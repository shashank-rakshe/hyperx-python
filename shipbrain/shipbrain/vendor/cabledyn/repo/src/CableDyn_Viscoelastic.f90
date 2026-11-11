! File: src/CableDyn_Viscoelastic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Viscoelastic
  !! The MoorDyn viscoelastic line model (ElasticMod 2) is a four-parameter
  !! series-Kelvin solid. A fast Voigt branch (EA_D parallel to BA_D) is in
  !! series with a slow Voigt branch (EA_1 parallel to BA). The standard linear
  !! solid is recovered only for BA_D = 0. The relation
  !! EA_1 = EA_D*EA/(EA_D - EA) makes the static composite stiffness EA.
  !! Each segment carries the slow-branch
  !! stretch dl_1 as an internal STATE with the linear ODE
  !!
  !!   ld_1 = (EA_D*dl - (EA_D + EA_1)*dl_1 + BA_D*lstrd) / (BA_D + BA)
  !!
  !! (dl = lstr - l0), and the segment force is MagT = EA_1*dl_1/l0 plus the
  !! damping MagTd = BA*ld_1/l0, as in MoorDyn (Hall, Duong & Lozon, 2023).
  !!
  !! Slack ("cable can't push"): MoorDyn zeroes MagT when dl < 0 but keeps MagTd,
  !! which is discontinuous whenever dl_1 /= 0 at the switch and can report a
  !! compressive tension. CableDyn applies tension-only complementarity to the
  !! WHOLE series chain instead: T = max(MagT + MagTd, 0), and while T = 0 the slow
  !! branch relaxes under zero load (BA*ld_1 + EA_1*dl_1 = 0). The two agree
  !! whenever the MoorDyn tension is non-negative with dl >= 0; at the switch the
  !! taut and slack states coincide, so force and state are continuous for Newton.
  !!
  !! CableDyn integrates IMPLICITLY: inside a step of size dt the state ODE is
  !! LINEAR in dl_1 given the endpoint kinematics, so backward Euler eliminates
  !! it locally in closed form,
  !!
  !!   dl_1(q, v) = (dl_1_n + dt*(EA_D*dl + BA_D*lstrd)/B) / (1 + dt*(EA_D+EA_1)/B)
  !!
  !! with B = BA_D + BA, giving a consistent (q, v)-dependent element load with
  !! chain-rule Jacobians -- the same contributor shape as the axial damping.
  !! The committed dl_1 advances once per successful step from the converged
  !! kinematics (never at Newton iterates).
  USE CableDyn_Precision, ONLY: wp, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Viscoelastic_Params
  PUBLIC :: CD_Viscoelastic_LoadDependent_EAD
  PUBLIC :: CD_Viscoelastic_Steady_State
  PUBLIC :: CD_Viscoelastic_Element_Load
  PUBLIC :: CD_Viscoelastic_Element_Force
  PUBLIC :: CD_Viscoelastic_Element_Tension
  PUBLIC :: CD_Viscoelastic_State_Advance
  INTEGER, PARAMETER, PUBLIC :: CD_VISCO_OK = 0, CD_VISCO_BADINPUT = 1

  REAL(wp), PARAMETER :: CD_ZERO = 0.0_wp, CD_ONE = 1.0_wp
  ! exported so callers staging a two-pass commit can pre-validate element
  ! lengths against the EXACT threshold the advance itself applies
  REAL(wp), PARAMETER, PUBLIC :: CD_VISCO_TINY_LEN = 1.0e-12_wp
  ! Relative input uncertainty is amplified approximately by
  ! (EA_D + EA)/(EA_D - EA) when the derived series spring is formed. Reject
  ! parameter pairs above this explicit conditioning limit rather than creating
  ! an arbitrarily stiff and input-sensitive internal branch.
  REAL(wp), PARAMETER, PUBLIC :: CD_VISCO_MAX_SERIES_CONDITION = 1.0e3_wp
  REAL(wp), PARAMETER :: TINY_LEN = CD_VISCO_TINY_LEN

