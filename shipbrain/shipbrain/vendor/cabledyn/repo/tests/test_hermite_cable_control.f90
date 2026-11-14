! File: tests/test_hermite_cable_control.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_cable_control
  !! Active line control of a finite-EI (cubic-Hermite) cable,
  !! CD_HermiteCable_Dyn_Set_SegmentLength:
  !!   A  the update is inert when nothing changes (a rate of -0 included), rebuilds every
  !!      length-dependent cache to what a model built with the new lengths carries (bit for
  !!      bit), leaves the committed lengths to a re-derived acceleration, is atomic on
  !!      failure, refuses a contact line without the seabed recompute inputs and the
  !!      configuration blend, is taken back exactly by a saved control state, and joins the
  !!      snapshot/restore contract exactly (a line restrained in torsion: test_control_torsion);
  !!   B  a hanging vertical cable whose top span is paid out settles to the top reaction
  !!      w (L + DeltaL) and the stretched length L' + w L'**2/(2 EA);
  !!   C  a taut vertical cable whose top span is hauled in settles to the top tension
  !!      EA (H - L')/L' + w L'/2;
  !!   D  a weightless taut cable paid out at a constant rate Ldot carries the Kelvin-Voigt
  !!      tension EA (H/L' - 1) - BA H Ldot/L'**2 (without the length rate it does not);
  !!   E  a slack cable whose top span is ramped slowly ends at the static equilibrium of the
  !!      edited lengths;
  !!   F  the cable of D paid out at a constant rate under the force-blended generalised-alpha
  !!      with alpha_f > 0 carries the same tension as with alpha_f = 0, the closed form of D,
  !!      also when the committed force is evaluated afresh each step rather than reused: the
  !!      committed force of each step belongs to the lengths it was reached with.
  !! The axial cases B-D and F hold every transverse DOF, so the closed forms are exact for the
  !! cubic-Hermite element (linear tension, quadratic displacement); the transient is damped
  !! by BA. A, D and E run at rho_inf = 0; B and C at rho_inf = 0 and 0.4, C also comparing the
  !! two through the ramp (the lag check of a line with weight).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Reaction, &
                                          CD_HermiteCable_Dyn_Set_SegmentLength, &
                                          CD_HermiteCable_Dyn_Set_Control_Seabed, &
                                          CD_HermiteCable_Dyn_Set_Contact, CD_HermiteCable_Dyn_Set_Attachments, &
                                          CD_HermiteCable_Dyn_Set_Axial_Damping, CD_HermiteCable_Dyn_Set_Drag, &
                                          CD_HermiteCable_Dyn_Recompute_Acceleration, &
                                          CD_HermiteCable_Dyn_Snapshot, CD_HermiteCable_Dyn_Restore, &
                                          CD_HermiteCable_Dyn_Set_ForceBlend, CD_HermiteCableControlSaveType, &
                                          CD_HermiteCable_Dyn_Save_Control, CD_HermiteCable_Dyn_Restore_Control, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_Line, ONLY: CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  INTEGER :: nfail

  nfail = 0
  CALL check_model_contract()
  CALL check_hanging_payout()
  CALL check_taut_haul_in()
  CALL check_payout_rate_lag()
  CALL check_slow_ramp_static()
  CALL check_payout_alpha_f()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI active line control (caches, rewind, closed forms, static end state)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_model_contract()
    !! A: a seabed cable with friction, attachments and axial damping.
    INTEGER, PARAMETER :: NE = 8, NN = NE + 1, NDOF = 6*NN
    REAL(wp), PARAMETER :: L = 1.5_wp, KBOT = 1.0e5_wp, CBOT = 1.0e4_wp, ZBED = -20.0_wp, DT = 0.01_wp
    TYPE(CD_HermiteCableDynType) :: a, b, ref, twin
    REAL(wp) :: l0(NE), l0b(NE), q(NDOF), diam(NE), lam
    INTEGER, PARAMETER :: SPAN(2) = [7, 8]
    INTEGER :: i, es, k
    CHARACTER(300) :: em

    l0 = L
    diam = 0.1_wp
    q = 0.0_wp
    DO i = 1, NN
      q(6*(i - 1) + 1) = REAL(i - 1, wp)*L
      q(6*(i - 1) + 3) = ZBED
      q(6*(i - 1) + 4) = 1.0_wp
    END DO
    CALL build_bed_model(a, l0, q, diam, KBOT, CBOT, ZBED, es, em)
    CALL require(es == CD_HCDYN_OK, 'A: seabed model: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN

    ! inert: a command that changes nothing leaves the model untouched and uncontrolled
    twin = a
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, a%l0(SPAN), [0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. .NOT. a%has_ctrl .AND. .NOT. ALLOCATED(a%l0_dot), &
                 'A: an unchanged length and zero rate leave the model uncontrolled')
    CALL require(same_bits2(a%Mgb, twin%Mgb) .AND. same_bits(a%l0, twin%l0) .AND. &
                 (a%fc_valid .EQV. twin%fc_valid), 'A: the inert call writes nothing')
    DO k = 1, 3
      CALL CD_HermiteCable_Dyn_Step(a, DT, 50, 1.0e-10_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'A: inert step: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_Step(twin, DT, 50, 1.0e-10_wp, es, em)
    END DO
    CALL require(same_bits(a%q, twin%q) .AND. same_bits(a%v, twin%v) .AND. same_bits(a%a, twin%a), &
                 'A: steps after the inert call are bit-identical to a never-controlled twin')
    ! a rate of -0 (a host's negated zero) counts as +0: still inert
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, a%l0(SPAN), [SIGN(0.0_wp, -1.0_wp), SIGN(0.0_wp, -1.0_wp)], &
                                               es, em)
    CALL require(es == CD_HCDYN_OK .AND. .NOT. a%has_ctrl .AND. .NOT. ALLOCATED(a%l0_dot), &
                 'A: a rate of -0 leaves the model uncontrolled')
    ! the configuration blend has no committed-length treatment: refused by name
    CALL CD_HermiteCable_Dyn_Set_ForceBlend(twin, .FALSE., es, em)
    CALL require(es == CD_HCDYN_OK, 'A: twin on the configuration blend')
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(twin, SPAN, 1.1_wp*twin%l0(SPAN), [0.0_wp, 0.0_wp], es, em)
    CALL require(es /= CD_HCDYN_OK .AND. INDEX(em, 'force blend') > 0 .AND. .NOT. twin%has_ctrl, &
                 'A: the configuration blend fails closed by name')
    CALL CD_HermiteCable_Dyn_End(twin)

    ! rebuild = fresh init: lengthen the trailing span, then build a model with those lengths
    CALL CD_HermiteCable_Dyn_End(a)
    CALL build_bed_model(a, l0, q, diam, KBOT, CBOT, ZBED, es, em)
    lam = 1.3_wp
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, lam*l0(SPAN), [0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. a%has_ctrl, 'A: span lengthened: '//TRIM(em))
    CALL require(.NOT. a%tr_valid .AND. same_bits(a%l0_c, l0) .AND. ALL(a%l0_dot_c == 0.0_wp), &
                 'A: a length change drops the carried factor; the committed state keeps its lengths')
    l0b = l0
    l0b(SPAN) = lam*l0(SPAN)
    CALL build_bed_model(b, l0b, q, diam, KBOT, CBOT, ZBED, es, em)
    CALL require(es == CD_HCDYN_OK, 'A: fresh model at the new lengths: '//TRIM(em))
    CALL require(same_bits(a%l0, b%l0), 'A: lengths equal a fresh build')
    CALL require(same_bits2(a%Mgb, b%Mgb), 'A: constant mass with attachments equals a fresh build bit for bit')
    CALL require(same_bits(a%trib, b%trib), 'A: tributary lengths equal a fresh build bit for bit')
    CALL require(same_bits(a%contact_kn, b%contact_kn) .AND. same_bits(a%contact_cn, b%contact_cn), &
                 'A: nodal seabed coefficients equal a fresh build bit for bit')
    CALL require(same_bits(a%fr_k, b%fr_k), 'A: friction spring stiffness equals a fresh build bit for bit')
    ! a non-stepping re-derivation of the committed acceleration between the command and the
    ! step belongs to the committed state: it is solved at the lengths that state was reached
    ! with, which stay the committed ones, so it equals the acceleration of a model that was
    ! never commanded, the committed force cache survives, and the new lengths stay in place
    twin = a
    CALL build_bed_model(ref, l0, q, diam, KBOT, CBOT, ZBED, es, em)
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(ref, es, em)
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(a, es, em)
    CALL require(es == CD_HCDYN_OK .AND. same_bits(a%a, ref%a) .AND. same_bits(a%l0_c, l0) .AND. &
                 ALL(a%l0_dot_c == 0.0_wp) .AND. (a%fc_valid .EQV. twin%fc_valid) .AND. unchanged(a, twin), &
                 'A: a re-derived acceleration belongs to the committed lengths, which stay committed')
    CALL CD_HermiteCable_Dyn_End(ref)
    CALL CD_HermiteCable_Dyn_End(twin)
    ! once the new lengths are committed (restored = .TRUE., as a checkpoint restart does),
    ! the re-derived acceleration is the fresh model's and the two models step identically
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, lam*l0(SPAN), [0.0_wp, 0.0_wp], es, em, restored=.TRUE.)
    CALL require(es == CD_HCDYN_OK .AND. same_bits(a%l0_c, a%l0), 'A: restored = .TRUE. commits the lengths')
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(a, es, em)
    CALL require(es == CD_HCDYN_OK .AND. nan_max_abs(a%a - b%a) <= 0.0_wp, &
                 'A: at committed new lengths the re-derived acceleration equals the fresh model''s')
    DO k = 1, 3
      CALL CD_HermiteCable_Dyn_Step(a, DT, 50, 1.0e-10_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'A: controlled step: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_Step(b, DT, 50, 1.0e-10_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'A: fresh-model step: '//TRIM(em))
    END DO
    CALL require(nan_max_abs(a%q - b%q) <= 0.0_wp .AND. nan_max_abs(a%v - b%v) <= 0.0_wp, &
                 'A: the controlled model marches exactly as one built with the new lengths')
    CALL CD_HermiteCable_Dyn_End(b)

    ! a rate-only change rebuilds nothing and keeps the committed force (it belongs to the
    ! committed rates, which stay)
    ref = a
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, a%l0(SPAN), [0.05_wp, 0.05_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. same_bits2(a%Mgb, ref%Mgb) .AND. same_bits(a%l0, ref%l0) .AND. &
                 a%fc_valid .AND. same_bits(a%fc_R, ref%fc_R) .AND. ALL(a%l0_dot_c == 0.0_wp) .AND. &
                 ALL(a%l0_dot(SPAN) == 0.05_wp) .AND. ALL(a%l0_dot(1:6) == 0.0_wp), &
                 'A: a rate-only change keeps the caches and records the rate on the span')

    ! a controlled model keeps the force blend
    CALL CD_HermiteCable_Dyn_Set_ForceBlend(a, .FALSE., es, em)
    CALL require(es /= CD_HCDYN_OK .AND. a%force_blend, 'A: the force blend of a controlled model stays on')

    ! a saved control state takes a command back bit for bit, the carried-factor flag included
    BLOCK
      TYPE(CD_HermiteCableControlSaveType) :: saved
      LOGICAL :: tr_before
      ref = a
      tr_before = a%tr_valid
      CALL CD_HermiteCable_Dyn_Save_Control(a, saved)
      CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, 0.7_wp*a%l0(SPAN), [-0.3_wp, -0.3_wp], es, em, &
                                                 restored=.TRUE.)
      CALL require(es == CD_HCDYN_OK .AND. .NOT. unchanged(a, ref), 'A: a command to take back')
      CALL CD_HermiteCable_Dyn_Restore_Control(a, saved, es, em)
      CALL require(es == CD_HCDYN_OK .AND. unchanged(a, ref) .AND. same_bits(a%l0_c, ref%l0_c) .AND. &
                   same_bits(a%l0_dot_c, ref%l0_dot_c) .AND. (a%tr_valid .EQV. tr_before), &
                   'A: the saved control state takes the command back bit for bit')
      ! on a model that was never controlled, the restore drops the control storage again
      CALL build_bed_model(twin, l0, q, diam, KBOT, CBOT, ZBED, es, em)
      ref = twin
      CALL CD_HermiteCable_Dyn_Save_Control(twin, saved)
      CALL CD_HermiteCable_Dyn_Set_SegmentLength(twin, SPAN, 1.2_wp*l0(SPAN), [0.1_wp, 0.1_wp], es, em)
      CALL CD_HermiteCable_Dyn_Restore_Control(twin, saved, es, em)
      CALL require(es == CD_HCDYN_OK .AND. unchanged(twin, ref) .AND. .NOT. ALLOCATED(twin%l0_dot), &
                   'A: taking back the first command restores the uncontrolled model')
      CALL CD_HermiteCable_Dyn_End(twin)
      CALL CD_HermiteCable_Dyn_End(ref)
    END BLOCK

    ! atomic failure: nothing is written
    ref = a
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, [7, 9], [1.0_wp, 1.0_wp], [0.0_wp, 0.0_wp], es, em)
    CALL require(es /= CD_HCDYN_OK .AND. unchanged(a, ref), 'A: an out-of-range element fails and writes nothing')
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, [8, 7], [1.0_wp, 1.0_wp], [0.0_wp, 0.0_wp], es, em)
    CALL require(es /= CD_HCDYN_OK .AND. unchanged(a, ref), 'A: unordered elements fail and write nothing')
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, [1.0_wp, -1.0_wp], [0.0_wp, 0.0_wp], es, em)
    CALL require(es /= CD_HCDYN_OK .AND. unchanged(a, ref), 'A: a non-positive length fails and writes nothing')
    twin = a
    twin%has_seabed_recompute = .FALSE.
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(twin, SPAN, [1.0_wp, 1.0_wp], [0.0_wp, 0.0_wp], es, em)
    CALL require(es /= CD_HCDYN_OK .AND. INDEX(em, 'seabed recompute') > 0, &
                 'A: a contact line without the seabed recompute inputs fails closed')
    CALL CD_HermiteCable_Dyn_End(twin)
    CALL CD_HermiteCable_Dyn_Set_Control_Seabed(a, 2.0_wp*KBOT, diam, CBOT/KBOT, es, em)
    CALL require(es /= CD_HCDYN_OK .AND. INDEX(em, 'do not reproduce') > 0 .AND. a%seabed_kbot == KBOT, &
                 'A: seabed recompute inputs that do not reproduce the installed coefficients fail')
    ! a ratio that differs only by rounding (an optimising compiler may evaluate the deck's
    ! kn*(cBot/kBot) differently) is accepted; one that differs by 1e-9 is not
    CALL CD_HermiteCable_Dyn_Set_Control_Seabed(a, KBOT, diam, NEAREST(CBOT/KBOT, 1.0_wp), es, em)
    CALL require(es == CD_HCDYN_OK, 'A: seabed recompute inputs equal to rounding are accepted: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Control_Seabed(a, KBOT, diam, CBOT/KBOT, es, em)
    CALL require(es == CD_HCDYN_OK .AND. a%seabed_cn_over_kn == CBOT/KBOT, 'A: the exact inputs are set again')
    CALL CD_HermiteCable_Dyn_Set_Control_Seabed(a, KBOT, diam, (CBOT/KBOT)*(1.0_wp + 1.0e-9_wp), es, em)
    CALL require(es /= CD_HCDYN_OK .AND. INDEX(em, 'contact damping') > 0, &
                 'A: a damping ratio off by 1e-9 does not reproduce the installed coefficients')

    ! snapshot/restore: a later command and step roll back exactly, caches included
    ref = a
    CALL CD_HermiteCable_Dyn_Snapshot(a, es, em)
    CALL require(es == CD_HCDYN_OK, 'A: snapshot: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, 0.8_wp*a%l0(SPAN), [-0.1_wp, -0.1_wp], es, em)
    CALL require(es == CD_HCDYN_OK, 'A: command after the snapshot: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Step(a, DT, 50, 1.0e-10_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'A: step after the command: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Restore(a, es, em)
    CALL require(es == CD_HCDYN_OK, 'A: restore: '//TRIM(em))
    CALL require(unchanged(a, ref) .AND. same_bits(a%l0_dot, ref%l0_dot) .AND. same_bits(a%q, ref%q) .AND. &
                 same_bits(a%v, ref%v) .AND. same_bits(a%a, ref%a) .AND. same_bits2(a%fr_anchor, ref%fr_anchor), &
                 'A: restore brings back the lengths, rates, caches and state bit for bit')
    ! Restore clears the carried Newton factor, which ref still holds; where a step stops
    ! depends on the factor's age, so a restart is exact only with tangent reuse off. The
    ! cached committed force comes back with the snapshot (the length command after it does
    ! not invalidate it), so a takes the same cached path as ref: on a friction line the cache
    ! differs from a fresh evaluation in its last bits.
    a%tangent_reuse = .FALSE.
    ref%tangent_reuse = .FALSE.
    CALL require(a%fc_valid .AND. ref%fc_valid .AND. same_bits(a%fc_R, ref%fc_R), &
                 'A: restore brings back the cached committed force of the snapshot')
    DO k = 1, 3
      CALL CD_HermiteCable_Dyn_Step(a, DT, 50, 1.0e-10_wp, es, em)
      CALL CD_HermiteCable_Dyn_Step(ref, DT, 50, 1.0e-10_wp, es, em)
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3)') '  A: restored vs untouched after 3 steps, max |dq| ', &
      MAXVAL(ABS(a%q - ref%q)), ', max |dv| ', MAXVAL(ABS(a%v - ref%v))
    CALL require(es == CD_HCDYN_OK .AND. same_bits(a%q, ref%q) .AND. same_bits(a%v, ref%v), &
                 'A: the restored model marches bit-identically to an untouched copy')
    CALL CD_HermiteCable_Dyn_End(ref)
    CALL CD_HermiteCable_Dyn_End(a)

    ! a snapshot taken before any command restores the uncontrolled model
    CALL build_bed_model(a, l0, q, diam, KBOT, CBOT, ZBED, es, em)
    ref = a
    CALL CD_HermiteCable_Dyn_Snapshot(a, es, em)
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, 1.5_wp*l0(SPAN), [0.2_wp, 0.2_wp], es, em)
    CALL CD_HermiteCable_Dyn_Restore(a, es, em)
    CALL require(es == CD_HCDYN_OK .AND. .NOT. a%has_ctrl .AND. unchanged(a, ref), &
                 'A: restoring a pre-control snapshot gives back the uncontrolled model')
    CALL CD_HermiteCable_Dyn_End(ref)
    CALL CD_HermiteCable_Dyn_End(a)
  END SUBROUTINE check_model_contract

  SUBROUTINE build_bed_model(model, l0, q, diam, kbot, cbot, zbed, ErrStat, ErrMsg)
    !! A cable laid on a flat bed: nodal contact with friction, axial damping and two
    !! attachments, set up in the order of the deck builder.
    TYPE(CD_HermiteCableDynType), INTENT(OUT) :: model
    REAL(wp), INTENT(IN) :: l0(:), q(:), diam(:), kbot, cbot, zbed
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: kn(:), cn(:)
    INTEGER :: ne, ndof, k
    ne = SIZE(l0)
    ndof = 6*(ne + 1)
    CALL CD_HermiteCable_Dyn_Init(model, l0, [(1.0e6_wp, k=1, ne)], [(100.0_wp, k=1, ne)], [(5.0_wp, k=1, ne)], &
                                  [(30.0_wp, k=1, ne)], q, [1, 2, 3, ndof - 5, ndof - 4, ndof - 3], zbed, 0.0_wp, &
                                  0.5_wp, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(model, [(2.0e4_wp, k=1, ne)], ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    CALL CD_Nodal_Seabed_Stiffness(kbot, diam, l0, kn, ErrStat, ErrMsg)
    IF (ErrStat /= CD_LINE_OK) RETURN
    cn = kn*(cbot/kbot)
    CALL CD_HermiteCable_Dyn_Set_Contact(model, kn, cn, 0.3_wp, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Control_Seabed(model, kbot, diam, cbot/kbot, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Attachments(model, [3, ne], [50.0_wp, 20.0_wp], [0.01_wp, 0.02_wp], &
                                             [0.1_wp, 0.0_wp], [0.05_wp, 0.0_wp], [1.0_wp, 0.5_wp], &
                                             1025.0_wp, 9.80665_wp, ErrStat, ErrMsg)
  END SUBROUTINE build_bed_model

  LOGICAL FUNCTION unchanged(m, r) RESULT(same)
    !! Every length-dependent field of m equals that of r bit for bit.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: m, r
    same = same_bits(m%l0, r%l0) .AND. same_bits2(m%Mgb, r%Mgb) .AND. same_bits(m%trib, r%trib) .AND. &
           same_bits(m%contact_kn, r%contact_kn) .AND. same_bits(m%contact_cn, r%contact_cn) .AND. &
           same_bits(m%fr_k, r%fr_k) .AND. (m%has_ctrl .EQV. r%has_ctrl)
    IF (same .AND. m%has_ctrl) same = same_bits(m%l0_dot, r%l0_dot)
  END FUNCTION unchanged

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_hanging_payout()
    !! B: a vertical cable hangs from a fixed top node; its two top elements (S = 2 m) are paid
    !! out by 0.5 m on a smooth ramp. At rest the top carries the whole submerged weight
    !! w (L + DeltaL), and the free end hangs L' + w L'**2/(2 EA) below the top. Marched at
    !! rho_inf = 0 (alpha_f = 0) and rho_inf = 0.4 (alpha_f = 2/7, where the committed force
    !! carries weight in the blend): both reach the closed form. (The free end rings axially
    !! through the ramp, and the two spectral radii damp that differently by more than a lag
    !! would shift the tension, so the lag is checked on the taut lines of C and F.)
    INTEGER, PARAMETER :: NE = 10
    REAL(wp), PARAMETER :: L = 10.0_wp, EA = 1.0e5_wp, W = 50.0_wp, RHOA = 10.0_wp, BA = 2000.0_wp
    REAL(wp), PARAMETER :: DL = 0.5_wp, TR = 2.0_wp, TEND = 8.0_wp, DT = 0.01_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: s, z(NE + 1), mz(NE + 1), t_top, lp, z_end, expect
    INTEGER :: i, es, pass
    CHARACTER(300) :: em

    DO pass = 1, 2
      DO i = 1, NE + 1
        s = REAL(i - 1, wp)*L/REAL(NE, wp)
        z(i) = -(L - s) - W*(L*L - s*s)/(2.0_wp*EA)
        mz(i) = 1.0_wp + W*s/EA
      END DO
      CALL vertical_model(m, L/REAL(NE, wp), EA, W, RHOA, BA, z, mz, .FALSE., es, em, &
                          rho_inf=MERGE(0.0_wp, 0.4_wp, pass == 1))
      CALL require(es == CD_HCDYN_OK, 'B: init: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      t_top = top_tension(m)
      CALL require(ABS(t_top - W*L) <= 1.0e-9_wp*W*L, 'B: the seed carries the weight w L')
      CALL march_ramp(m, [NE - 1, NE], DL, 0.0_wp, TR, TEND, DT, .TRUE., es, em)
      CALL require(es == CD_HCDYN_OK, 'B: march: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      lp = L + DL
      expect = W*lp
      t_top = top_tension(m)
      z_end = m%q(3)
      WRITE (*, '(A,I0,A,ES12.5,A,ES12.5)') '  B (pass ', pass, '): top reaction rel. error ', &
        ABS(t_top - expect)/expect, '   free-end position error [m] ', ABS(z_end + lp + W*lp*lp/(2.0_wp*EA))
      CALL require(ABS(t_top - expect) <= 1.0e-6_wp*expect, 'B: top reaction is w (L + DeltaL)')
      CALL require(ABS(z_end + lp + W*lp*lp/(2.0_wp*EA)) <= 1.0e-6_wp, &
                   'B: the free end hangs L'' + w L''**2/(2 EA) below the top')
      CALL require(ALL(ABS(m%l0(NE - 1:NE) - 1.25_wp) <= 2.0_wp*EPSILON(1.0_wp)), &
                   'B: the span elements scaled by (S + DeltaL)/S')
      CALL CD_HermiteCable_Dyn_End(m)
    END DO
  END SUBROUTINE check_hanging_payout

  SUBROUTINE check_taut_haul_in()
    !! C: a vertical cable between fixed ends H = 10.1 m apart; its two top elements are
    !! hauled in by 0.2 m. At rest the top tension is EA (H - L')/L' + w L'/2. Marched at
    !! rho_inf = 0 and 0.4, as B: both reach the closed form, and through the ramp the top
    !! tension of the two follows the same path, to a few per cent of the per-step tension
    !! change (a committed force taken at the new lengths would lag the alpha_f > 0 run by
    !! alpha_f = 2/7 of it).
    INTEGER, PARAMETER :: NE = 10
    REAL(wp), PARAMETER :: L = 10.0_wp, H = 10.1_wp, EA = 1.0e5_wp, W = 50.0_wp, RHOA = 10.0_wp
    REAL(wp), PARAMETER :: BA = 2000.0_wp, DL = -0.2_wp, TR = 2.0_wp, TEND = 8.0_wp, DT = 0.01_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: s, z(NE + 1), mz(NE + 1), tb, t_top, lp, expect, hist(NINT(TEND/DT), 2), d_step, diff
    INTEGER :: i, es, pass
    CHARACTER(300) :: em

    DO pass = 1, 2
      tb = EA*(H - L)/L - W*L/2.0_wp
      DO i = 1, NE + 1
        s = REAL(i - 1, wp)*L/REAL(NE, wp)
        z(i) = s + (tb*s + W*s*s/2.0_wp)/EA
        mz(i) = 1.0_wp + (tb + W*s)/EA
      END DO
      CALL vertical_model(m, L/REAL(NE, wp), EA, W, RHOA, BA, z, mz, .TRUE., es, em, &
                          rho_inf=MERGE(0.0_wp, 0.4_wp, pass == 1))
      CALL require(es == CD_HCDYN_OK, 'C: init: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      t_top = top_tension(m)
      expect = EA*(H - L)/L + W*L/2.0_wp
      CALL require(ABS(t_top - expect) <= 1.0e-9_wp*expect, 'C: the seed carries EA (H - L)/L + w L/2')
      CALL march_ramp(m, [NE - 1, NE], DL, 0.0_wp, TR, TEND, DT, .TRUE., es, em, hist(:, pass))
      CALL require(es == CD_HCDYN_OK, 'C: march: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      lp = L + DL
      expect = EA*(H - lp)/lp + W*lp/2.0_wp
      t_top = top_tension(m)
      WRITE (*, '(A,I0,A,ES12.5)') '  C (pass ', pass, '): top tension rel. error ', ABS(t_top - expect)/expect
      CALL require(ABS(t_top - expect) <= 1.0e-6_wp*expect, 'C: top tension is EA (H - L'')/L'' + w L''/2')
      CALL CD_HermiteCable_Dyn_End(m)
    END DO
    ! the largest per-step change of the quasi-static tension EA H/L'(t), at the shortest L'
    lp = L + DL
    d_step = EA*H*ABS(DL)*0.5_wp*(PI/TR)*DT/(lp*lp)
    diff = MAXVAL(ABS(hist(:, 2) - hist(:, 1)))
    WRITE (*, '(A,ES10.3,A,ES12.5)') '  C: per-step tension change ', d_step, &
      ' N; max difference between rho_inf = 0.4 and 0 ', diff
    CALL require(diff <= 5.0e-2_wp*d_step, 'C: the alpha_f > 0 ramp follows the alpha_f = 0 one (no lag)')
  END SUBROUTINE check_taut_haul_in

  SUBROUTINE check_payout_rate_lag()
    !! D: a weightless cable between fixed ends H = 10.1 m apart (initial strain 1 %); its two
    !! top elements are paid out at Ldot = 0.01 m/s from t = 0. The strain stays uniform,
    !! eps = H/L' - 1, so the Kelvin-Voigt tension is EA eps + BA d(eps)/dt
    !! = EA (H/L' - 1) - BA H Ldot/L'**2: the damping lag. Withholding the length rate puts a
    !! spurious stretch rate on the span and misses it.
    INTEGER, PARAMETER :: NE = 10
    REAL(wp), PARAMETER :: L = 10.0_wp, H = 10.1_wp, EA = 1.0e5_wp, RHOA = 1.0_wp, BA = 1.0e5_wp
    REAL(wp), PARAMETER :: LDOT = 0.01_wp, TEND = 4.0_wp, DT = 0.01_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: s, z(NE + 1), mz(NE + 1), err_rate, err_norate, lag
    INTEGER :: i, es, pass
    CHARACTER(300) :: em

    lag = BA*H*LDOT/(L + LDOT*TEND)**2
    DO pass = 1, 2
      DO i = 1, NE + 1
        s = REAL(i - 1, wp)*L/REAL(NE, wp)
        z(i) = s*H/L
        mz(i) = H/L
      END DO
      CALL vertical_model(m, L/REAL(NE, wp), EA, 0.0_wp, RHOA, BA, z, mz, .TRUE., es, em)
      CALL require(es == CD_HCDYN_OK, 'D: init: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      IF (pass == 1) THEN
        CALL march_rate(m, [NE - 1, NE], LDOT, .TRUE., TEND, DT, H, EA, BA, err_rate, es, em)
        CALL require(es == CD_HCDYN_OK, 'D: march: '//TRIM(em))
      ELSE
        CALL march_rate(m, [NE - 1, NE], LDOT, .FALSE., TEND, DT, H, EA, BA, err_norate, es, em)
        CALL require(es == CD_HCDYN_OK, 'D: march without the rate: '//TRIM(em))
      END IF
      CALL CD_HermiteCable_Dyn_End(m)
    END DO
    WRITE (*, '(A,ES10.3,A,ES12.5,A,ES12.5)') '  D: damping lag ', lag, ' N; max tension error with the rate ', &
      err_rate, ' N, without ', err_norate
    CALL require(err_rate <= 1.0e-2_wp*lag, 'D: tension follows EA (H/L'' - 1) - BA H Ldot/L''**2')
    CALL require(err_norate > 0.2_wp*lag, 'D: without the length rate the damping tension is wrong')
  END SUBROUTINE check_payout_rate_lag

  SUBROUTINE check_slow_ramp_static()
    !! E: a slack planar cable (10.4 m between ends 10 m apart, EI > 0) sagging under its
    !! weight; its three top elements are hauled in by 0.2 m on a slow ramp and the line
    !! settles. The end state is the static equilibrium of the edited lengths
    !! (CD_HermiteCable_Static_Solve, seeded from the initial equilibrium).
    INTEGER, PARAMETER :: NE = 12, NN = NE + 1, NDOF = 6*NN
    REAL(wp), PARAMETER :: LTOT = 10.4_wp, EA = 1.0e6_wp, EI = 50.0_wp, W = 20.0_wp, RHOA = 2.0_wp
    REAL(wp), PARAMETER :: BA = 1.0e4_wp, SAG = 1.3_wp, DL = -0.2_wp, TR = 10.0_wp, TEND = 60.0_wp, DT = 0.05_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(NE), seed(NDOF), q_static(NDOF), q_edit(NDOF), curv(NN), res, t, dx(3), dist, err
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER :: i, es, iters, k
    CHARACTER(300) :: em

    l0 = LTOT/REAL(NE, wp)
    ! end translations, then the out-of-plane DOFs (m_y everywhere, r_y in the interior)
    fixed = [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3, (6*(i - 1) + 5, i=1, NN), (6*(i - 1) + 2, i=2, NN - 1)]
    ! parabolic sag below the chord from (0, 0, 0) to (8, 0, 6)
    DO i = 1, NN
      t = REAL(i - 1, wp)/REAL(NE, wp)
      seed(6*(i - 1) + 1:6*(i - 1) + 3) = [8.0_wp*t, 0.0_wp, 6.0_wp*t - 4.0_wp*SAG*t*(1.0_wp - t)]
      dx = [8.0_wp, 0.0_wp, 6.0_wp - 4.0_wp*SAG*(1.0_wp - 2.0_wp*t)]
      seed(6*(i - 1) + 4:6*(i - 1) + 6) = dx/NORM2(dx)
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, [(EA, k=1, NE)], [(EI, k=1, NE)], [(W, k=1, NE)], seed, fixed, &
                                      -1.0e3_wp, 0.0_wp, 4, 200, 1.0e-10_wp, 1.0_wp, q_static, curv, res, iters, &
                                      es, em)
    CALL require(es == CD_HCSTAT_OK, 'E: initial static solve: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL require(q_static(6*(NE/2) + 3) < 3.0_wp - 0.5_wp, 'E: the initial equilibrium sags below the chord')
    CALL CD_HermiteCable_Dyn_Init(m, l0, [(EA, k=1, NE)], [(EI, k=1, NE)], [(RHOA, k=1, NE)], [(W, k=1, NE)], &
                                  q_static, fixed, -1.0e3_wp, 0.0_wp, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'E: init: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(m, [(BA, k=1, NE)], es, em)
    CALL CD_HermiteCable_Dyn_Set_Drag(m, 1025.0_wp, [(0.2_wp, k=1, NE)], [(2.0_wp, k=1, NE)], &
                                      [(0.5_wp, k=1, NE)], 100.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK, 'E: drag: '//TRIM(em))
    CALL march_ramp(m, [NE - 2, NE - 1, NE], DL, 0.0_wp, TR, TEND, DT, .TRUE., es, em)
    CALL require(es == CD_HCDYN_OK, 'E: march: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    l0(NE - 2:NE) = l0(NE - 2:NE)*((3.0_wp*l0(NE) + DL)/(3.0_wp*l0(NE)))
    CALL CD_HermiteCable_Static_Solve(l0, [(EA, k=1, NE)], [(EI, k=1, NE)], [(W, k=1, NE)], q_static, fixed, &
                                      -1.0e3_wp, 0.0_wp, 1, 200, 1.0e-10_wp, 1.0_wp, q_edit, curv, res, iters, &
                                      es, em)
    CALL require(es == CD_HCSTAT_OK, 'E: static solve at the edited lengths: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    err = 0.0_wp
    dist = 0.0_wp
    DO i = 1, NN
      err = MAX(err, NORM2(m%q(6*(i - 1) + 1:6*(i - 1) + 3) - q_edit(6*(i - 1) + 1:6*(i - 1) + 3)))
      dist = MAX(dist, NORM2(q_static(6*(i - 1) + 1:6*(i - 1) + 3) - q_edit(6*(i - 1) + 1:6*(i - 1) + 3)))
    END DO
    WRITE (*, '(A,ES12.5,A,ES12.5,A)') '  E: end state vs static solve ', err, ' m (the haul-in moves nodes up to ', &
      dist, ' m)'
    CALL require(dist > 0.1_wp, 'E: the haul-in moves the line')
    CALL require(err <= 1.0e-5_wp*dist, 'E: the settled end state is the static equilibrium of the edited lengths')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_slow_ramp_static

  SUBROUTINE check_payout_alpha_f()
    !! F: the cable of D paid out at Ldot = 0.01 m/s, marched with rho_inf = 0.4
    !! (alpha_f = 2/7) and with rho_inf = 0 (alpha_f = 0). The force-blended residual weighs
    !! the committed force F_n by alpha_f; F_n is the force at the lengths of the step that
    !! reached the committed state, so the blend tracks the quasi-static tension
    !! EA (H/L' - 1) - BA H Ldot/L'**2 at either alpha_f. Evaluating F_n with the new lengths
    !! instead lags the tension by a fixed fraction of the per-step change
    !! dT = EA H Ldot dt/L'**2 (the pay-out ramp artifact this check guards against).
    INTEGER, PARAMETER :: NE = 10
    REAL(wp), PARAMETER :: L = 10.0_wp, H = 10.1_wp, EA = 1.0e5_wp, RHOA = 1.0_wp, BA = 1.0e5_wp
    REAL(wp), PARAMETER :: LDOT = 0.01_wp, TEND = 4.0_wp, DT = 0.01_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: s, z(NE + 1), mz(NE + 1), err(3), t_hist(NINT(TEND/DT), 3), d_step, diff
    INTEGER :: i, es, pass
    CHARACTER(300) :: em

    d_step = EA*H*LDOT*DT/(L + LDOT*TEND)**2
    DO pass = 1, 3
      DO i = 1, NE + 1
        s = REAL(i - 1, wp)*L/REAL(NE, wp)
        z(i) = s*H/L
        mz(i) = H/L
      END DO
      CALL vertical_model(m, L/REAL(NE, wp), EA, 0.0_wp, RHOA, BA, z, mz, .TRUE., es, em, &
                          rho_inf=MERGE(0.0_wp, 0.4_wp, pass == 2))
      CALL require(es == CD_HCDYN_OK, 'F: init: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      ! pass 3 drops the committed force reused from the preceding step before every step, so
      ! each step evaluates it afresh at the committed lengths
      CALL march_rate(m, [NE - 1, NE], LDOT, .TRUE., TEND, DT, H, EA, BA, err(pass), es, em, t_hist(:, pass), &
                      fresh_force=pass == 3)
      CALL require(es == CD_HCDYN_OK, 'F: march: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_End(m)
      IF (es /= CD_HCDYN_OK) RETURN
    END DO
    diff = MAXVAL(ABS(t_hist(NINT(1.0_wp/DT):, 1) - t_hist(NINT(1.0_wp/DT):, 2)))
    WRITE (*, '(A,ES10.3,A,ES12.5,A,ES12.5,A,ES12.5)') '  F: per-step tension change ', d_step, &
      ' N; max error vs the closed form at alpha_f = 2/7 ', err(1), ' N, at alpha_f = 0 ', err(2), &
      ' N; max difference ', diff
    CALL require(err(1) <= 2.0e-2_wp*d_step, 'F: at alpha_f > 0 the tension follows the quasi-static closed form')
    CALL require(err(2) <= 2.0e-2_wp*d_step, 'F: at alpha_f = 0 the tension follows the quasi-static closed form')
    WRITE (*, '(A,ES12.5,A)') '  F: with the committed force evaluated afresh each step, max error ', err(3), ' N'
    CALL require(err(3) <= 2.0e-2_wp*d_step, &
                 'F: a committed force evaluated afresh (not reused) is taken at the committed lengths')
    CALL require(diff <= 2.0e-2_wp*d_step, 'F: the tension at alpha_f > 0 equals the one at alpha_f = 0')
  END SUBROUTINE check_payout_alpha_f

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE vertical_model(model, l, ea, w, rhoa, ba, z, mz, fix_bottom, ErrStat, ErrMsg, rho_inf)
    !! A vertical cable along z (node 1 at the bottom, the last node at the fixed top) held in
    !! every transverse DOF, so only r_z and m_z move: an axial bar under weight w. rho_inf
    !! (default 0) is the generalised-alpha spectral radius.
    TYPE(CD_HermiteCableDynType), INTENT(OUT) :: model
    REAL(wp), INTENT(IN) :: l, ea, w, rhoa, ba, z(:), mz(:)
    LOGICAL, INTENT(IN) :: fix_bottom
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: rho_inf
    REAL(wp), ALLOCATABLE :: q(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER :: nn, ne, i, k
    REAL(wp) :: rho
    nn = SIZE(z)
    ne = nn - 1
    ALLOCATE (q(6*nn))
    q = 0.0_wp
    fixed = [INTEGER ::]
    DO i = 1, nn
      q(6*(i - 1) + 3) = z(i)
      q(6*(i - 1) + 6) = mz(i)
      fixed = [fixed, 6*(i - 1) + 1, 6*(i - 1) + 2, 6*(i - 1) + 4, 6*(i - 1) + 5]
    END DO
    fixed = [fixed, 6*nn - 3]
    IF (fix_bottom) fixed = [fixed, 3]
    rho = 0.0_wp
    IF (PRESENT(rho_inf)) rho = rho_inf
    CALL CD_HermiteCable_Dyn_Init(model, [(l, k=1, ne)], [(ea, k=1, ne)], [(1.0_wp, k=1, ne)], &
                                  [(rhoa, k=1, ne)], [(w, k=1, ne)], q, fixed, -1.0e3_wp, 0.0_wp, rho, &
                                  ErrStat, ErrMsg)
    IF (ErrStat /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Set_Axial_Damping(model, [(ba, k=1, ne)], ErrStat, ErrMsg)
  END SUBROUTINE vertical_model

  SUBROUTINE march_ramp(model, span, dl_final, dl_start, tr, tend, dt, with_rate, ErrStat, ErrMsg, tension)
    !! March to tend, changing the span's total length from its base S by
    !! dl(t) = dl_start + (dl_final - dl_start) (1 - cos(pi t/tr))/2 over [0, tr] and holding it
    !! after; each element scales by (S + dl)/S, with rate dl_dot l_e/S, before each step
    !! (and, optionally, return the top tension after every step).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: span(:)
    REAL(wp), INTENT(IN) :: dl_final, dl_start, tr, tend, dt
    LOGICAL, INTENT(IN) :: with_rate
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: tension(:)
    REAL(wp) :: base(SIZE(span)), s_base, t, dl, dldot
    INTEGER :: n, k
    base = model%l0(span)
    s_base = SUM(base)
    n = NINT(tend/dt)
    DO k = 1, n
      t = REAL(k, wp)*dt
      IF (t < tr) THEN
        dl = dl_start + (dl_final - dl_start)*0.5_wp*(1.0_wp - COS(PI*t/tr))
        dldot = (dl_final - dl_start)*0.5_wp*(PI/tr)*SIN(PI*t/tr)
      ELSE
        dl = dl_final
        dldot = 0.0_wp
      END IF
      IF (.NOT. with_rate) dldot = 0.0_wp
      CALL CD_HermiteCable_Dyn_Set_SegmentLength(model, span, base*((s_base + dl)/s_base), dldot*base/s_base, &
                                                 ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      CALL CD_HermiteCable_Dyn_Step(model, dt, 50, 1.0e-10_wp, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      IF (PRESENT(tension)) tension(k) = top_tension(model)
    END DO
  END SUBROUTINE march_ramp

  SUBROUTINE march_rate(model, span, ldot, with_rate, tend, dt, h, ea, ba, err_max, ErrStat, ErrMsg, tension, &
                        fresh_force)
    !! March a constant pay-out of the span (rate passed when with_rate) and return the largest
    !! deviation of the top tension from EA (H/L' - 1) - BA H Ldot/L'**2 after the first second
    !! (and, optionally, the top tension after every step). fresh_force drops the committed
    !! force cached by the preceding step before each step (re-selecting the force blend does).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    INTEGER, INTENT(IN) :: span(:)
    REAL(wp), INTENT(IN) :: ldot, tend, dt, h, ea, ba
    LOGICAL, INTENT(IN) :: with_rate
    REAL(wp), INTENT(OUT) :: err_max
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: tension(:)
    LOGICAL, INTENT(IN), OPTIONAL :: fresh_force
    REAL(wp) :: base(SIZE(span)), s_base, l_total, t, lp, rate, expect
    INTEGER :: n, k
    LOGICAL :: fresh
    fresh = .FALSE.
    IF (PRESENT(fresh_force)) fresh = fresh_force
    base = model%l0(span)
    s_base = SUM(base)
    l_total = SUM(model%l0)
    err_max = 0.0_wp
    rate = 0.0_wp
    IF (with_rate) rate = ldot
    n = NINT(tend/dt)
    DO k = 1, n
      t = REAL(k, wp)*dt
      CALL CD_HermiteCable_Dyn_Set_SegmentLength(model, span, base*((s_base + ldot*t)/s_base), rate*base/s_base, &
                                                 ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      IF (fresh) THEN
        CALL CD_HermiteCable_Dyn_Set_ForceBlend(model, .TRUE., ErrStat, ErrMsg)
        IF (ErrStat /= CD_HCDYN_OK) RETURN
      END IF
      CALL CD_HermiteCable_Dyn_Step(model, dt, 50, 1.0e-6_wp, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HCDYN_OK) RETURN
      IF (PRESENT(tension)) tension(k) = top_tension(model)
      IF (t < 1.0_wp) CYCLE
      lp = l_total + ldot*t
      expect = ea*(h/lp - 1.0_wp) - ba*h*ldot/(lp*lp)
      err_max = MAX(err_max, ABS(top_tension(model) - expect))
    END DO
  END SUBROUTINE march_rate

  REAL(wp) FUNCTION top_tension(model) RESULT(t)
    !! Axial pull of the line on its fixed top node (the last node).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: model
    REAL(wp) :: f(3)
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_HermiteCable_Dyn_Reaction(model, model%nn, f, es, em)
    t = -f(3)
    IF (es /= CD_HCDYN_OK) t = HUGE(1.0_wp)
  END FUNCTION top_tension

  LOGICAL FUNCTION same_bits(x, y) RESULT(same)
    REAL(wp), INTENT(IN) :: x(:), y(:)
    same = SIZE(x) == SIZE(y)
    IF (same) same = ALL(TRANSFER(x, 0_INT64, SIZE(x)) == TRANSFER(y, 0_INT64, SIZE(y)))
  END FUNCTION same_bits

  LOGICAL FUNCTION same_bits2(x, y) RESULT(same)
    REAL(wp), INTENT(IN) :: x(:, :), y(:, :)
    same = SIZE(x, 1) == SIZE(y, 1) .AND. SIZE(x, 2) == SIZE(y, 2)
    IF (same) same = same_bits(RESHAPE(x, [SIZE(x)]), RESHAPE(y, [SIZE(y)]))
  END FUNCTION same_bits2

  SUBROUTINE require(condition, message)
    LOGICAL, INTENT(IN) :: condition
    CHARACTER(*), INTENT(IN) :: message
    IF (.NOT. condition) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'MISMATCH: '//TRIM(message)
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_cable_control
