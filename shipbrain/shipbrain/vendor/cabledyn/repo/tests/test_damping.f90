! File: tests/test_damping.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_damping
  !! Gate for legacy axial (BA) damping (CableDyn_Damping): BA resolution, the
  !! closed-form element force, signed per-element damping tension, the analytic
  !! position/velocity Jacobians vs central finite differences, dissipativity, the
  !! at-rest fixed point, and fail-closed inputs. Mirrors the reference
  !! implementation's axial-damping gates.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Damping, ONLY: CD_Resolve_Legacy_BA, CD_Cable_Axial_Damping_Force, &
                              CD_Cable_Axial_Damping_Load, CD_Cable_Element_Damping_Tension, &
                              CD_Axial_Damping_Element_Force, CD_Axial_Damping_Element_Load, &
                              CD_DAMP_OK, CD_DAMP_BADINPUT
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_resolve_ba()
  CALL case_force_closed_form()
  CALL case_element_kernel_matches_cable_path()
  CALL case_signed_tension()
  CALL case_velocity_jacobian_fd()
  CALL case_position_jacobian_fd()
  CALL case_dissipative_and_rest()
  CALL case_fail_closed()
  CALL case_payout_rate_shifts_strain_rate()
  CALL case_payout_constant_strain()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Damping (legacy axial BA damping) vs reference/FD'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_resolve_ba()
    !! -zeta resolves to BA = zeta*L_seg*sqrt(EA*w); half ratio -> half; direct passes.
    REAL(wp) :: ba, ba_half, ea, w, lseg
    INTEGER  :: es
    CHARACTER(160) :: em
    ea = 1.674e9_wp; w = 390.0_wp; lseg = 410.0_wp/41.0_wp
    CALL CD_Resolve_Legacy_BA(-1.0_wp, lseg, ea, w, ba, es, em)
    CALL require(es == CD_DAMP_OK, 'resolve:ok')
    CALL require(ABS(ba - lseg*SQRT(ea*w)) < 1.0e-3_wp, 'resolve:formula')
    CALL require(ABS(ba - 8.0800e6_wp) < 1.0e3_wp, 'resolve:wd0050-value')
    CALL CD_Resolve_Legacy_BA(-0.5_wp, lseg, ea, w, ba_half, es, em)
    CALL require(ABS(ba_half - 0.5_wp*ba) < 1.0e-3_wp, 'resolve:half-ratio')
    ! a direct non-negative value passes through (EA/mass ignored)
    CALL CD_Resolve_Legacy_BA(5.0e6_wp, lseg, 0.0_wp, w, ba, es, em)
    CALL require(es == CD_DAMP_OK .AND. ABS(ba - 5.0e6_wp) < 1.0e-6_wp, 'resolve:direct-passthrough')
    ! a -zeta ratio without positive EA fails closed
    CALL CD_Resolve_Legacy_BA(-1.0_wp, lseg, 0.0_wp, w, ba, es, em)
    CALL require(es == CD_DAMP_BADINPUT, 'resolve:zeta-needs-ea')
  END SUBROUTINE case_resolve_ba

  SUBROUTINE case_force_closed_form()
    !! One element along +x; node b moving +x at `speed` -> stretching. Td = BA*speed/L0,
    !! force = +Td on node a (toward b), -Td on node b.
    REAL(wp) :: q(6), v(6), ba(1), l0(1), force(6), speed, td_mag
    INTEGER  :: conn(2, 1), es
    CHARACTER(160) :: em
    conn(:, 1) = [1, 2]
    q = [0.0_wp, 0.0_wp, 0.0_wp, 10.0_wp, 0.0_wp, 0.0_wp]
    l0 = 10.0_wp; ba = 8.08e6_wp; speed = 2.0_wp
    v = 0.0_wp; v(4) = speed       ! node 2 (b) moves +x
    CALL CD_Cable_Axial_Damping_Force(q, v, conn, l0, ba, force, es, em)
    CALL require(es == CD_DAMP_OK, 'force:ok')
    td_mag = ba(1)*speed/l0(1)
    CALL require(ABS(force(1) - td_mag) < 1.0e-3_wp, 'force:node-a')
    CALL require(ABS(force(4) + td_mag) < 1.0e-3_wp, 'force:node-b')
    CALL require(ALL(ABS(force([2, 3, 5, 6])) < 1.0e-6_wp), 'force:transverse-zero')
  END SUBROUTINE case_force_closed_form

  SUBROUTINE case_element_kernel_matches_cable_path()
    REAL(wp) :: q(6), v(6), ba(1), l0(1), force_ref(6), jq_ref(6, 6), jv_ref(6, 6)
    REAL(wp) :: force_elem(6), jq_elem(6, 6), jv_elem(6, 6), force_only(6)
    INTEGER :: conn(2, 1), es
    CHARACTER(160) :: em

    conn(:, 1) = [1, 2]
    q = [0.0_wp, 0.0_wp, 0.0_wp, 9.0_wp, 4.0_wp, 1.0_wp]
    v = [0.1_wp, -0.2_wp, 0.3_wp, 0.5_wp, 0.4_wp, -0.1_wp]
    l0 = [8.0_wp]
    ba = [8.08e6_wp]

    CALL CD_Cable_Axial_Damping_Load(q, v, conn, l0, ba, force_ref, jq_ref, jv_ref, es, em)
    CALL require(es == CD_DAMP_OK, 'element:ref-ok')
    CALL CD_Axial_Damping_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), ba(1), &
                                       force_elem, jq_elem, jv_elem, es, em)
    CALL require(es == CD_DAMP_OK, 'element:load-ok')
    CALL require(nan_max_abs(force_elem - force_ref) < 1.0e-9_wp, 'element:force-match')
    CALL require(nan_max_abs(jq_elem - jq_ref) < 1.0e-9_wp, 'element:jq-match')
    CALL require(nan_max_abs(jv_elem - jv_ref) < 1.0e-9_wp, 'element:jv-match')

    CALL CD_Axial_Damping_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), ba(1), &
                                        force_only, es, em)
    CALL require(es == CD_DAMP_OK, 'element:force-ok')
    CALL require(nan_max_abs(force_only - force_ref) < 1.0e-9_wp, 'element:force-only-match')

    ! inputs_validated (the model hot path) skips only the input scan: the outputs, status and
    ! message equal the default call's bit for bit, for a regular and a collapsed element
    BLOCK
      INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
      REAL(wp) :: f2(6), jq2(6, 6), jv2(6, 6)
      INTEGER :: es2, icase
      CHARACTER(160) :: em2
      DO icase = 1, 2
        IF (icase == 2) q(4:6) = q(1:3)
        CALL CD_Axial_Damping_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), ba(1), &
                                           force_elem, jq_elem, jv_elem, es, em, l0_dot=0.3_wp)
        CALL CD_Axial_Damping_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), ba(1), &
                                           f2, jq2, jv2, es2, em2, l0_dot=0.3_wp, inputs_validated=.TRUE.)
        CALL require(ALL(TRANSFER(force_elem, [0_I8]) == TRANSFER(f2, [0_I8])) .AND. &
                     ALL(TRANSFER(jq_elem, [0_I8]) == TRANSFER(jq2, [0_I8])) .AND. &
                     ALL(TRANSFER(jv_elem, [0_I8]) == TRANSFER(jv2, [0_I8])) .AND. &
                     es == es2 .AND. em == em2, 'element:validated-load-bitwise')
        CALL CD_Axial_Damping_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), ba(1), &
                                            force_only, es, em, l0_dot=0.3_wp)
        CALL CD_Axial_Damping_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), ba(1), &
                                            f2, es2, em2, l0_dot=0.3_wp, inputs_validated=.TRUE.)
        CALL require(ALL(TRANSFER(force_only, [0_I8]) == TRANSFER(f2, [0_I8])) .AND. &
                     es == es2 .AND. em == em2, 'element:validated-force-bitwise')
      END DO
      CALL require(es2 == CD_DAMP_BADINPUT, 'element:validated-collapsed-fails')
    END BLOCK
  END SUBROUTINE case_element_kernel_matches_cable_path

  SUBROUTINE case_signed_tension()
    !! Two segments along +x; shared middle node moves +x: seg 1 stretches (+Td),
    !! seg 2 shortens (-Td); at rest Td = 0.
    REAL(wp) :: q(9), v(9), v_zero(9), ba(2), l0(2), td(2), speed
    INTEGER  :: conn(2, 2), es
    CHARACTER(160) :: em
    conn(:, 1) = [1, 2]; conn(:, 2) = [2, 3]
    q = [0.0_wp, 0.0_wp, 0.0_wp, 10.0_wp, 0.0_wp, 0.0_wp, 20.0_wp, 0.0_wp, 0.0_wp]
    l0 = 10.0_wp; ba = 8.08e6_wp; speed = 3.0_wp
    v = 0.0_wp; v(4) = speed        ! middle node (2) moves +x
    v_zero = 0.0_wp
    CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td, es, em)
    CALL require(es == CD_DAMP_OK, 'td:ok')
    CALL require(ABS(td(1) - ba(1)*speed/l0(1)) < 1.0e-3_wp, 'td:seg1-stretch')
    CALL require(ABS(td(2) + ba(2)*speed/l0(2)) < 1.0e-3_wp, 'td:seg2-shorten')
    CALL CD_Cable_Element_Damping_Tension(q, v_zero, conn, l0, ba, td, es, em)
    CALL require(nan_max_abs(td) < 1.0e-9_wp, 'td:zero-at-rest')
  END SUBROUTINE case_signed_tension

  SUBROUTINE case_velocity_jacobian_fd()
    !! Analytic dF/dv = -jac_v matches central FD on a bent 3-node line with generic v.
    REAL(wp) :: q(9), v(9), ba(2), l0(2), jq(9, 9), jv(9, 9)
    REAL(wp) :: fd(9, 9), analytic(9, 9), vp(9), vm(9), fp(9), fm(9), rel, eps, denom
    INTEGER  :: conn(2, 2), es, j
    CHARACTER(160) :: em
    REAL(wp) :: f9(9)
    conn(:, 1) = [1, 2]; conn(:, 2) = [2, 3]
    ! bent line so tangents differ and the orientation terms are exercised
    q = [0.0_wp, 0.0_wp, 0.0_wp, 9.0_wp, 4.0_wp, 1.0_wp, 17.0_wp, 1.0_wp, 6.0_wp]
    v = [0.1_wp, -0.2_wp, 0.3_wp, 0.5_wp, 0.4_wp, -0.1_wp, -0.3_wp, 0.2_wp, 0.6_wp]
    l0 = 8.0_wp; ba = 8.08e6_wp
    CALL CD_Cable_Axial_Damping_Load(q, v, conn, l0, ba, f9, jq, jv, es, em)
    CALL require(es == CD_DAMP_OK, 'jacv:ok')
    analytic = -jv                       ! dF/dv = -(returned residual jac_v)
    eps = 1.0e-2_wp                      ! linear in v -> any eps exact to round-off
    DO j = 1, 9
      vp = v; vm = v; vp(j) = vp(j) + eps; vm(j) = vm(j) - eps
      CALL CD_Cable_Axial_Damping_Force(q, vp, conn, l0, ba, fp, es, em)
      CALL CD_Cable_Axial_Damping_Force(q, vm, conn, l0, ba, fm, es, em)
      fd(:, j) = (fp - fm)/(2.0_wp*eps)
    END DO
    denom = nan_max_abs(analytic) + 1.0e-30_wp
    rel = nan_max_abs(analytic - fd)/denom
    CALL require(rel < 1.0e-7_wp, 'jacv:matches-fd')
  END SUBROUTINE case_velocity_jacobian_fd

  SUBROUTINE case_position_jacobian_fd()
    !! Analytic dF/dq = -jac_q matches central FD on a bent 3-node line with generic v.
    REAL(wp) :: q(9), v(9), ba(2), l0(2), jq(9, 9), jv(9, 9)
    REAL(wp) :: fd(9, 9), analytic(9, 9), qp(9), qm(9), fp(9), fm(9), rel, eps, denom, f9(9)
    INTEGER  :: conn(2, 2), es, j
    CHARACTER(160) :: em
    conn(:, 1) = [1, 2]; conn(:, 2) = [2, 3]
    q = [0.0_wp, 0.0_wp, 0.0_wp, 9.0_wp, 4.0_wp, 1.0_wp, 17.0_wp, 1.0_wp, 6.0_wp]
    v = [0.1_wp, -0.2_wp, 0.3_wp, 0.5_wp, 0.4_wp, -0.1_wp, -0.3_wp, 0.2_wp, 0.6_wp]
    l0 = 8.0_wp; ba = 8.08e6_wp
    CALL CD_Cable_Axial_Damping_Load(q, v, conn, l0, ba, f9, jq, jv, es, em)
    CALL require(es == CD_DAMP_OK, 'jacq:ok')
    analytic = -jq
    eps = 1.0e-6_wp
    DO j = 1, 9
      qp = q; qm = q; qp(j) = qp(j) + eps; qm(j) = qm(j) - eps
      CALL CD_Cable_Axial_Damping_Force(qp, v, conn, l0, ba, fp, es, em)
      CALL CD_Cable_Axial_Damping_Force(qm, v, conn, l0, ba, fm, es, em)
      fd(:, j) = (fp - fm)/(2.0_wp*eps)
    END DO
    denom = nan_max_abs(analytic) + 1.0e-30_wp
    rel = nan_max_abs(analytic - fd)/denom
    CALL require(rel < 1.0e-6_wp, 'jacq:matches-fd')
  END SUBROUTINE case_position_jacobian_fd

  SUBROUTINE case_dissipative_and_rest()
    !! Power f.v <= 0 (dissipative) for generic motion; at rest force and jac_q vanish.
    REAL(wp) :: q(9), v(9), v_zero(9), ba(2), l0(2), force(9), jq(9, 9), jv(9, 9), f9(9), power
    INTEGER  :: conn(2, 2), es
    CHARACTER(160) :: em
    conn(:, 1) = [1, 2]; conn(:, 2) = [2, 3]
    q = [0.0_wp, 0.0_wp, 0.0_wp, 9.0_wp, 4.0_wp, 1.0_wp, 17.0_wp, 1.0_wp, 6.0_wp]
    v = [0.1_wp, -0.2_wp, 0.3_wp, 0.5_wp, 0.4_wp, -0.1_wp, -0.3_wp, 0.2_wp, 0.6_wp]
    v_zero = 0.0_wp
    l0 = 8.0_wp; ba = 8.08e6_wp
    CALL CD_Cable_Axial_Damping_Force(q, v, conn, l0, ba, force, es, em)
    power = DOT_PRODUCT(force, v)
    CALL require(power <= 1.0e-6_wp, 'dissipative:power-nonpositive')
    ! at rest: force = 0 and the position Jacobian = 0 (ldot = 0)
    CALL CD_Cable_Axial_Damping_Load(q, v_zero, conn, l0, ba, f9, jq, jv, es, em)
    CALL require(nan_max_abs(f9) < 1.0e-9_wp, 'rest:force-zero')
    CALL require(nan_max_abs(jq) < 1.0e-6_wp, 'rest:jacq-zero')
  END SUBROUTINE case_dissipative_and_rest

  SUBROUTINE case_fail_closed()
    !! Malformed shapes and a collapsed element fail closed.
    REAL(wp) :: q(9), v(9), ba(2), l0(2), force(9), td(2)
    INTEGER  :: conn(2, 2), es
    CHARACTER(160) :: em
    conn(:, 1) = [1, 2]; conn(:, 2) = [2, 3]
    l0 = 8.0_wp; ba = 8.08e6_wp
    ! collapsed element: nodes 1 and 2 coincide
    q = [0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 17.0_wp, 1.0_wp, 6.0_wp]
    v = 0.0_wp
    CALL CD_Cable_Axial_Damping_Force(q, v, conn, l0, ba, force, es, em)
    CALL require(es == CD_DAMP_BADINPUT, 'fail:collapsed-element')
    ! bad ba shape (1 not n_elem=2)
    q = [0.0_wp, 0.0_wp, 0.0_wp, 9.0_wp, 4.0_wp, 1.0_wp, 17.0_wp, 1.0_wp, 6.0_wp]
    BLOCK
      REAL(wp) :: ba1(1)
      ba1 = 1.0_wp
      CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba1, td, es, em)
      CALL require(es == CD_DAMP_BADINPUT, 'fail:bad-ba-shape')
    END BLOCK
    ! non-positive l0
    BLOCK
      REAL(wp) :: l0bad(2)
      l0bad = [8.0_wp, 0.0_wp]
      CALL CD_Cable_Axial_Damping_Force(q, v, conn, l0bad, ba, force, es, em)
      CALL require(es == CD_DAMP_BADINPUT, 'fail:bad-l0')
    END BLOCK
    ! a negative (unresolved) ba would flip damping into anti-damping -> reject it
    BLOCK
      REAL(wp) :: ba_neg(2)
      ba_neg = [8.08e6_wp, -1.0_wp]
      CALL CD_Cable_Axial_Damping_Force(q, v, conn, l0, ba_neg, force, es, em)
      CALL require(es == CD_DAMP_BADINPUT, 'fail:negative-ba')
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

  SUBROUTINE case_payout_rate_shifts_strain_rate()
    !! Active line control: the optional per-element unstretched-length RATE
    !! (l0_dot, MoorDyn's ld) shifts the damping strain rate. Exact identities on
    !! a single axially stretching element: (a) l0_dot equal to the geometric
    !! stretch rate gives ZERO damping tension (a segment paying out exactly with
    !! its stretch carries none); (b) the shifted tension equals the closed form
    !! ba*(ldot - l0_dot)/l0; (c) all three routines agree; (d) omitting l0_dot is
    !! bit-identical to l0_dot = 0.
    REAL(wp) :: q(6), v(6), l0(1), ba(1), l0_dot(1), td(1), td0(1)
    REAL(wp) :: force(6), force2(6), jq(6, 6), jv(6, 6)
    INTEGER :: conn(2, 1), es
    CHARACTER(200) :: em
    REAL(wp), PARAMETER :: SPEED = 0.3_wp

    conn(:, 1) = [1, 2]
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    v(4) = SPEED                     ! node b moving +x: geometric ldot = SPEED
    l0 = [1.0_wp]
    ba = [7.0_wp]

    ! (a) payout at exactly the stretch rate: zero damping tension
    l0_dot = [SPEED]
    CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td, es, em, l0_dot=l0_dot)
    CALL require(es == CD_DAMP_OK, 'payout:ok')
    CALL require(ABS(td(1)) <= 1.0e-15_wp, 'payout:matched-rate-zero-tension')

    ! (b) closed form at half the rate
    l0_dot = [0.5_wp*SPEED]
    CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td, es, em, l0_dot=l0_dot)
    CALL require(ABS(td(1) - ba(1)*(SPEED - l0_dot(1))/l0(1)) < 1.0e-12_wp, 'payout:closed-form')

    ! (c) the force and load routines carry the same shift
    CALL CD_Cable_Axial_Damping_Force(q, v, conn, l0, ba, force, es, em, l0_dot=l0_dot)
    CALL require(es == CD_DAMP_OK, 'payout:force-ok')
    CALL require(ABS(force(4) + td(1)) < 1.0e-12_wp, 'payout:force-matches-tension')
    CALL CD_Cable_Axial_Damping_Load(q, v, conn, l0, ba, force2, jq, jv, es, em, l0_dot=l0_dot)
    CALL require(es == CD_DAMP_OK, 'payout:load-ok')
    CALL require(nan_max_abs(force2 - force) <= 0.0_wp, 'payout:load-matches-force')

    ! (d) absent l0_dot is bit-identical to the l0_dot = 0 call
    CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td0, es, em)
    CALL require(ABS(td0(1) - ba(1)*SPEED/l0(1)) < 1.0e-12_wp, 'payout:absent-arg-unchanged')
  END SUBROUTINE case_payout_rate_shifts_strain_rate

  SUBROUTINE case_payout_constant_strain()
    !! MoorDyn-F damps L0 times the strain rate: Td = (BA/L0)*(ldot - (length/L0)*l0_dot).
    !! (a) A stretched segment (2 % strain) paid out at constant strain,
    !! ldot = (length/L0)*l0_dot, carries ZERO damping tension in all four routines;
    !! (b) the closed form off that point; (c) the position Jacobians of the cable
    !! and element load routines, including the l0_dot term, match central FD.
    REAL(wp), PARAMETER :: L0E = 10.0_wp, LD = 0.5_wp, BAE = 1.0e6_wp, STRETCH = 1.02_wp
    REAL(wp) :: q(6), v(6), l0(1), ba(1), l0_dot(1), td(1), f6(6), jq(6, 6), jv(6, 6)
    REAL(wp) :: fp(6), fm(6), jd(6, 6), jvd(6, 6), qp(6), err, h
    INTEGER :: conn(2, 1), es, i, j
    CHARACTER(200) :: em

    conn(:, 1) = [1, 2]
    l0 = [L0E]
    ba = [BAE]
    l0_dot = [LD]
    q = [0.0_wp, 0.0_wp, 0.0_wp, STRETCH*L0E, 0.0_wp, 0.0_wp]
    v = 0.0_wp
    v(4) = STRETCH*LD
    ! (a) constant-strain payout
    CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td, es, em, l0_dot=l0_dot)
    CALL require(es == CD_DAMP_OK .AND. ABS(td(1)) <= 1.0e-9_wp, 'payout-strain:zero-tension')
    CALL CD_Cable_Axial_Damping_Force(q, v, conn, l0, ba, f6, es, em, l0_dot=l0_dot)
    CALL require(es == CD_DAMP_OK .AND. nan_max_abs(f6) <= 1.0e-9_wp, 'payout-strain:zero-force')
    CALL CD_Axial_Damping_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), L0E, BAE, f6, es, em, l0_dot=LD)
    CALL require(es == CD_DAMP_OK .AND. nan_max_abs(f6) <= 1.0e-9_wp, 'payout-strain:zero-element-force')
    CALL CD_Axial_Damping_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), L0E, BAE, f6, jq, jv, es, em, &
                                       l0_dot=LD)
    CALL require(es == CD_DAMP_OK .AND. nan_max_abs(f6) <= 1.0e-9_wp, 'payout-strain:zero-element-load')
    ! (b) closed form with the segment moving off the constant-strain rate
    v(4) = 0.3_wp
    CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td, es, em, l0_dot=l0_dot)
    CALL require(ABS(td(1) - BAE/L0E*(0.3_wp - STRETCH*LD)) <= 1.0e-9_wp*BAE, 'payout-strain:closed-form')
    ! (c) FD position Jacobians on a skewed element (jac_q = -dF/dq)
    q = [0.1_wp, -0.2_wp, 0.05_wp, 9.9_wp, 1.3_wp, -0.7_wp]
    v = [0.02_wp, 0.01_wp, -0.03_wp, 0.4_wp, -0.1_wp, 0.2_wp]
    h = 1.0e-6_wp
    CALL CD_Cable_Axial_Damping_Load(q, v, conn, l0, ba, f6, jq, jv, es, em, l0_dot=l0_dot)
    err = 0.0_wp
    DO j = 1, 6
      qp = q
      qp(j) = q(j) + h
      CALL CD_Cable_Axial_Damping_Force(qp, v, conn, l0, ba, fp, es, em, l0_dot=l0_dot)
      qp(j) = q(j) - h
      CALL CD_Cable_Axial_Damping_Force(qp, v, conn, l0, ba, fm, es, em, l0_dot=l0_dot)
      DO i = 1, 6
        err = MAX(err, ABS(-(fp(i) - fm(i))/(2.0_wp*h) - jq(i, j))/MAX(1.0_wp, ABS(jq(i, j))))
      END DO
    END DO
    CALL require(err < 1.0e-5_wp, 'payout-strain:cable-fd-jacobian')
    CALL CD_Axial_Damping_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), L0E, BAE, f6, jq, jv, es, em, &
                                       l0_dot=LD)
    err = 0.0_wp
    DO j = 1, 6
      qp = q
      qp(j) = q(j) + h
      CALL CD_Axial_Damping_Element_Load(qp(1:3), qp(4:6), v(1:3), v(4:6), L0E, BAE, fp, jd, jvd, es, em, &
                                         l0_dot=LD)
      qp(j) = q(j) - h
      CALL CD_Axial_Damping_Element_Load(qp(1:3), qp(4:6), v(1:3), v(4:6), L0E, BAE, fm, jd, jvd, es, em, &
                                         l0_dot=LD)
      DO i = 1, 6
        err = MAX(err, ABS(-(fp(i) - fm(i))/(2.0_wp*h) - jq(i, j))/MAX(1.0_wp, ABS(jq(i, j))))
      END DO
    END DO
    CALL require(err < 1.0e-5_wp, 'payout-strain:element-fd-jacobian')
  END SUBROUTINE case_payout_constant_strain

END PROGRAM test_damping