CONTAINS

  SUBROUTINE CD_Viscoelastic_Params(ea, ea_d, ba, ba_d, ea_1, ErrStat, ErrMsg)
    !! Derive the static-branch spring EA_1 = EA_D*EA/(EA_D - EA) and validate
    !! the physical and numerical admissibility conditions. EA_D <= EA violates
    !! the fast-stiffer-than-static premise, whilst EA_D close to EA makes the
    !! inferred EA_1 ill-conditioned.
    REAL(wp), INTENT(IN) :: ea, ea_d, ba, ba_d
    REAL(wp), INTENT(OUT) :: ea_1
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: stiffness_condition
    ErrStat = CD_VISCO_OK
    ErrMsg = ''
    ea_1 = CD_ZERO
    IF (.NOT. (CD_Is_Finite(ea) .AND. CD_Is_Finite(ea_d) .AND. &
               CD_Is_Finite(ba) .AND. CD_Is_Finite(ba_d))) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic parameters must be finite')
      RETURN
    END IF
    IF (ea <= CD_ZERO .OR. ea_d <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic EA and EA_D must be positive')
      RETURN
    END IF
    IF (ea_d <= ea) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic dynamic stiffness must exceed the static stiffness '// &
                '(EA_D > EA; equality gives an infinite series spring)')
      RETURN
    END IF
    stiffness_condition = (ea_d + ea)/(ea_d - ea)
    IF (.NOT. CD_Is_Finite(stiffness_condition) .OR. &
        stiffness_condition > CD_VISCO_MAX_SERIES_CONDITION) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic EA_D and EA are too close to form a well-conditioned '// &
                'series spring; reduce the stiffness-condition ratio or use a directly fitted model')
      RETURN
    END IF
    IF (ba < CD_ZERO .OR. ba_d < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic BA and BA_D must be non-negative')
      RETURN
    END IF
    IF (ba + ba_d <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'the viscoelastic state ODE needs BA + BA_D > 0 (a zero-damping '// &
                'series-Kelvin solid is then a plain spring; use ElasticMod 1)')
      RETURN
    END IF
    ea_1 = ea_d*ea/(ea_d - ea)
  END SUBROUTINE CD_Viscoelastic_Params

  SUBROUTINE CD_Viscoelastic_LoadDependent_EAD(ea, l0, alpha_mbl, vbeta, dl_1, ea_d, ErrStat, ErrMsg)
    !! The mean-load-dependent dynamic stiffness of MoorDyn's ElasticMod 3
    !! (MoorDyn_Line.f90, from the IOWTC2023 paper's eqns. 2 + 10 with mean load
    !! k1*dl_1/MBL): for dl_1 > 0,
    !!
    !!   EA_D = 0.5*(alphaMBL + vbeta*dl_1*(EA/l0) + EA
    !!          + sqrt(alphaMBL^2 + 2*alphaMBL*(EA/l0)*(vbeta*dl_1 - l0)
    !!                 + (EA/l0)^2*(vbeta*dl_1 + l0)^2)),
    !!
    !! and EA_D = alphaMBL at dl_1 <= 0 (zero mean load). MoorDyn merely WARNS
    !! when the resulting EA_D fails the model premise; here EA_D <= EA fails
    !! CLOSED -- a violated premise makes the series spring EA_1 negative and
    !! the eliminated state ODE ill-posed.
    REAL(wp), INTENT(IN) :: ea, l0, alpha_mbl, vbeta, dl_1
    REAL(wp), INTENT(OUT) :: ea_d
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: k, disc
    ErrStat = CD_VISCO_OK
    ErrMsg = ''
    ea_d = CD_ZERO
    IF (.NOT. (CD_Is_Finite(ea) .AND. ea > CD_ZERO .AND. CD_Is_Finite(l0) .AND. l0 > CD_ZERO .AND. &
               CD_Is_Finite(alpha_mbl) .AND. alpha_mbl > CD_ZERO .AND. &
               CD_Is_Finite(vbeta) .AND. vbeta > CD_ZERO .AND. CD_Is_Finite(dl_1))) THEN
      CALL fail(ErrStat, ErrMsg, 'load-dependent stiffness needs finite inputs with '// &
                'positive EA, l0, alphaMBL, and vbeta')
      RETURN
    END IF
    IF (dl_1 > CD_ZERO) THEN
      k = ea/l0
      disc = alpha_mbl*alpha_mbl + 2.0_wp*alpha_mbl*k*(vbeta*dl_1 - l0) + &
             (k*(vbeta*dl_1 + l0))**2
      ea_d = 0.5_wp*(alpha_mbl + vbeta*dl_1*k + ea + SQRT(disc))
    ELSE
      ea_d = alpha_mbl
    END IF
    IF (.NOT. CD_Is_Finite(ea_d) .OR. ea_d <= ea) THEN
      CALL fail(ErrStat, ErrMsg, 'load-dependent dynamic stiffness fell to or below the static EA '// &
                '(the ElasticMod 3 premise alphaMBL > Es is violated at the current state)')
      ea_d = CD_ZERO
    END IF
  END SUBROUTINE CD_Viscoelastic_LoadDependent_EAD

  SUBROUTINE CD_Viscoelastic_Steady_State(ea, ea_d, dl, dl_1_ss)
    !! The zero-rate partition of a held stretch: ld_1 = 0 gives
    !! dl_1* = dl*(EA_D - EA)/EA_D (using EA_D + EA_1 = EA_D^2/(EA_D - EA)),
    !! at which the reported tension is EXACTLY the static composite EA*dl/l0.
    !! This is the CableDyn initial condition: MoorDyn seeds dl_1 = dl and
    !! relaxes it here over its TmaxIC window before t = 0; CableDyn's static
    !! equilibrium is the dynamic fixed point, so the state starts settled.
    REAL(wp), INTENT(IN) :: ea, ea_d, dl
    REAL(wp), INTENT(OUT) :: dl_1_ss
    dl_1_ss = dl*(ea_d - ea)/ea_d
  END SUBROUTINE CD_Viscoelastic_Steady_State

  SUBROUTINE CD_Viscoelastic_Element_Load(qa, qb, va, vb, l0, ea_d, ea_1, ba, ba_d, &
                                          dl_1_n, dt, force, jac_q, jac_v, ErrStat, ErrMsg, dl_1_out)
    !! The implicit viscoelastic element load at the CURRENT kinematics: the
    !! backward-Euler-eliminated state dl_1(q, v), the segment tension
    !! max(MagT + MagTd, 0) with MagT = EA_1*dl_1/l0 and MagTd = BA*ld_1/l0 along
    !! the unit tangent, and the exact chain-rule Jacobians -dF/dq, -dF/dv in the
    !! residual convention of the axial-damping contributor (force on node a
    !! positive toward b under tension). dl_1_out reports the eliminated state so
    !! the step commit can advance it from the converged kinematics. dt = 0 is
    !! the INSTANTANEOUS limit (dl_1 frozen at dl_1_n, ld_1 from the ODE right-
    !! hand side) used for initial-acceleration, coupled-load, and tension
    !! queries at a committed state; the formulas below reduce to it exactly.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3)
    REAL(wp), INTENT(IN) :: l0, ea_d, ea_1, ba, ba_d, dl_1_n, dt
    REAL(wp), INTENT(OUT) :: force(6), jac_q(6, 6), jac_v(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: dl_1_out

    REAL(wp) :: chord(3), tang(3), rel(3), length, lstrd, dl, bsum, den
    REAL(wp) :: dl1, ld1, magt, magtd, coefT
    REAL(wp) :: ddl1_ddl, ddl1_dlstrd, dld1_ddl1, dld1_ddl, dld1_dlstrd
    REAL(wp) :: dmag_ddl, dmag_dlstrd
    REAL(wp) :: eye(3, 3), tt(3, 3), pmat(3, 3), dq(3, 3), dv(3, 3)
    INTEGER :: i

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    IF (PRESENT(dl_1_out)) dl_1_out = dl_1_n
    ErrStat = CD_VISCO_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(qa) .AND. CD_All_Finite(qb) .AND. &
               CD_All_Finite(va) .AND. CD_All_Finite(vb) .AND. &
               CD_Is_Finite(dl_1_n) .AND. CD_Is_Finite(dt) .AND. dt >= CD_ZERO .AND. &
               CD_Is_Finite(l0) .AND. l0 > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic element inputs must be finite (dt >= 0, l0 positive)')
      RETURN
    END IF
    chord = qb - qa
    length = NORM2(chord)
    IF (length <= TINY_LEN) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic element collapsed to zero length')
      RETURN
    END IF
    tang = chord/length
    rel = vb - va
    lstrd = DOT_PRODUCT(tang, rel)
    dl = length - l0
    bsum = ba_d + ba
    den = CD_ONE + dt*(ea_d + ea_1)/bsum

    ! backward-Euler local elimination of the state ODE
    dl1 = (dl_1_n + dt*(ea_d*dl + ba_d*lstrd)/bsum)/den
    ld1 = (ea_d*dl - (ea_d + ea_1)*dl1 + ba_d*lstrd)/bsum
    IF (PRESENT(dl_1_out)) dl_1_out = dl1

    ddl1_ddl = (dt*ea_d/bsum)/den
    ddl1_dlstrd = (dt*ba_d/bsum)/den
    dld1_ddl1 = -(ea_d + ea_1)/bsum
    dld1_ddl = ea_d/bsum + dld1_ddl1*ddl1_ddl
    dld1_dlstrd = ba_d/bsum + dld1_ddl1*ddl1_dlstrd

    magt = ea_1*dl1/l0
    dmag_ddl = (ea_1/l0)*ddl1_ddl
    dmag_dlstrd = (ea_1/l0)*ddl1_dlstrd
    magtd = ba*ld1/l0
    dmag_ddl = dmag_ddl + (ba/l0)*dld1_ddl
    dmag_dlstrd = dmag_dlstrd + (ba/l0)*dld1_dlstrd

    coefT = magt + magtd
    IF (coefT < CD_ZERO) THEN
      ! Tension-only chain: the series solid cannot push. The segment carries T = 0 and
      ! the slow branch relaxes under that zero load, BA*ld_1 + EA_1*dl_1 = 0 (backward
      ! Euler below). At the switch T = 0 the taut elimination gives exactly this state,
      ! so force and state are continuous and Newton sees a kink, not a jump.
      coefT = CD_ZERO
      dmag_ddl = CD_ZERO
      dmag_dlstrd = CD_ZERO
      IF (PRESENT(dl_1_out)) dl_1_out = slack_state(dl_1_n, ea_1, ba, dt)
    END IF
    force(1:3) = coefT*tang
    force(4:6) = -coefT*tang

    eye = CD_ZERO
    DO i = 1, 3
      eye(i, i) = CD_ONE
    END DO
    tt = outer(tang, tang)
    pmat = (eye - tt)/length

    ! d(force_a)/d(qb) = tang * (dcoef/dlength) * tang^T
    !                  + tang * (dcoef/dlstrd) * (d lstrd/d qb)^T + coefT * d(tang)/d(qb)
    ! with d(length)/d(qb) = tang, d(lstrd)/d(qb) = P*rel/1 (through tang), d(tang)/d(qb) = P/length.
    dq = outer(tang, dmag_ddl*tang + dmag_dlstrd*MATMUL(pmat, rel)) + coefT*pmat
    dv = dmag_dlstrd*tt

    ! residual-Jacobian convention of the damping contributor (jac = -dF/dq):
    ! dq/dv above are dF_a/d(qb) and dF_a/d(vb); the chord is qb - qa, so the
    ! a-columns carry the opposite sign, and F_b = -F_a mirrors the rows.
    jac_q(1:3, 1:3) = dq
    jac_q(1:3, 4:6) = -dq
    jac_q(4:6, 1:3) = -dq
    jac_q(4:6, 4:6) = dq
    jac_v(1:3, 1:3) = dv
    jac_v(1:3, 4:6) = -dv
    jac_v(4:6, 1:3) = -dv
    jac_v(4:6, 4:6) = dv
  END SUBROUTINE CD_Viscoelastic_Element_Load

  SUBROUTINE CD_Viscoelastic_Element_Force(qa, qb, va, vb, l0, ea_d, ea_1, ba, ba_d, &
                                           dl_1_n, dt, force, ErrStat, ErrMsg)
    !! Force-only evaluation for line-search and initial-acceleration paths: the
    !! SAME formulas as CD_Viscoelastic_Element_Load with the Jacobians discarded
    !! (one formula source; the load/advance consistency gate pins the state).
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3)
    REAL(wp), INTENT(IN) :: l0, ea_d, ea_1, ba, ba_d, dl_1_n, dt
    REAL(wp), INTENT(OUT) :: force(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: jq(6, 6), jv(6, 6)
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, l0, ea_d, ea_1, ba, ba_d, &
                                      dl_1_n, dt, force, jq, jv, ErrStat, ErrMsg)
  END SUBROUTINE CD_Viscoelastic_Element_Force

  SUBROUTINE CD_Viscoelastic_Element_Tension(qa, qb, va, vb, l0, ea_d, ea_1, ba, ba_d, &
                                             dl_1_n, tension, ErrStat, ErrMsg)
    !! Signed segment tension MagT + MagTd at a COMMITTED state (the
    !! instantaneous dt = 0 limit): the along-tangent component of the element
    !! force on node a, matching MoorDyn's reported viscoelastic tension.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3)
    REAL(wp), INTENT(IN) :: l0, ea_d, ea_1, ba, ba_d, dl_1_n
    REAL(wp), INTENT(OUT) :: tension
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: force(6), jq(6, 6), jv(6, 6), chord(3), length
    tension = CD_ZERO
    CALL CD_Viscoelastic_Element_Load(qa, qb, va, vb, l0, ea_d, ea_1, ba, ba_d, &
                                      dl_1_n, CD_ZERO, force, jq, jv, ErrStat, ErrMsg)
    IF (ErrStat /= CD_VISCO_OK) RETURN
    chord = qb - qa
    length = NORM2(chord)
    tension = DOT_PRODUCT(force(1:3), chord/length)
  END SUBROUTINE CD_Viscoelastic_Element_Tension

  SUBROUTINE CD_Viscoelastic_State_Advance(qa, qb, va, vb, l0, ea_d, ea_1, ba, ba_d, &
                                           dl_1_n, dt, dl_1_next, ErrStat, ErrMsg)
    !! Advance the committed state from CONVERGED kinematics -- the same backward
    !! Euler the load used, evaluated once per successful step.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3)
    REAL(wp), INTENT(IN) :: l0, ea_d, ea_1, ba, ba_d, dl_1_n, dt
    REAL(wp), INTENT(OUT) :: dl_1_next
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: chord(3), tang(3), length, lstrd, dl, bsum, den, ld1
    dl_1_next = dl_1_n
    ErrStat = CD_VISCO_OK
    ErrMsg = ''
    chord = qb - qa
    length = NORM2(chord)
    IF (length <= TINY_LEN) THEN
      CALL fail(ErrStat, ErrMsg, 'viscoelastic element collapsed to zero length')
      RETURN
    END IF
    tang = chord/length
    lstrd = DOT_PRODUCT(tang, vb - va)
    dl = length - l0
    bsum = ba_d + ba
    den = CD_ONE + dt*(ea_d + ea_1)/bsum
    dl_1_next = (dl_1_n + dt*(ea_d*dl + ba_d*lstrd)/bsum)/den
    ! the same tension-only switch as CD_Viscoelastic_Element_Load (same expression order,
    ! so the load and the commit always pick the same branch)
    ld1 = (ea_d*dl - (ea_d + ea_1)*dl_1_next + ba_d*lstrd)/bsum
    IF (ea_1*dl_1_next/l0 + ba*ld1/l0 < CD_ZERO) dl_1_next = slack_state(dl_1_n, ea_1, ba, dt)
  END SUBROUTINE CD_Viscoelastic_State_Advance

  PURE REAL(wp) FUNCTION slack_state(dl_1_n, ea_1, ba, dt) RESULT(dl_1)
    !! Slow-branch stretch after a step of dt under zero segment tension: backward Euler
    !! of BA*ld_1 = -EA_1*dl_1. With BA = 0 the unloaded spring relaxes at once (dl_1 = 0);
    !! the instantaneous query (dt = 0) keeps the committed state.
    REAL(wp), INTENT(IN) :: dl_1_n, ea_1, ba, dt
    IF (dt <= CD_ZERO) THEN
      dl_1 = dl_1_n
    ELSE
      dl_1 = ba*dl_1_n/(ba + dt*ea_1)
    END IF
  END FUNCTION slack_state

  PURE FUNCTION outer(a, b) RESULT(m)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: m(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        m(i, j) = a(i)*b(j)
      END DO
    END DO
  END FUNCTION outer

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_VISCO_BADINPUT
    ErrMsg = 'CableDyn_Viscoelastic: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Viscoelastic
