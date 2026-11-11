! File: tests/test_control_torsion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_control_torsion
  !! Active line control (CD_HermiteCable_Dyn_Set_SegmentLength, deck CONTROL) of a finite-EI line
  !! restrained in torsion. Unless named otherwise the line is straight along +x, 10 elements of
  !! 1 m unstretched held between rigid torsional ends H = 10.1 m apart (1 % strain), with the
  !! imposed twist Phi; its fairlead-side span (the last two elements, S = 2 m) is controlled.
  !!   Q  quasi-static: the span paid out and hauled in, DeltaL = 0.05 sin(2 pi t/10 s), carries the
  !!      torque GJ Phi/L(t) + K (H - L)/L and the tension EA (H - L)/L + K Phi/L (L = 10 m + DeltaL,
  !!      with the axial damping's BA d(eps)/dt):
  !!      condensed torsion without and with torque-tension coupling K, and the nodal twist with a
  !!      negligible Irn (1e-9) and K (every node torque);
  !!   D  torsional damping with the length rate: a constant pay-out Ldot of the span under GJ|K|Bt
  !!      (Irn 1e-9) keeps the twist per length uniform, so the torque is the Kelvin-Voigt
  !!      GJ chi + Bt chi_dot with chi = (Phi + (K/GJ) H)/L - K/GJ; without the rate it is not;
  !!   F  the length-rate share of the torsional damping on a bowed line equals Bt l0_dot
  !!      d(tau/l0)/dl0 by central differences of the element twist at fixed q (the Euler identity
  !!      l0 drho/dl0 = m . drho/dm of the element shape), on interior elements, at both rigid
  !!      torsional ends (End A the fairlead) and with coupling, and the torque tangent the step
  !!      assembles matches central differences of the torque;
  !!   Z  the torsion terms a length change rebuilds equal those of a model built with the new
  !!      lengths bit for bit (the lumped polar inertia Irn l0/2, a -zeta torsional damping
  !!      re-resolved as zeta l0 sqrt(GJ Irn), a direct Bt kept); a committed-state evaluation
  !!      between the command and the step takes the committed lengths and leaves the present ones,
  !!      and a saved control state and a snapshot take a command back bit for bit;
  !!   E  energy with a real Irn: with the centreline held, a span paid out under a ringing twist
  !!      changes the twist and polar kinetic energy by the work of the length change,
  !!      integral of sum (dE/dl0) l0_dot + 1/2 I_dot w^2 (the mass of the new lengths, without the
  !!      rate term, as for the translational mass);
  !!   L  a slow pay-out under a twist with a real Irn: the torque follows GJ Phi/L(t), the run at
  !!      rho_inf = 0.4 (alpha_f = 2/7) follows the one at rho_inf = 0 within a few per cent of the
  !!      per-step torque change, also with the committed force evaluated afresh each step rather
  !!      than reused (it keeps its torsion at the committed lengths; taking it at the new ones
  !!      lags by alpha_f of it), and no step jumps;
  !!   R  restart mid-ramp: a rolling, twisting, torsionally damped coupled cable under a pay-out
  !!      ramp continues bit-identically from a snapshot and from a module rebuilt from the
  !!      checkpoint mirror with the command re-applied; after a non-stepping frame write (whose
  !!      torque is the summed twist over the compliance) both bring back that committed torque
  !!      bit for bit, which re-deriving it as (Phi - Theta)/C would not (where a build makes the
  !!      two equal, the torque is set one ulp off the re-derived value so the check resolves);
  !!   S  deck: a straight torsion line with a pretwist and a CONTROL row on the coupled aggregate
  !!      (the CompMooring = 5 route; the standalone driver takes no CONTROL) initialises, its
  !!      Torq1N1 follows GJ Twist1/L(t) through a haul-in ramp, and the shell's checkpoint recipe
  !!      continues bit-identically.
  !!   O  deck, a line restrained in torsion at one end only: a straight neutral cable (EA 1e7 N,
  !!      GJ|K 5e4 N m2|4e5 N m, Irn 1e-9 kg m) of L0 = 99 m held H = 100 m apart, free in torsion
  !!      at End A (the controlled fairlead) and, in turn, at End B, paid out by 0.2 m on a half
  !!      cosine over 2 s and held. With no torque the section is free to twist, so each element
  !!      twists by -(K/GJ)(l_e - l0_e) and the free end turns with the commanded length:
  !!      Twist1 = -(K/GJ)(H - L0 - dL(t)) at every step, with no torque at either end; over the
  !!      hold the tension, about which the undamped axial waves of the ramp ring, has the mean
  !!      (EA - K^2/GJ)(H - L0 - dL)/(L0 + dL) of a section free to twist (within 5e-4: the 2 s mean
  !!      of the 2.4e-3 ringing).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Line, CD_HermiteTorsion_Unwrap, &
                                     CD_HermiteTorsion_Zeta_Damping, CD_HermiteTorsion_Element_Stretch, &
                                     CD_HermiteTorsion_Compliance, CD_HTORS_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Reaction, &
                                          CD_HermiteCable_Dyn_Set_SegmentLength, &
                                          CD_HermiteCable_Dyn_Set_Axial_Damping, &
                                          CD_HermiteCable_Dyn_Set_Torsion, CD_HermiteCable_Dyn_Set_Torsion_Drive, &
                                          CD_HermiteCable_Dyn_Torsion_State, CD_HermiteCable_Dyn_Node_Torque, &
                                          CD_HermiteCable_Dyn_Element_Twist, CD_HermiteCable_Dyn_Element_Torque, &
                                          CD_HermiteCable_Dyn_Recompute_Acceleration, CD_HermiteCable_Dyn_Snapshot, &
                                          CD_HermiteCable_Dyn_Restore, CD_HermiteCableControlSaveType, &
                                          CD_HermiteCable_Dyn_Save_Control, CD_HermiteCable_Dyn_Restore_Control, &
                                          CD_HermiteCable_Dyn_Set_ForceBlend, CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_Init, CD_HFMF_Set_EndConnection, &
                                          CD_HFMF_Set_Torsion, CD_HFMF_UpdateStates, CD_HFMF_Set_SegmentLength, &
                                          CD_HFMF_SetCoupledKinematics, &
                                          CD_HFMF_Snapshot, CD_HFMF_Restore, CD_HFMF_MirrorSize, &
                                          CD_HFMF_PackMirror, CD_HFMF_UnpackMirror, CD_HFMF_End, CD_HFMF_OK
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_UpdateStates_Moving, CD_AGG_Step_Moving, CD_AGG_CalcOutput, &
                                         CD_AGG_Apply_LineControl, CD_AGG_EvalChannel, CD_AGG_End, CD_AGG_OK
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  ! the straight line of Q, D, Z, E, L
  INTEGER, PARAMETER :: NE = 10, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: LS = 10.0_wp, HH = 10.1_wp, EA = 1.0e5_wp, EI = 100.0_wp, GJ = 80.0_wp
  REAL(wp), PARAMETER :: PHI0 = 0.5_wp*PI, KTT = 500.0_wp
  INTEGER, PARAMETER :: SPAN(2) = [NE - 1, NE]
  INTEGER :: nfail = 0

  CALL check_quasi_static('condensed', 0.0_wp, 0.0_wp)
  CALL check_quasi_static('condensed, coupled', KTT, 0.0_wp)
  CALL check_quasi_static('nodal twist, coupled', KTT, 1.0e-9_wp)
  CALL check_damping_rate()
  CALL check_rate_identity('interior', [5, 6], 0.0_wp)
  CALL check_rate_identity('End B rigid', [1, 2], 0.0_wp)
  CALL check_rate_identity('fairlead, End A rigid', [NE - 1, NE], 0.0_wp)
  CALL check_rate_identity('interior, coupled', [5, 6], 0.5_wp)
  CALL check_rate_identity('fairlead, coupled', [NE - 1, NE], 0.5_wp)
  CALL check_rebuild()
  CALL check_energy()
  CALL check_lag()
  CALL check_restart()
  CALL check_deck()
  CALL check_deck_one_end(1)
  CALL check_deck_one_end(2)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: active line control of lines restrained in torsion'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: '//TRIM(label)
  END SUBROUTINE require

  LOGICAL FUNCTION same_bits(x, y) RESULT(same)
    REAL(wp), INTENT(IN) :: x(:), y(:)
    same = SIZE(x) == SIZE(y)
    IF (same) same = ALL(TRANSFER(x, 0_INT64, SIZE(x)) == TRANSFER(y, 0_INT64, SIZE(y)))
  END FUNCTION same_bits

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE build_line(m, l0, rho_inf, rhoa, ktt_in, irn, ba, hold_all, es, em, bt, zeta, phi)
    !! The straight line: nodes at x = s H/L with m = (H/L, 0, 0) (uniform strain, at rest in
    !! equilibrium without weight), every transverse DOF held (an axial and torsional problem),
    !! the end translations held (hold_all: every DOF, the twist alone moves). The kernel takes
    !! EA - K^2/GJ, as the deck gives it under coupling. Torsion: both ends along +x with the
    !! reference normal +z, rigid, imposed twist phi (default Phi0), GJ, coupling ktt_in, the
    !! polar inertia irn (> 0: nodal twist), a direct Bt (bt) or a -zeta damping (zeta, resolved
    !! as the deck does). ba > 0 adds axial damping.
    TYPE(CD_HermiteCableDynType), INTENT(OUT) :: m
    REAL(wp), INTENT(IN) :: l0(NE), rho_inf, rhoa, ktt_in, irn, ba
    LOGICAL, INTENT(IN) :: hold_all
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp), INTENT(IN), OPTIONAL :: bt(NE), zeta(NE), phi
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: q(NDOF), s, g(NDOF), raw, lt
    INTEGER, ALLOCATABLE :: fixed(:)
    INTEGER :: i, k
    lt = SUM(l0)
    q = 0.0_wp
    fixed = [INTEGER ::]
    DO i = 1, NN
      s = SUM(l0(1:i - 1))
      q(6*i - 5) = s*HH/lt
      q(6*i - 2) = HH/lt
      fixed = [fixed, 6*i - 4, 6*i - 3, 6*i - 1, 6*i]
      IF (hold_all .OR. i == 1 .OR. i == NN) fixed = [fixed, 6*i - 5]
      IF (hold_all) fixed = [fixed, 6*i - 2]
    END DO
    CALL CD_HermiteCable_Dyn_Init(m, l0, [(EA - ktt_in**2/GJ, k=1, NE)], [(EI, k=1, NE)], [(rhoa, k=1, NE)], &
                                  [(0.0_wp, k=1, NE)], q, fixed, -1.0e3_wp, 0.0_wp, rho_inf, es, em)
    IF (es /= CD_HCDYN_OK) RETURN
    IF (ba > 0.0_wp) THEN
      CALL CD_HermiteCable_Dyn_Set_Axial_Damping(m, [(ba, k=1, NE)], es, em)
      IF (es /= CD_HCDYN_OK) RETURN
    END IF
    tors%active = .TRUE.
    tors%phi = PHI0
    IF (PRESENT(phi)) tors%phi = phi
    tors%ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                         0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    tors%end_compliance = 0.0_wp
    ALLOCATE (tors%gj(NE))
    tors%gj = GJ
    IF (ktt_in > 0.0_wp) tors%couple = [(ktt_in/GJ, k=1, NE)]
    IF (irn > 0.0_wp) tors%irn = [(irn, k=1, NE)]
    IF (PRESENT(bt)) tors%bt = bt
    IF (PRESENT(zeta)) THEN
      IF (.NOT. ALLOCATED(tors%bt)) tors%bt = [(0.0_wp, k=1, NE)]
      tors%bt_zeta = zeta
      DO k = 1, NE
        IF (zeta(k) > 0.0_wp) tors%bt(k) = CD_HermiteTorsion_Zeta_Damping(zeta(k), l0(k), GJ, irn)
      END DO
    END IF
    CALL CD_HermiteTorsion_Line(q, l0, tors%ends, raw, g, es, em, couple=tors%couple)
    IF (es /= CD_HTORS_OK) RETURN
    tors%theta = CD_HermiteTorsion_Unwrap(raw, 0.0_wp)
    tors%has_theta = .TRUE.
    CALL CD_HermiteCable_Dyn_Set_Torsion(m, tors, es, em)
  END SUBROUTINE build_line

  SUBROUTINE command(m, dl, dldot, es, em, restored)
    !! The span from its base S = 2 m to S + dl, each element scaled by (S + dl)/S, rate dldot l/S.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    REAL(wp), INTENT(IN) :: dl, dldot
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    LOGICAL, INTENT(IN), OPTIONAL :: restored
    REAL(wp), PARAMETER :: S = 2.0_wp
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(m, SPAN, [1.0_wp, 1.0_wp]*((S + dl)/S), [1.0_wp, 1.0_wp]*(dldot/S), &
                                               es, em, restored=restored)
  END SUBROUTINE command

  REAL(wp) FUNCTION end_tension(m) RESULT(t)
    !! Axial pull of the line on its held fairlead node (the last node).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    REAL(wp) :: f(3)
    INTEGER :: es
    CHARACTER(200) :: em
    CALL CD_HermiteCable_Dyn_Reaction(m, NN, f, es, em)
    t = -f(1)
    IF (es /= CD_HCDYN_OK) t = HUGE(1.0_wp)
  END FUNCTION end_tension

  REAL(wp) FUNCTION line_torque(m) RESULT(tq)
    !! The torque of the line: the condensed torque, or the node torque of the nodal twist furthest
    !! from the mean (so a non-uniform torque shows).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    REAL(wp) :: th, ntq(NN)
    INTEGER :: es
    CHARACTER(300) :: em
    IF (m%tw_active) THEN
      CALL CD_HermiteCable_Dyn_Node_Torque(m, ntq, es, em)
      tq = ntq(MAXLOC(ABS(ntq - SUM(ntq)/REAL(NN, wp)), 1))
    ELSE
      CALL CD_HermiteCable_Dyn_Torsion_State(m, th, tq, es, em)
    END IF
    IF (es /= CD_HCDYN_OK) tq = HUGE(1.0_wp)
  END FUNCTION line_torque

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_quasi_static(label, kc, irn)
    !! Q: rho_inf = 0, a light line (0.01 kg/m) with axial damping, 1000 steps of 0.01 s.
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: kc, irn
    REAL(wp), PARAMETER :: DT = 0.01_wp, AMP = 0.05_wp, PER = 10.0_wp, BA = 100.0_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(NE), t, dl, dldot, lt, mexp, texp, err_m, err_t, frozen
    INTEGER :: k, es
    CHARACTER(300) :: em
    l0 = 1.0_wp
    CALL build_line(m, l0, 0.0_wp, 0.01_wp, kc, irn, BA, .FALSE., es, em)
    CALL require(es == CD_HCDYN_OK, 'Q '//label//': build: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    CALL require(m%tw_active .EQV. irn > 0.0_wp, 'Q '//label//': the twist model')
    err_m = 0.0_wp
    err_t = 0.0_wp
    frozen = 0.0_wp
    DO k = 1, NINT(PER/DT)
      t = REAL(k, wp)*DT
      dl = AMP*(SIN(2.0_wp*PI*t/PER) - 0.5_wp*SIN(4.0_wp*PI*t/PER))
      dldot = AMP*(2.0_wp*PI/PER)*(COS(2.0_wp*PI*t/PER) - COS(4.0_wp*PI*t/PER))
      CALL command(m, dl, dldot, es, em)
      CALL require(es == CD_HCDYN_OK, 'Q '//label//': command: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) EXIT
      CALL CD_HermiteCable_Dyn_Step(m, DT, 50, 1.0e-10_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'Q '//label//': step: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) EXIT
      lt = LS + dl
      mexp = GJ*PHI0/lt + kc*(HH - lt)/lt
      ! the axial Kelvin-Voigt share BA d(eps)/dt of the uniform strain eps = H/L - 1
      texp = EA*(HH - lt)/lt - BA*HH*dldot/lt**2 + kc*PHI0/lt
      err_m = MAX(err_m, ABS(line_torque(m) - mexp)/mexp)
      err_t = MAX(err_t, ABS(end_tension(m) - texp)/texp)
      frozen = MAX(frozen, ABS(GJ*PHI0/LS + kc*(HH - LS)/LS - mexp)/mexp)
    END DO
    WRITE (*, '(A,A,A,3ES10.2)') 'Q quasi-static (', label, '): torque, tension rel. error; a frozen '// &
      'compliance would miss by ', err_m, err_t, frozen
    CALL require(err_m <= 1.0e-7_wp, 'Q '//label//': the torque is GJ Phi/L(t) + K (H - L)/L')
    CALL require(err_t <= 1.0e-5_wp, 'Q '//label//': the tension is EA (H - L)/L + K Phi/L')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_quasi_static

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_damping_rate()
    !! D: the span paid out at Ldot = 0.01 m/s from t = 0 over 4 s, Bt = 100 N m2 s, K as in Q.
    !! Every element obeys GJ chi_e + Bt chi_e_dot = M with one M (the angles carry no inertia) and
    !! starts from one chi, so chi stays uniform, and the end constraint gives sum chi_e l_e =
    !! Phi + (K/GJ)(H - L): M = GJ chi + Bt chi_dot, chi_dot = -(Phi + (K/GJ) H) Ldot/L^2.
    REAL(wp), PARAMETER :: DT = 0.01_wp, LDOT = 0.01_wp, TEND = 4.0_wp, BT = 100.0_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(NE), t, lt, chi, chid, mexp, err(2), lag, c
    INTEGER :: k, es, pass
    CHARACTER(300) :: em
    c = KTT/GJ
    l0 = 1.0_wp
    lag = BT*(PHI0 + c*HH)*LDOT/(LS + LDOT*TEND)**2
    DO pass = 1, 2
      CALL build_line(m, l0, 0.0_wp, 0.01_wp, KTT, 1.0e-9_wp, 100.0_wp, .FALSE., es, em, bt=[(BT, k=1, NE)])
      CALL require(es == CD_HCDYN_OK, 'D: build: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      err(pass) = 0.0_wp
      DO k = 1, NINT(TEND/DT)
        t = REAL(k, wp)*DT
        CALL command(m, LDOT*t, MERGE(LDOT, 0.0_wp, pass == 1), es, em)
        IF (es == CD_HCDYN_OK) CALL CD_HermiteCable_Dyn_Step(m, DT, 50, 1.0e-10_wp, es, em)
        CALL require(es == CD_HCDYN_OK, 'D: march: '//TRIM(em))
        IF (es /= CD_HCDYN_OK) EXIT
        IF (t < 1.0_wp) CYCLE
        lt = LS + LDOT*t
        chi = (PHI0 + c*HH)/lt - c
        chid = -(PHI0 + c*HH)*LDOT/lt**2
        mexp = GJ*chi + BT*chid
        err(pass) = MAX(err(pass), ABS(line_torque(m) - mexp))
      END DO
      CALL CD_HermiteCable_Dyn_End(m)
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A,ES10.3,A)') 'D torsional damping lag ', lag, ' N m; max torque error with '// &
      'the length rate ', err(1), ', without ', err(2), ' N m'
    CALL require(err(1) <= 1.0e-2_wp*lag, 'D: the torque is GJ chi + Bt chi_dot (the twist per length damped)')
    CALL require(err(2) > 0.2_wp*lag, 'D: without the length rate the damping torque is wrong')
  END SUBROUTINE check_damping_rate

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_rate_identity(label, el, kc)
    !! F: a bowed line at rest whose tangent DOFs are neither unit nor along the chord (transverse
    !! DOFs free, node 1 and the last node held, nodal twist Irn 0.05 kg m, Bt = 30 N m2 s, rigid
    !! torsional ends, coupling K/GJ = kc), the elements el at the rate l0_dot = 0.02 m/s:
    !!  - the change of their committed torque is Bt l0_dot d(tau/l0)/dl0 at fixed q, against
    !!    central differences of the element twist (with the coupling term (K/GJ)(l - l0)) over
    !!    l0 (+- 1e-5 m), and against the straight-line value -Bt l0_dot tau/l0^2;
    !!  - the element torque's tangent in its 12 DOFs and in its End-2 angle as a step assembles
    !!    it (the last assembly of a two-iteration step, at the accepted trial iterate, whose q, v,
    !!    angles and rates the test reads back and checks against the torque the assembly kept),
    !!    against central differences of the torque at that state (+- 1e-6), and the same
    !!    differences without the rate, which the check must resolve.
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, INTENT(IN) :: el(2)
    REAL(wp), INTENT(IN) :: kc
    REAL(wp), PARAMETER :: BT = 30.0_wp, RATE = 0.02_wp, DELTA = 1.0e-5_wp, HQ = 1.0e-6_wp
    TYPE(CD_HermiteCableDynType) :: m, base, pert, at, at0
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: l0(NE), q(NDOF), s, g(NDOF), raw, tw0(NE), twp(NE), twm(NE), mt0(NE), mt1(NE)
    REAL(wp) :: fd(2), share(2), shape(2), err, dq(13), dfd(13), dfd0(13), terr, tres, mp, mm, mt_at, state_err
    INTEGER :: i, k, j, es
    CHARACTER(300) :: em
    l0 = 1.0_wp
    q = 0.0_wp
    DO i = 1, NN
      s = REAL(i - 1, wp)
      q(6*i - 5) = s
      q(6*i - 4) = 0.8_wp*SIN(PI*s/LS)**2
      q(6*i - 3) = 0.4_wp*SIN(2.0_wp*PI*s/LS)**2
      q(6*i - 2) = 1.0_wp + 0.05_wp*s
      q(6*i - 1) = 0.8_wp*(PI/LS)*SIN(2.0_wp*PI*s/LS) + 0.1_wp
      q(6*i) = 0.4_wp*(2.0_wp*PI/LS)*SIN(4.0_wp*PI*s/LS) - 0.07_wp
    END DO
    CALL CD_HermiteCable_Dyn_Init(m, l0, [(EA, k=1, NE)], [(EI, k=1, NE)], [(1.0_wp, k=1, NE)], [(0.0_wp, k=1, NE)], &
                                  q, [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], -1.0e3_wp, 0.0_wp, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'F '//label//': init: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    tors%active = .TRUE.
    tors%phi = 1.0_wp
    tors%ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                         0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    tors%end_compliance = 0.0_wp
    tors%gj = [(GJ, k=1, NE)]
    IF (kc > 0.0_wp) tors%couple = [(kc, k=1, NE)]
    tors%irn = [(0.05_wp, k=1, NE)]
    tors%bt = [(BT, k=1, NE)]
    CALL CD_HermiteTorsion_Line(q, l0, tors%ends, raw, g, es, em, couple=tors%couple)
    tors%theta = CD_HermiteTorsion_Unwrap(raw, 0.0_wp)
    tors%has_theta = .TRUE.
    CALL CD_HermiteCable_Dyn_Set_Torsion(m, tors, es, em)
    CALL require(es == CD_HCDYN_OK .AND. m%tw_active, 'F '//label//': nodal twist on the bowed line: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    CALL coupled_twist(m, kc, tw0)
    CALL CD_HermiteCable_Dyn_Element_Torque(m, mt0, es, em)
    ! the element twist at l0 +- DELTA (the committed angles and q kept)
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(m, el, l0(el) + DELTA, [0.0_wp, 0.0_wp], es, em)
    CALL coupled_twist(m, kc, twp)
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(m, el, l0(el) - DELTA, [0.0_wp, 0.0_wp], es, em)
    CALL coupled_twist(m, kc, twm)
    ! the rate at the base lengths, committed, and the torque of that committed state
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(m, el, l0(el), [RATE, RATE], es, em, restored=.TRUE.)
    CALL require(es == CD_HCDYN_OK, 'F '//label//': the committed rate: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(m, es, em)
    CALL require(es == CD_HCDYN_OK, 'F '//label//': the committed state with the rate: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Element_Torque(m, mt1, es, em)
    err = 0.0_wp
    DO k = 1, 2
      i = el(k)
      fd(k) = BT*RATE*(twp(i)/(l0(i) + DELTA) - twm(i)/(l0(i) - DELTA))/(2.0_wp*DELTA)
      shape(k) = -BT*RATE*tw0(i)/l0(i)**2
      share(k) = mt1(i) - mt0(i)
      err = MAX(err, ABS(share(k) - fd(k))/ABS(fd(k)))
    END DO
    ! the tangent of the last assembly of a step (full Newton: the accepted trial of its first
    ! iteration) at the state of that assembly, read back from the step's staged iterate
    base = m
    CALL CD_HermiteCable_Dyn_Step(m, 1.0e-4_wp, 2, 1.0e-14_wp, es, em)
    at = base
    at%q = m%ws_qa
    at%v = m%ws_va
    at%tw_phi = m%tw_pe
    at%tw_w = m%tw_we
    at0 = at
    at0%l0_dot = 0.0_wp
    at0%l0_dot_c = 0.0_wp
    terr = 0.0_wp
    tres = 0.0_wp
    state_err = 0.0_wp
    DO k = 1, 2
      i = el(k)
      dq(1:12) = m%tw_ek(i)*m%tw_eg(:, i) + m%tw_ed(i)*m%tw_ehv(:, i)
      dq(13) = m%tw_ek(i)
      pert = at
      CALL perturbed_torque(pert, i, 1, 0.0_wp, mt_at)
      state_err = MAX(state_err, ABS(mt_at - m%tw_me(i))/ABS(m%tw_me(i)))
      DO j = 1, 13
        pert = at
        CALL perturbed_torque(pert, i, j, HQ, mp)
        pert = at
        CALL perturbed_torque(pert, i, j, -HQ, mm)
        dfd(j) = (mp - mm)/(2.0_wp*HQ)
        pert = at0
        CALL perturbed_torque(pert, i, j, HQ, mp)
        pert = at0
        CALL perturbed_torque(pert, i, j, -HQ, mm)
        dfd0(j) = (mp - mm)/(2.0_wp*HQ)
      END DO
      terr = MAX(terr, MAXVAL(ABS(dq - dfd))/MAXVAL(ABS(dfd)))
      tres = MAX(tres, MAXVAL(ABS(dfd - dfd0))/MAXVAL(ABS(dfd)))
    END DO
    WRITE (*, '(A,A,A,2ES13.5,A,2ES13.5,A,2ES13.5,A,ES9.2,A,ES9.2,A,ES9.2,A,ES9.2)') 'F length-rate damping (', &
      label, '): torque ', share, '; by differences ', fd, '; straight-line value ', shape, '; rel. error ', err, &
      '; tangent against differences ', terr, ', its length-rate share ', tres, ' (state read back to ', &
      state_err, ')'
    CALL require(err <= 1.0e-6_wp, 'F '//label//': the length-rate damping is Bt l0_dot d(tau/l0)/dl0 at fixed q')
    CALL require(MAXVAL(ABS(shape - fd)) > 1.0e3_wp*err*MAXVAL(ABS(fd)), &
                 'F '//label//': the element shape''s dependence on l0 is resolved by the check')
    CALL require(state_err <= 1.0e-12_wp, 'F '//label//': the state of the step''s last assembly is read back')
    CALL require(terr <= 1.0e-6_wp, 'F '//label//': the assembled torque tangent matches central differences')
    CALL require(tres > 1.0e2_wp*terr, 'F '//label//': the tangent check resolves the length-rate share')
    DO k = 1, NE
      IF (ANY(el == k)) CYCLE
      CALL require(same_bits(mt1(k:k), mt0(k:k)), 'F '//label//': elements without a rate keep their torque')
    END DO
    CALL CD_HermiteCable_Dyn_End(m)
    CALL CD_HermiteCable_Dyn_End(base)
    CALL CD_HermiteCable_Dyn_End(pert)
    CALL CD_HermiteCable_Dyn_End(at)
    CALL CD_HermiteCable_Dyn_End(at0)
  END SUBROUTINE check_rate_identity

  SUBROUTINE coupled_twist(m, kc, tw)
    !! The element twists tau_e of the nodal twist: the material twist (the query) plus the
    !! coupling term (K/GJ)(l_e - l0_e) of the stretched element length.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: m
    REAL(wp), INTENT(IN) :: kc
    REAL(wp), INTENT(OUT) :: tw(NE)
    INTEGER :: e, es
    CHARACTER(300) :: em
    CALL CD_HermiteCable_Dyn_Element_Twist(m, tw, es, em)
    IF (.NOT. kc > 0.0_wp) RETURN
    DO e = 1, NE
      tw(e) = tw(e) + kc*(CD_HermiteTorsion_Element_Stretch(m%q(6*e - 5:6*e + 6), m%l0(e), 4) - m%l0(e))
    END DO
  END SUBROUTINE coupled_twist

  SUBROUTINE perturbed_torque(m, e, j, h, mt)
    !! The committed torque of element e with its DOF j (1-12: [r1, m1, r2, m2]; 13: the End-2
    !! angle) moved by h, from a re-derived committed state.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    INTEGER, INTENT(IN) :: e, j
    REAL(wp), INTENT(IN) :: h
    REAL(wp), INTENT(OUT) :: mt
    REAL(wp) :: tq(NE)
    INTEGER :: es
    CHARACTER(300) :: em
    IF (j <= 12) THEN
      m%q(6*e - 6 + j) = m%q(6*e - 6 + j) + h
    ELSE
      m%tw_phi(e + 1) = m%tw_phi(e + 1) + h
    END IF
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(m, es, em)
    CALL CD_HermiteCable_Dyn_Element_Torque(m, tq, es, em)
    mt = tq(e)
    IF (es /= CD_HCDYN_OK) mt = HUGE(1.0_wp)
  END SUBROUTINE perturbed_torque

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_rebuild()
    !! Z: Irn 0.5 kg m, K, a -zeta damping (zeta 0.1) on every element but element 3, which takes
    !! a direct Bt of 7 N m2 s; the span lengthened by 30 % at 0.05 m/s.
    REAL(wp), PARAMETER :: LAM = 1.3_wp, IRN = 0.5_wp, ZETA = 0.1_wp, DT = 0.01_wp
    TYPE(CD_HermiteCableDynType) :: a, b, ref, twin
    TYPE(CD_HermiteCableControlSaveType) :: saved
    REAL(wp) :: l0(NE), l0b(NE), zt(NE), btd(NE), bt_keep(NE), mass_keep(NN), torque_keep
    INTEGER :: k, es
    CHARACTER(300) :: em
    l0 = 1.0_wp
    zt = ZETA
    zt(3) = 0.0_wp
    btd = 0.0_wp
    btd(3) = 7.0_wp
    CALL build_line(a, l0, 0.0_wp, 0.01_wp, KTT, IRN, 100.0_wp, .FALSE., es, em, bt=btd, zeta=zt)
    CALL require(es == CD_HCDYN_OK .AND. a%tw_active, 'Z: build: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    ref = a
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, LAM*l0(SPAN), [0.05_wp, 0.05_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. a%has_ctrl, 'Z: a line restrained in torsion takes a length command: '// &
                 TRIM(em))
    l0b = l0
    l0b(SPAN) = LAM*l0(SPAN)
    CALL build_line(b, l0b, 0.0_wp, 0.01_wp, KTT, IRN, 100.0_wp, .FALSE., es, em, bt=btd, zeta=zt)
    CALL require(es == CD_HCDYN_OK, 'Z: fresh build at the new lengths: '//TRIM(em))
    CALL require(same_bits(a%tw_mass, b%tw_mass), 'Z: the lumped polar inertia equals a fresh build bit for bit')
    CALL require(same_bits(a%torsion%bt, b%torsion%bt), 'Z: the torsional damping equals a fresh build bit for bit')
    CALL require(ALL(a%torsion%bt(SPAN) == CD_HermiteTorsion_Zeta_Damping(ZETA, LAM, GJ, IRN)) .AND. &
                 ALL(a%torsion%bt(SPAN) > ref%torsion%bt(SPAN)), &
                 'Z: a -zeta damping is re-resolved as zeta l0 sqrt(GJ Irn) at the new lengths')
    CALL require(a%torsion%bt(3) == 7.0_wp .AND. same_bits(a%torsion%bt(1:NE - 2), ref%torsion%bt(1:NE - 2)), &
                 'Z: a direct Bt and the elements outside the span keep their damping')
    ! a committed-state evaluation between the command and the step takes the committed lengths
    ! (the acceleration of a never-commanded twin) and leaves the present torsion terms
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(ref, es, em)
    CALL CD_HermiteCable_Dyn_Recompute_Acceleration(a, es, em)
    CALL require(es == CD_HCDYN_OK .AND. same_bits(a%a, ref%a) .AND. same_bits(a%tw_al, ref%tw_al) .AND. &
                 same_bits(a%tw_mt, ref%tw_mt), 'Z: the committed state is evaluated at the committed lengths')
    CALL require(same_bits(a%tw_mass, b%tw_mass) .AND. same_bits(a%torsion%bt, b%torsion%bt) .AND. &
                 same_bits(a%l0, l0b), 'Z: the committed-state evaluation leaves the present torsion terms')
    ! a saved control state takes a command back
    bt_keep = a%torsion%bt
    mass_keep = a%tw_mass
    CALL CD_HermiteCable_Dyn_Save_Control(a, saved)
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, 0.6_wp*l0(SPAN), [-0.2_wp, -0.2_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. .NOT. same_bits(a%tw_mass, mass_keep), 'Z: a command to take back')
    CALL CD_HermiteCable_Dyn_Restore_Control(a, saved, es, em)
    CALL require(es == CD_HCDYN_OK .AND. same_bits(a%tw_mass, mass_keep) .AND. same_bits(a%torsion%bt, bt_keep), &
                 'Z: the saved control state takes the torsion terms back bit for bit')
    ! snapshot, command, step, restore: lengths, torsion terms and committed torque come back
    DO k = 1, 3
      CALL CD_HermiteCable_Dyn_Step(a, DT, 50, 1.0e-10_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'Z: step: '//TRIM(em))
    END DO
    ! the snapshot falls between a command and its step: the committed torque belongs to the
    ! committed lengths, not to the commanded ones
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, 0.9_wp*l0(SPAN), [-0.1_wp, -0.1_wp], es, em)
    twin = a
    torque_keep = a%torsion%torque
    CALL CD_HermiteCable_Dyn_Snapshot(a, es, em)
    CALL CD_HermiteCable_Dyn_Set_SegmentLength(a, SPAN, 0.8_wp*l0(SPAN), [-0.1_wp, -0.1_wp], es, em)
    CALL CD_HermiteCable_Dyn_Step(a, DT, 50, 1.0e-10_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'Z: step after the command: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Restore(a, es, em)
    CALL require(es == CD_HCDYN_OK .AND. same_bits(a%l0, twin%l0) .AND. same_bits(a%tw_mass, twin%tw_mass) .AND. &
                 same_bits(a%torsion%bt, twin%torsion%bt) .AND. same_bits(a%tw_phi, twin%tw_phi) .AND. &
                 same_bits([a%torsion%torque], [torque_keep]), &
                 'Z: restore brings back the lengths, the torsion terms, the twist and the torque bit for bit')
    CALL CD_HermiteCable_Dyn_End(a)
    CALL CD_HermiteCable_Dyn_End(b)
    CALL CD_HermiteCable_Dyn_End(ref)
    CALL CD_HermiteCable_Dyn_End(twin)
  END SUBROUTINE check_rebuild

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE energy_of(m, e)
    !! Twist and polar kinetic energy of the held straight line, from the element twists and the
    !! lengths (sum GJ tau^2/(2 l0) + 1/2 sum I w^2, I the lumped Irn l0/2 of the lengths).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: m
    REAL(wp), INTENT(OUT) :: e
    REAL(wp), PARAMETER :: IRN = 0.5_wp
    REAL(wp) :: tw(NE), inertia(NN)
    INTEGER :: es, k
    CHARACTER(300) :: em
    CALL CD_HermiteCable_Dyn_Element_Twist(m, tw, es, em)
    inertia = 0.0_wp
    DO k = 1, NE
      inertia(k) = inertia(k) + 0.5_wp*IRN*m%l0(k)
      inertia(k + 1) = inertia(k + 1) + 0.5_wp*IRN*m%l0(k)
    END DO
    e = SUM(0.5_wp*GJ*tw**2/m%l0) + 0.5_wp*SUM(inertia*m%tw_w**2)
    IF (es /= CD_HCDYN_OK) e = HUGE(1.0_wp)
  END SUBROUTINE energy_of

  FUNCTION control_power(m) RESULT(p)
    !! The work rate of the length change at the state of m: p(1) the elastic share, the sum over
    !! the elements of dE/dl0 l0_dot = -GJ tau^2 l0_dot/(2 l0^2), and p(2) the inertial one,
    !! 1/2 I_dot w^2 at the nodes.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: m
    REAL(wp) :: p(2)
    REAL(wp), PARAMETER :: IRN = 0.5_wp
    REAL(wp) :: tw(NE), idot(NN)
    INTEGER :: es, k
    CHARACTER(300) :: em
    p = 0.0_wp
    IF (.NOT. m%has_ctrl) RETURN
    CALL CD_HermiteCable_Dyn_Element_Twist(m, tw, es, em)
    idot = 0.0_wp
    DO k = 1, NE
      idot(k) = idot(k) + 0.5_wp*IRN*m%l0_dot(k)
      idot(k + 1) = idot(k + 1) + 0.5_wp*IRN*m%l0_dot(k)
    END DO
    p(1) = SUM(-0.5_wp*GJ*tw**2*m%l0_dot/m%l0**2)
    p(2) = 0.5_wp*SUM(idot*m%tw_w**2)
    IF (es /= CD_HCDYN_OK) p = HUGE(1.0_wp)
  END FUNCTION control_power

  SUBROUTINE check_energy()
    !! E: Irn 0.5 kg m, no damping, rho_inf = 1, every cable DOF held. Over the first 0.5 s the
    !! imposed twist is driven from 1 to 1.3 rad (with zero rate at both ends), which then holds
    !! and rings (the first mode at 4 rad/s); from t = 0.5 s the span is paid out by 0.5 m on a
    !! smoothstep over 10 s, then held to 15 s. The energy change since the end of the drive is
    !! compared with the trapezoidal integral of control_power over the steps.
    REAL(wp), PARAMETER :: DT = 0.005_wp, T0 = 0.5_wp, TR = 10.0_wp, TEND = 15.0_wp, AMP = 0.5_wp
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(NE), t, u, dl, dldot, e0, e1, w(2), p0(2), p1(2), err, wmax
    INTEGER :: k, es
    CHARACTER(300) :: em
    l0 = 1.0_wp
    CALL build_line(m, l0, 1.0_wp, 1.0_wp, 0.0_wp, 0.5_wp, 0.0_wp, .TRUE., es, em, phi=1.0_wp)
    CALL require(es == CD_HCDYN_OK .AND. m%tw_active, 'E: build: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    DO k = 1, NINT(T0/DT)
      t = REAL(k, wp)*DT
      CALL CD_HermiteCable_Dyn_Set_Torsion_Drive(m, m%torsion%ends, &
                                                 1.0_wp + 0.3_wp*(t/T0 - SIN(2.0_wp*PI*t/T0)/(2.0_wp*PI)), es, em)
      IF (es == CD_HCDYN_OK) CALL CD_HermiteCable_Dyn_Step(m, DT, 50, 1.0e-11_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'E: the driven steps: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
    END DO
    CALL energy_of(m, e0)
    p0 = control_power(m)
    w = 0.0_wp
    err = 0.0_wp
    wmax = 0.0_wp
    DO k = NINT(T0/DT) + 1, NINT(TEND/DT)
      t = REAL(k, wp)*DT
      u = MIN(MAX((t - T0)/TR, 0.0_wp), 1.0_wp)
      dl = AMP*u**3*(10.0_wp - 15.0_wp*u + 6.0_wp*u**2)
      dldot = AMP*30.0_wp*u**2*(1.0_wp - u)**2/TR
      CALL command(m, dl, dldot, es, em)
      IF (es == CD_HCDYN_OK) CALL CD_HermiteCable_Dyn_Step(m, DT, 50, 1.0e-11_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'E: march: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) EXIT
      CALL energy_of(m, e1)
      p1 = control_power(m)
      ! trapezoidal work of the step: the power at t_{k-1} (its lengths and the rate commanded
      ! then) and at t_k
      w = w + 0.5_wp*DT*(p0 + p1)
      p0 = p1
      err = MAX(err, ABS(e1 - e0 - SUM(w)))
      wmax = MAX(wmax, ABS(SUM(w)))
    END DO
    WRITE (*, '(A,2ES12.4,A,ES12.5,A,ES10.3)') 'E energy: work of the length change (elastic, inertial) ', w, &
      ' J of ', e1, ' J; max balance error ', err/wmax
    CALL require(wmax > 1.0e-2_wp*e0, 'E: the length change does measurable work')
    CALL require(err <= 2.0e-3_wp*wmax, 'E: the twist energy changes by the work of the length change')
    CALL require(ABS(w(2)) > 10.0_wp*err, 'E: the balance resolves the inertial share (the lumped Irn l0/2 follows)')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_energy

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_lag()
    !! L: Irn 0.5 kg m, -zeta 0.2 damping, every cable DOF held, Phi = 1 rad; the span paid out by
    !! 0.5 m on a smoothstep over 20 s, dt 0.01 s, at rho_inf = 0 and 0.4, and at 0.4 with the
    !! committed force dropped before every step (re-selecting the force blend does), so each
    !! step evaluates it at the committed lengths instead of reusing the converged one.
    REAL(wp), PARAMETER :: DT = 0.01_wp, TR = 20.0_wp, AMP = 0.5_wp
    INTEGER, PARAMETER :: NSTEP = NINT(TR/DT)
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l0(NE), t, u, dl, dldot, hist(NSTEP, 3), ntq(NN), err_qs, d_step, diff, diff_fresh, jump, prev, mqs
    INTEGER :: k, es, pass
    CHARACTER(300) :: em
    l0 = 1.0_wp
    err_qs = 0.0_wp
    jump = 0.0_wp
    DO pass = 1, 3
      CALL build_line(m, l0, MERGE(0.0_wp, 0.4_wp, pass == 1), 1.0_wp, 0.0_wp, 0.5_wp, 0.0_wp, .TRUE., es, em, &
                      zeta=[(0.2_wp, k=1, NE)], phi=1.0_wp)
      CALL require(es == CD_HCDYN_OK, 'L: build: '//TRIM(em))
      IF (es /= CD_HCDYN_OK) RETURN
      prev = GJ*1.0_wp/LS
      DO k = 1, NSTEP
        t = REAL(k, wp)*DT
        u = MIN(t/TR, 1.0_wp)
        dl = AMP*u**3*(10.0_wp - 15.0_wp*u + 6.0_wp*u**2)
        dldot = AMP*30.0_wp*u**2*(1.0_wp - u)**2/TR
        CALL command(m, dl, dldot, es, em)
        IF (pass == 3 .AND. es == CD_HCDYN_OK) CALL CD_HermiteCable_Dyn_Set_ForceBlend(m, .TRUE., es, em)
        IF (es == CD_HCDYN_OK) CALL CD_HermiteCable_Dyn_Step(m, DT, 50, 1.0e-11_wp, es, em)
        CALL require(es == CD_HCDYN_OK, 'L: march: '//TRIM(em))
        IF (es /= CD_HCDYN_OK) EXIT
        CALL CD_HermiteCable_Dyn_Node_Torque(m, ntq, es, em)
        hist(k, pass) = ntq(1)
        mqs = GJ*1.0_wp/(LS + dl)
        err_qs = MAX(err_qs, ABS(ntq(1) - mqs)/mqs)
        jump = MAX(jump, ABS(ntq(1) - prev))
        prev = ntq(1)
      END DO
      CALL CD_HermiteCable_Dyn_End(m)
    END DO
    ! the largest per-step change of the quasi-static torque GJ Phi/L(t): at the peak rate,
    ! 15/8 AMP/TR, at the mid-ramp length
    d_step = GJ*1.0_wp*(15.0_wp/8.0_wp)*AMP/TR*DT/(LS + 0.5_wp*AMP)**2
    diff = MAXVAL(ABS(hist(:, 2) - hist(:, 1)))
    diff_fresh = MAXVAL(ABS(hist(:, 3) - hist(:, 1)))
    WRITE (*, '(A,ES10.3,A,ES10.3,A,2ES10.3,A,ES10.3)') 'L slow pay-out: torque vs GJ Phi/L(t) ', err_qs, &
      '; per-step change ', d_step, ' N m; rho_inf 0.4 vs 0 (reused, fresh committed force) ', diff, diff_fresh, &
      '; largest step ', jump
    CALL require(err_qs <= 1.0e-3_wp, 'L: the torque follows GJ Phi/L(t)')
    CALL require(diff <= 5.0e-2_wp*d_step, 'L: the alpha_f > 0 run follows the alpha_f = 0 one (no lag)')
    CALL require(diff_fresh <= 5.0e-2_wp*d_step, &
                 'L: a committed force evaluated afresh is taken at the committed lengths (no lag)')
    CALL require(jump <= 1.5_wp*d_step, 'L: no step changes the torque by more than the quasi-static change')
  END SUBROUTINE check_lag

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE build_coupled(cab, es, em)
    !! The bowed 10 m HFMF cable of the nodal-twist gates (20 elements): node 21 coupled, node 1
    !! held, Rigid bending ends along +x, the coupled torsion frame on the parent, Irn 0.05,
    !! K 200 N m, -zeta 0.1 torsional damping, Phi 1 rad.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cab
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    INTEGER, PARAMETER :: NE2 = 20, NN2 = NE2 + 1, ND2 = 6*NN2
    REAL(wp), PARAMETER :: KC = 200.0_wp
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: q(ND2), l0(NE2), eye(3, 3), frame(3, 2), s, g(ND2), raw
    INTEGER :: k
    l0 = LS/REAL(NE2, wp)
    q = 0.0_wp
    DO k = 1, NN2
      s = LS*REAL(k - 1, wp)/REAL(NE2, wp)
      q(6*k - 5) = s
      q(6*k - 4) = 0.3_wp*SIN(PI*s/LS)**2
      q(6*k - 3) = 0.1_wp*SIN(2.0_wp*PI*s/LS)**2
      q(6*k - 2) = 1.0_wp
      q(6*k - 1) = 0.3_wp*(PI/LS)*SIN(2.0_wp*PI*s/LS)
      q(6*k) = 0.1_wp*(2.0_wp*PI/LS)*SIN(4.0_wp*PI*s/LS)
    END DO
    eye = 0.0_wp
    DO k = 1, 3
      eye(k, k) = 1.0_wp
    END DO
    CALL CD_HFMF_Init(cab, l0, [(EA - KC**2/GJ, k=1, NE2)], [(EI, k=1, NE2)], [(1.0_wp, k=1, NE2)], &
                      [(0.0_wp, k=1, NE2)], q, [1, 2, 3, ND2 - 5, ND2 - 4, ND2 - 3], 0.0_wp, 0.0_wp, 0.8_wp, 0.01_wp, &
                      NN2, es, em, max_iter=60, tol=1.0e-10_wp)
    IF (es /= CD_HFMF_OK) RETURN
    CALL CD_HFMF_Set_EndConnection(cab, [0.0_wp, 0.0_wp], RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                  [3, 2]), es, em, &
                                   coupled_d0_parent=[1.0_wp, 0.0_wp, 0.0_wp], parent_orientation=eye, &
                                   connection_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
    IF (es /= CD_HFMF_OK) RETURN
    tors%active = .TRUE.
    tors%phi = 1.0_wp
    tors%ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                         0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    tors%end_compliance = 0.0_wp
    tors%gj = [(GJ, k=1, NE2)]
    tors%couple = [(KC/GJ, k=1, NE2)]
    tors%irn = [(0.05_wp, k=1, NE2)]
    tors%bt_zeta = [(0.1_wp, k=1, NE2)]
    tors%bt = CD_HermiteTorsion_Zeta_Damping(tors%bt_zeta, l0, GJ, 0.05_wp)
    CALL CD_HermiteTorsion_Line(q, l0, tors%ends, raw, g, es, em, couple=tors%couple)
    IF (es /= CD_HTORS_OK) RETURN
    tors%theta = CD_HermiteTorsion_Unwrap(raw, 0.0_wp)
    tors%has_theta = .TRUE.
    frame(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
    frame(:, 2) = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL CD_HFMF_Set_Torsion(cab, tors, es, em, coupled_frame_parent=frame, parent_orientation=eye)
  END SUBROUTINE build_coupled

  SUBROUTINE coupled_command(cab, k, es, em, restored)
    !! The command of step k: the two elements at the coupled end (base 0.5 m each) paid out by
    !! 0.15 m on a half cosine over 3 s, then held.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cab
    INTEGER, INTENT(IN) :: k
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    LOGICAL, INTENT(IN), OPTIONAL :: restored
    REAL(wp), PARAMETER :: TR = 3.0_wp, AMP = 0.15_wp, S = 1.0_wp
    REAL(wp) :: t, dl, dldot
    t = 0.01_wp*REAL(k, wp)
    IF (t < TR) THEN
      dl = AMP*0.5_wp*(1.0_wp - COS(PI*t/TR))
      dldot = AMP*0.5_wp*(PI/TR)*SIN(PI*t/TR)
    ELSE
      dl = AMP
      dldot = 0.0_wp
    END IF
    CALL CD_HFMF_Set_SegmentLength(cab, [19, 20], [0.5_wp, 0.5_wp]*((S + dl)/S), [0.5_wp, 0.5_wp]*(dldot/S), &
                                   es, em, restored=restored)
  END SUBROUTINE coupled_command

  SUBROUTINE coupled_march(cab, k0, k1, ok)
    !! Steps k0 + 1 .. k1: the command, then a lateral sway of the coupled end with a parent roll
    !! about the line (2 rad/s) and an imposed twist following it.
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cab
    INTEGER, INTENT(IN) :: k0, k1
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: t, x(3), v(3), a(3), dcm(3, 3), w(3), al(3), phi
    INTEGER :: k, es
    CHARACTER(300) :: em
    ok = .TRUE.
    DO k = k0 + 1, k1
      t = 0.01_wp*REAL(k, wp)
      x = [LS, 0.05_wp*SIN(2.0_wp*t), 0.0_wp]
      v = [0.0_wp, 0.1_wp*COS(2.0_wp*t), 0.0_wp]
      a = [0.0_wp, -0.2_wp*SIN(2.0_wp*t), 0.0_wp]
      dcm = 0.0_wp
      dcm(1, 1) = 1.0_wp
      dcm(2, 2) = COS(2.0_wp*t)
      dcm(3, 3) = COS(2.0_wp*t)
      dcm(2, 3) = SIN(2.0_wp*t)
      dcm(3, 2) = -SIN(2.0_wp*t)
      w = [2.0_wp, 0.0_wp, 0.0_wp]
      al = 0.0_wp
      phi = 1.0_wp - 2.0_wp*t + 0.3_wp*SIN(2.0_wp*t)
      CALL coupled_command(cab, k, es, em)
      IF (es == CD_HFMF_OK) CALL CD_HFMF_UpdateStates(cab, x, v, a, es, em, u_orientation=dcm, u_angular_velocity=w, &
                                                      u_angular_acceleration=al, u_twist=phi)
      IF (es /= CD_HFMF_OK) THEN
        WRITE (*, '(A,I0,A)') '  coupled step ', k, ': '//TRIM(em)
        ok = .FALSE.
        RETURN
      END IF
    END DO
  END SUBROUTINE coupled_march

  SUBROUTINE check_restart()
    !! R: 150 steps (mid-ramp), snapshot and mirror, 100 more; restore and redo the 100. A fresh
    !! module given the command of step 150 as committed and then the mirror redoes them too.
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab, cab2
    REAL(wp), ALLOCATABLE :: mirror(:), qref(:), pref(:), mref(:)
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(300) :: em
    ALLOCATE (cab, cab2)
    CALL build_coupled(cab, es, em)
    CALL require(es == CD_HFMF_OK .AND. cab%line%tw_active, 'R: build: '//TRIM(em))
    IF (es /= CD_HFMF_OK) RETURN
    CALL coupled_march(cab, 0, 150, ok)
    CALL require(ok .AND. cab%line%has_ctrl, 'R: first leg under the pay-out ramp')
    IF (.NOT. ok) RETURN
    CALL CD_HFMF_Snapshot(cab, es, em)
    CALL require(es == CD_HFMF_OK, 'R: snapshot: '//TRIM(em))
    ALLOCATE (mirror(CD_HFMF_MirrorSize(cab)))
    CALL CD_HFMF_PackMirror(cab, mirror, es, em)
    CALL require(es == CD_HFMF_OK, 'R: mirror pack: '//TRIM(em))
    CALL coupled_march(cab, 150, 250, ok)
    CALL require(ok, 'R: second leg')
    qref = cab%line%q
    pref = cab%line%tw_phi
    mref = cab%line%tw_mt
    CALL CD_HFMF_Restore(cab, es, em)
    CALL require(es == CD_HFMF_OK, 'R: restore: '//TRIM(em))
    CALL coupled_march(cab, 150, 250, ok)
    CALL require(ok .AND. same_bits(cab%line%q, qref) .AND. same_bits(cab%line%tw_phi, pref) .AND. &
                 same_bits(cab%line%tw_mt, mref), 'R: the run restored from the snapshot continues bit-identically')
    CALL build_coupled(cab2, es, em)
    CALL require(es == CD_HFMF_OK, 'R: rebuild: '//TRIM(em))
    CALL coupled_command(cab2, 150, es, em, restored=.TRUE.)
    CALL require(es == CD_HFMF_OK, 'R: the checkpointed command re-applied: '//TRIM(em))
    CALL CD_HFMF_UnpackMirror(cab2, mirror, 1.5_wp, es, em)
    CALL require(es == CD_HFMF_OK, 'R: mirror reload: '//TRIM(em))
    CALL coupled_march(cab2, 150, 250, ok)
    CALL require(ok .AND. same_bits(cab2%line%q, qref) .AND. same_bits(cab2%line%tw_phi, pref) .AND. &
                 same_bits(cab2%line%tw_mt, mref), 'R: the run rebuilt from the mirror continues bit-identically')
    WRITE (*, '(A,F9.5,A,F9.5,A)') 'R restart mid-ramp: span ', SUM(cab%line%l0(19:20)), ' m, end twist angle ', &
      pref(SIZE(pref)), ' rad; snapshot and mirror runs identical'
    ! a non-stepping write of the coupled end at step 250 turned 0.05 rad further: the committed
    ! torque is then the summed twist over the compliance, which the snapshot and the mirror
    ! must bring back as it is
    BLOCK
      TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab3
      REAL(wp) :: t, x(3), v(3), a(3), dcm(3, 3), tq_keep, tq_formula
      LOGICAL :: ok2
      ALLOCATE (cab3)
      t = 2.5_wp
      x = [LS, 0.05_wp*SIN(2.0_wp*t), 0.0_wp]
      v = [0.0_wp, 0.1_wp*COS(2.0_wp*t), 0.0_wp]
      a = [0.0_wp, -0.2_wp*SIN(2.0_wp*t), 0.0_wp]
      dcm = 0.0_wp
      dcm(1, 1) = 1.0_wp
      dcm(2, 2) = COS(2.0_wp*t + 0.05_wp)
      dcm(3, 3) = COS(2.0_wp*t + 0.05_wp)
      dcm(2, 3) = SIN(2.0_wp*t + 0.05_wp)
      dcm(3, 2) = -SIN(2.0_wp*t + 0.05_wp)
      CALL CD_HFMF_SetCoupledKinematics(cab, x, v, a, es, em, u_orientation=dcm, &
                                        u_angular_velocity=[2.0_wp, 0.0_wp, 0.0_wp], &
                                        u_angular_acceleration=[0.0_wp, 0.0_wp, 0.0_wp])
      CALL require(es == CD_HFMF_OK, 'R: the non-stepping frame write: '//TRIM(em))
      tq_keep = cab%line%torsion%torque
      tq_formula = (cab%line%torsion%phi - cab%line%torsion%theta)/ &
                   CD_HermiteTorsion_Compliance(cab%line%torsion, cab%line%l0)
      WRITE (*, '(A,ES24.16,A,ES10.3)') 'R committed torque after a frame write ', tq_keep, &
        ' N m; re-derived as (Phi - Theta)/C it would differ by ', tq_formula - tq_keep
      ! the two differ only by the round-off of Phi - (Phi - summed twist), which some builds
      ! happen to make exact: one ulp off the re-derived value keeps the check resolving
      IF (same_bits([tq_formula], [tq_keep])) THEN
        tq_keep = NEAREST(tq_formula, 1.0_wp)
        cab%line%torsion%torque = tq_keep
      END IF
      CALL CD_HFMF_PackMirror(cab, mirror, es, em)
      CALL CD_HFMF_Snapshot(cab, es, em)
      CALL coupled_march(cab, 250, 251, ok2)
      CALL CD_HFMF_Restore(cab, es, em)
      CALL require(es == CD_HFMF_OK .AND. ok2 .AND. same_bits([cab%line%torsion%torque], [tq_keep]), &
                   'R: the snapshot brings back the committed torque of a frame write as it was formed')
      CALL build_coupled(cab3, es, em)
      CALL coupled_command(cab3, 250, es, em, restored=.TRUE.)
      CALL CD_HFMF_UnpackMirror(cab3, mirror, t, es, em)
      CALL require(es == CD_HFMF_OK .AND. same_bits([cab3%line%torsion%torque], [tq_keep]), &
                   'R: the mirror brings back the committed torque of a frame write as it was formed')
      CALL CD_HFMF_End(cab3)
    END BLOCK
    CALL CD_HFMF_End(cab)
    CALL CD_HFMF_End(cab2)
  END SUBROUTINE check_restart

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_deck(path)
    !! The straight neutral 100 m torsion line of test_coupled_torsion (40 segments, GJ 5e4,
    !! Irn 1e-9, torsional damping -zeta = -0.1), End A Coupled at (0, 0, -50) with a 30 deg
    !! pretwist, End B Fixed, controlled on channel 1; outputs Torq1N1 and Twist1.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u
    CHARACTER(160) :: neutral_type
    WRITE (neutral_type, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4|0|-0.1 1.0 1.0e-9 0.0 0.0 0.0 0.0'
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'controlled torsion line'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(neutral_type)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 0 1 30'
    WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 0 1 0'
    WRITE (u, '(A)') '--- CONTROL ---'
    WRITE (u, '(A)') 'ChannelID Line(s)'
    WRITE (u, '(A)') '(-) (-)'
    WRITE (u, '(A)') '1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') 'Twist1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE deck_command(step, dl, dldot)
    !! A haul-in of 0.1 m on a half cosine over 1 s (20 steps of 0.05 s), then held.
    INTEGER, INTENT(IN) :: step
    REAL(wp), INTENT(OUT) :: dl, dldot
    REAL(wp) :: t
    t = 0.05_wp*REAL(step, wp)
    IF (t < 1.0_wp) THEN
      dl = -0.1_wp*0.5_wp*(1.0_wp - COS(PI*t))
      dldot = -0.1_wp*0.5_wp*PI*SIN(PI*t)
    ELSE
      dl = -0.1_wp
      dldot = 0.0_wp
    END IF
  END SUBROUTINE deck_command

  SUBROUTINE check_deck()
    !! S: reference A marches 30 steps (the ramp and a hold), Torq1N1 against GJ Twist1/L(t).
    !! B is rebuilt at step 12 (mid-ramp) with the shell's recipe (torsion mirror, coupled
    !! kinematics, the command re-applied as committed, full mirror) and both march 12 more.
    REAL(wp), PARAMETER :: DT = 0.05_wp, GJD = 5.0e4_wp, DEG = PI/180.0_wp
    TYPE(CD_AGG_ModuleType) :: a, b
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), orient(3, 3, 1), omega(3, 1), alpha(3, 1)
    REAL(wp) :: dl, dldot, tq, tw, tqb, twb, err, lt, t
    REAL(wp), ALLOCATABLE :: mirror(:)
    INTEGER :: es, ni, k
    LOGICAL :: cv, st, same
    CHARACTER(512) :: em
    CALL write_deck('ctl_torsion_deck.dat')
    CALL CD_AGG_Init_From_Deck(a, 'ctl_torsion_deck.dat', DT, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_AGG_OK, 'S: a deck with CONTROL on a line restrained in torsion initialises: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL require(a%ctrl_is_cable(1) .AND. a%cables(1)%line%tw_active .AND. &
                 a%ctrl_elem(1) + a%ctrl_nelem(1) - 1 == a%cables(1)%line%ne, &
                 'S: the row controls the fairlead segment of the nodal-twist cable')
    CALL require(ALLOCATED(a%cables(1)%line%torsion%bt_zeta), 'S: the deck keeps the -zeta of its torsional damping')
    IF (.NOT. ALLOCATED(a%cables(1)%line%torsion%bt_zeta)) RETURN
    CALL require(ALL(a%cables(1)%line%torsion%bt_zeta == 0.1_wp), 'S: zeta = 0.1 on every element')
    CALL CD_AGG_GetMovingPointMesh(a, pos, vel, acc, load, es, em, orientation=orient)
    omega = 0.0_wp
    alpha = 0.0_wp
    err = 0.0_wp
    same = .TRUE.
    DO k = 1, 30
      CALL deck_command(k, dl, dldot)
      CALL CD_AGG_Apply_LineControl(a, [dl], [dldot], es, em)
      CALL require(es == CD_AGG_OK, 'S: command: '//TRIM(em))
      CALL CD_AGG_Step_Moving(a, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, 'S: step: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_CalcOutput(a, es, em)
      CALL CD_AGG_EvalChannel(a, 1, tq, es, em)
      CALL CD_AGG_EvalChannel(a, 2, tw, es, em)
      IF (k == 10) THEN
        ASSOCIATE (cl => a%cables(1)%line, e1 => a%ctrl_elem(1))
          CALL require(ALL(cl%torsion%bt(e1:cl%ne) == CD_HermiteTorsion_Zeta_Damping(0.1_wp, cl%l0(e1:cl%ne), GJD, &
                                                                                     1.0e-9_wp)), &
                       'S: the commanded elements re-resolve the deck''s -zeta at their new lengths')
        END ASSOCIATE
      END IF
      lt = 100.0_wp + dl
      err = MAX(err, ABS(tq - GJD*tw*DEG/lt)/ABS(GJD*tw*DEG/lt))
      IF (k == 12) THEN
        t = DT*REAL(k, wp)
        ALLOCATE (mirror(CD_HFMF_MirrorSize(a%cables(1))))
        CALL CD_HFMF_PackMirror(a%cables(1), mirror, es, em)
        CALL CD_AGG_Init_From_Deck(b, 'ctl_torsion_deck.dat', DT, es, em, host_orientation=.TRUE.)
        CALL require(es == CD_AGG_OK, 'S: rebuild: '//TRIM(em))
        CALL CD_HFMF_UnpackMirror(b%cables(1), mirror, t, es, em)
        CALL require(es == CD_HFMF_OK, 'S: torsion mirror first: '//TRIM(em))
        CALL CD_AGG_UpdateStates_Moving(b, pos, vel, acc, es, em, orientation=orient, angular_velocity=omega, &
                                        angular_acceleration=alpha)
        CALL require(es == CD_AGG_OK, 'S: coupled kinematics: '//TRIM(em))
        CALL CD_AGG_Apply_LineControl(b, [dl], [dldot], es, em, restored=.TRUE.)
        CALL require(es == CD_AGG_OK, 'S: the checkpointed command re-applied: '//TRIM(em))
        CALL CD_HFMF_UnpackMirror(b%cables(1), mirror, t, es, em)
        CALL require(es == CD_HFMF_OK, 'S: full mirror: '//TRIM(em))
      ELSE IF (k > 12 .AND. k <= 24) THEN
        CALL CD_AGG_Apply_LineControl(b, [dl], [dldot], es, em)
        CALL CD_AGG_Step_Moving(b, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                                angular_velocity=omega, angular_acceleration=alpha)
        CALL require(es == CD_AGG_OK .AND. cv, 'S: restarted step: '//TRIM(em))
        CALL CD_AGG_CalcOutput(b, es, em)
        CALL CD_AGG_EvalChannel(b, 1, tqb, es, em)
        CALL CD_AGG_EvalChannel(b, 2, twb, es, em)
        same = same .AND. same_bits(a%cables(1)%line%q, b%cables(1)%line%q) .AND. &
               same_bits(a%cables(1)%line%tw_phi, b%cables(1)%line%tw_phi) .AND. same_bits([tq, tw], [tqb, twb])
      END IF
    END DO
    WRITE (*, '(A,F9.4,A,ES15.7,A,ES10.3)') 'S deck: Twist1 ', tw, ' deg, Torq1N1 ', tq, &
      '; max rel. error against GJ Twist1/L(t) ', err
    CALL require(ABS(ABS(tw) - 30.0_wp) <= 1.0e-6_wp, 'S: the line keeps its 30 deg twist')
    CALL require(err <= 1.0e-6_wp, 'S: Torq1N1 follows GJ Twist1/L(t) through the haul-in')
    CALL require(same, 'S: the checkpoint restart mid-ramp continues bit-identically')
    CALL CD_AGG_End(a, es, em)
    CALL CD_AGG_End(b, es, em)
  END SUBROUTINE check_deck

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_deck_one_end(kfree)
    !! O: the controlled line free in torsion at deck End kfree (1 = A, the fairlead, 2 = B).
    REAL(wp), PARAMETER :: DT = 0.05_wp, GJD = 5.0e4_wp, KD = 4.0e5_wp, EAD = 1.0e7_wp, H0 = 100.0_wp, &
                           L0D = 99.0_wp, DLMAX = 0.2_wp, TR = 2.0_wp, DEG = PI/180.0_wp
    INTEGER, PARAMETER :: NSTEP = 80
    INTEGER, INTENT(IN) :: kfree
    TYPE(CD_AGG_ModuleType) :: a
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), orient(3, 3, 1), omega(3, 1), alpha(3, 1)
    REAL(wp) :: dl, dldot, tw, tqa, tqb, ten, tw_ref, ten_ref, e_tw, e_tq, e_ten, t, ten_sum
    INTEGER :: es, ni, k, u, n_hold
    LOGICAL :: cv, st
    CHARACTER(512) :: em
    CHARACTER(160) :: ltype
    CHARACTER(2) :: tag
    tag = MERGE('A ', 'B ', kfree == 1)
    WRITE (ltype, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4|4.0e5 1.0 1.0e-9 0.0 0.0 0.0 0.0'
    OPEN (NEWUNIT=u, FILE='ctl_torsion_one_end.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'controlled line restrained in torsion at one end'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(ltype)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 99.0 40'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    IF (kfree == 1) THEN
      WRITE (u, '(A)') '1 A Rigid 1 0 0 Free 0 0 1'
      WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 0 1 30'
    ELSE
      WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 0 1 -30'
      WRITE (u, '(A)') '1 B Rigid 1 0 0 Free 0 0 1'
    END IF
    WRITE (u, '(A)') '--- CONTROL ---'
    WRITE (u, '(A)') 'ChannelID Line(s)'
    WRITE (u, '(A)') '(-) (-)'
    WRITE (u, '(A)') '1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Twist1'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') 'Torq1N41'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL CD_AGG_Init_From_Deck(a, 'ctl_torsion_one_end.dat', DT, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_AGG_OK, 'O (End '//TRIM(tag)//' free): a CONTROL deck on a line restrained at one end '// &
                 'initialises with its twist channels: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL require(a%ctrl_is_cable(1) .AND. a%cables(1)%line%tw_active .AND. &
                 a%cables(1)%line%torsion%end_free(3 - kfree), &
                 'O: the row controls the nodal-twist cable, free at the deck end')
    CALL CD_AGG_GetMovingPointMesh(a, pos, vel, acc, load, es, em, orientation=orient)
    omega = 0.0_wp
    alpha = 0.0_wp
    e_tw = 0.0_wp
    e_tq = 0.0_wp
    e_ten = 0.0_wp
    ten_sum = 0.0_wp
    n_hold = 0
    DO k = 1, NSTEP
      t = DT*REAL(k, wp)
      IF (t < TR) THEN
        dl = DLMAX*0.5_wp*(1.0_wp - COS(PI*t/TR))
        dldot = DLMAX*0.5_wp*PI/TR*SIN(PI*t/TR)
      ELSE
        dl = DLMAX
        dldot = 0.0_wp
      END IF
      CALL CD_AGG_Apply_LineControl(a, [dl], [dldot], es, em)
      CALL require(es == CD_AGG_OK, 'O: command: '//TRIM(em))
      CALL CD_AGG_Step_Moving(a, DT, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, 'O: step: '//TRIM(em))
      IF (es /= CD_AGG_OK) RETURN
      CALL CD_AGG_CalcOutput(a, es, em)
      CALL CD_AGG_EvalChannel(a, 1, tw, es, em)
      CALL CD_AGG_EvalChannel(a, 2, tqa, es, em)
      CALL CD_AGG_EvalChannel(a, 3, tqb, es, em)
      CALL CD_AGG_EvalChannel(a, 4, ten, es, em)
      tw_ref = -(KD/GJD)*(H0 - L0D - dl)/DEG
      e_tw = MAX(e_tw, ABS(tw - tw_ref)/ABS(tw_ref))
      ! against the torque K eps the coupling would give a section held from twisting
      e_tq = MAX(e_tq, ABS(tqa), ABS(tqb))
      IF (t > TR) THEN
        ten_sum = ten_sum + ten
        n_hold = n_hold + 1
      END IF
    END DO
    ten_ref = (EAD - KD**2/GJD)*(H0 - L0D - DLMAX)/(L0D + DLMAX)
    e_ten = ABS(ten_sum/REAL(n_hold, wp) - ten_ref)/ten_ref
    e_tq = e_tq/(KD*(H0 - L0D - DLMAX)/(L0D + DLMAX))
    WRITE (*, '(A,A,A,F12.5,A,F12.5,A,3ES10.3)') 'O deck, End ', TRIM(tag), ' free, paid out 0.2 m: Twist1 ', tw, &
      ' deg (-(K/GJ)(H - L) ', tw_ref, '); max rel. errors twist, |torque| / K eps, mean held tension ', e_tw, &
      e_tq, e_ten
    CALL require(e_tw <= 1.0e-6_wp, 'O: the free end turns with the commanded length, -(K/GJ)(H - L(t))')
    CALL require(e_tq <= 1.0e-6_wp, 'O: no torque at either end')
    CALL require(e_ten <= 5.0e-4_wp, 'O: the mean held tension is (EA - K^2/GJ) eps')
    CALL CD_AGG_End(a, es, em)
  END SUBROUTINE check_deck_one_end

END PROGRAM test_control_torsion
