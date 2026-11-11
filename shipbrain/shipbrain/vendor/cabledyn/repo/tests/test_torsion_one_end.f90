! File: tests/test_torsion_one_end.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_torsion_one_end
  !! Gates of a finite-EI line restrained in torsion at one end only, its other end free to twist
  !! (END CONNECTIONS TorsStiffness Free there, or no row): the free end carries no torque and
  !! turns with the twist of the line.
  !!   M  modes and waves of the cubic-Hermite dynamics: a straight taut 10 m line (GJ 80 N m2,
  !!      Irn 0.5 kg m, 20 elements, clamped in bending, both end positions held), rigid in
  !!      torsion at one end and free at the other, the free end at internal end 2 (deck End A)
  !!      and at internal end 1 (deck End B) in turn:
  !!      M1 released from a twist (the restrained end's frame turned by 0.2 rad over a quarter
  !!         period, then held), the free end rings at the quarter-wave frequencies of the
  !!         clamped-free continuum, omega_n = (2n - 1) pi/(2L) sqrt(GJ/Irn), n = 1, 2 (the peaks
  !!         of its Hann-windowed spectrum, 0.4 % and 1 %);
  !!      M2 driven in roll A sin(Omega t) at the restrained end, Omega = omega_1/2 and
  !!         3 omega_1/2 (kL = pi/4, 3 pi/4): the free end rolls with the continuum's A/cos kL
  !!         (in antiphase above the first mode) and the restrained end's support reacts with
  !!         GJ A k tan kL (1 %, the Fourier components at Omega); the free end's support takes
  !!         no torque;
  !!      M3 a snapshot of the driven run, restored, continues bit-identically.
  !!   C  torque-tension coupling on the deck (standalone driver): a straight neutral cable (EA
  !!      1e7 N, GJ|K 5e4 N m2|4e5 N m) of 99 m held 100 m apart, restrained in torsion at one end:
  !!      C1 statics, End A free, End B free, and End A without an END CONNECTIONS row (End B an
  !!         elastic restraint): the stretch twists the line by -(K/GJ) sum (l_e - l0_e) = -8 rad
  !!         (Twist1, half of it at mid-line, Twist1N41 = Twist1), no torque anywhere, and the
  !!         tension (EA - K^2/GJ) eps of a section free to twist;
  !!      C2 a march moving End A 0.1 m away over 20 s (polar inertia negligible, Irn 1e-9): the
  !!         free end, the moving End A or the anchored End B, turns with the stretch at every
  !!         step, Twist1 = -(K/GJ)(l(t) - l0), and the tension follows (EA - K^2/GJ) eps(t);
  !!   D  torsional inertia on the deck: the 100 m line (GJ 5e4 N m2, Irn 1 kg m) restrained at
  !!      End A, free at End B, End A rolled A sin(Omega t) by the motionFile roll column at
  !!      Omega = omega_1/4 (kL = pi/8): the Fourier components at Omega of Twist1, Torq1N1 and
  !!      Torq1N41 are the continuum's, A (1/cos kL - 1) and GJ times its mean twist rate over the
  !!      end elements (the free end's element carries 1.3 % of the driven end's torque);
  !!   A  the coupled aggregate (End A host-driven, host_orientation): the C1 line free at End A
  !!      keeps its static twist and no torque while the platform rolls about the line axis (the
  !!      roll does not reach a free end), with no axial moment on the platform; the D line
  !!      restrained at End A rolled by the platform gives D's continuum response;
  !!   N  a line restrained at one end whose LINE TYPES row gives no GJ (10 columns) keeps the
  !!      meaning of the 6-column rows: its twist channels are refused with the reason; a solved
  !!      line's restrained Pretwist beyond 1000 turns is refused by name.
  !!   T  ATTACHMENTS on a line free at one end (the torsion stage after the attachment polish,
  !!      on the polished mesh):
  !!      T1 statics: the C1 cable hung vertically (99 m between points 100 m apart) carrying three
  !!         clumps and buoys of net weights w_k at nodes n_k, free at End A and at End B in turn.
  !!         The line stays straight and its section is free to twist, so each element carries
  !!         the tension T_e = T_A - sum_(n_k <= e) w_k and the strain T_e/(EA - K^2/GJ), with
  !!         sum_e l0 eps_e = H - L0: T_A = [(EA - K^2/GJ)(H - L0)/l0 + sum_k w_k (NE + 1 - n_k)]/NE.
  !!         The free end turns by Twist1 = -(K/GJ)(H - L0) whatever the weights, with no torque
  !!         and the tensions T_A, T_A - sum w_k; the mid-line node by -(K/GJ) sum_(e<=20) l0 eps_e
  !!         (0.8 % beyond the uniform strain's half) within 1e-3: the shared nodal tangent of
  !!         the cubic-Hermite elements spreads each tension step over its two elements, a
  !!         first-order mesh error (3.9e-4, 1.9e-4, 9.6e-5 at 40, 80, 160 elements);
  !!      T2 dynamics: the D roll of the restrained End A, the line taut (99.9 m over the span),
  !!         with three neutral modules (their mass is translational only, so the torsional
  !!         response is D's continuum over the 99.9 m).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Line, CD_HermiteTorsion_Unwrap, &
                                     CD_HTORS_OK
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_Step_Moving, CD_AGG_CalcOutput, CD_AGG_EvalChannel, CD_AGG_End, &
                                         CD_AGG_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_End, &
                                          CD_HermiteCable_Dyn_Set_EndConnection, CD_HermiteCable_Dyn_Set_Torsion, &
                                          CD_HermiteCable_Dyn_Set_Torsion_Drive, &
                                          CD_HermiteCable_Dyn_EndConnection_Moment, CD_HermiteCable_Dyn_Snapshot, &
                                          CD_HermiteCable_Dyn_Restore, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, RHOW = 1025.0_wp, DEG = PI/180.0_wp
  ! the deck cable of gates C, D, A: EA 1e7 N, GJ 5e4 N m2 and, under coupling, K 4e5 N m
  REAL(wp), PARAMETER :: EA_D = 1.0e7_wp, GJ_D = 5.0e4_wp, K_D = 4.0e5_wp, SPAN = 100.0_wp, L0_D = 99.0_wp
  REAL(wp), PARAMETER :: LL = 10.0_wp, EA = 1.0e5_wp, EI = 100.0_wp, GJ = 80.0_wp, RHOA = 1.0_wp, IRN = 0.5_wp
  INTEGER, PARAMETER :: NE = 20, NN = NE + 1, NDOF = 6*NN
  INTEGER :: nfail = 0, kfree, mom_sign(2) = 0

  DO kfree = 2, 1, -1
    CALL check_modes(kfree)
    CALL check_driven(kfree, 0.5_wp)
    CALL check_driven(kfree, 1.5_wp)
  END DO
  CALL check_restore()
  CALL check_deck_statics()
  CALL check_deck_stretch()
  CALL check_deck_inertia()
  CALL check_aggregate()
  CALL check_not_solved()
  CALL check_attachments_statics()
  CALL check_attachments_inertia()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: one-end torsion gates'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: '//TRIM(label)
  END SUBROUTINE require

  CHARACTER(5) FUNCTION end_name(kf) RESULT(s)
    !! The deck end of internal end kf (internal end 1 is End B, end 2 End A).
    INTEGER, INTENT(IN) :: kf
    s = MERGE('End B', 'End A', kf == 1)
  END FUNCTION end_name

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE build_line(m, kf, ok)
    !! The straight line along +x (node 1 at the origin), clamped in bending at both ends (end
    !! positions held), rigid in torsion at internal end 3 - kf and free at internal end kf; both
    !! end frames (+x, +z); rho_inf 1 (no numerical dissipation).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    INTEGER, INTENT(IN) :: kf
    LOGICAL, INTENT(OUT) :: ok
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: q(NDOF), l0(NE), g(NDOF), raw
    INTEGER :: k, es
    CHARACTER(300) :: em
    l0 = LL/REAL(NE, wp)
    q = 0.0_wp
    DO k = 1, NN
      q(6*k - 5) = LL*REAL(k - 1, wp)/REAL(NE, wp)
      q(6*k - 2) = 1.0_wp
    END DO
    CALL CD_HermiteCable_Dyn_Init(m, l0, [(EA, k=1, NE)], [(EI, k=1, NE)], [(RHOA, k=1, NE)], [(0.0_wp, k=1, NE)], q, &
                                  [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    ok = es == CD_HCDYN_OK
    CALL require(ok, 'init: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL CD_HermiteCable_Dyn_Set_EndConnection(m, [0.0_wp, 0.0_wp], &
                                               RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], [3, 2]), &
                                               es, em, connection_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
    ok = es == CD_HCDYN_OK
    CALL require(ok, 'end connections: '//TRIM(em))
    IF (.NOT. ok) RETURN
    tors%active = .TRUE.
    tors%ends = frames(0.0_wp)
    tors%end_free(kf) = .TRUE.
    ALLOCATE (tors%gj(NE), tors%irn(NE))
    tors%gj = GJ
    tors%irn = IRN
    CALL CD_HermiteTorsion_Line(q, l0, tors%ends, raw, g, es, em)
    CALL require(es == CD_HTORS_OK, 'seed twist evaluates: '//TRIM(em))
    tors%theta = CD_HermiteTorsion_Unwrap(raw, 0.0_wp)
    tors%has_theta = .TRUE.
    CALL CD_HermiteCable_Dyn_Set_Torsion(m, tors, es, em)
    ok = es == CD_HCDYN_OK .AND. m%tw_active
    CALL require(ok, 'one-end torsion installs the nodal twist ('//end_name(kf)//' free): '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL require(m%torsion%torque == 0.0_wp, 'one-end torsion: no condensed torque')
  END SUBROUTINE build_line

  FUNCTION frames(ang) RESULT(ends)
    !! Both end frames (+x, +z), the restrained end's turned by ang about +x by the caller.
    REAL(wp), INTENT(IN) :: ang
    REAL(wp) :: ends(3, 4)
    ends(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
    ends(:, 2) = [0.0_wp, -SIN(ang), COS(ang)]
    ends(:, 3) = [1.0_wp, 0.0_wp, 0.0_wp]
    ends(:, 4) = [0.0_wp, -SIN(ang), COS(ang)]
  END FUNCTION frames

  SUBROUTINE drive_step(m, kf, ang, dt, ok)
    !! One step with the restrained end's frame turned to ang about +x (the free end's held).
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    INTEGER, INTENT(IN) :: kf
    REAL(wp), INTENT(IN) :: ang, dt
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: ends(3, 4), turned(3, 4)
    INTEGER :: es, kr
    CHARACTER(300) :: em
    kr = 3 - kf
    ends = frames(0.0_wp)
    turned = frames(ang)
    ends(:, 2*kr - 1:2*kr) = turned(:, 2*kr - 1:2*kr)
    CALL CD_HermiteCable_Dyn_Set_Torsion_Drive(m, ends, 0.0_wp, es, em)
    IF (es == CD_HCDYN_OK) CALL CD_HermiteCable_Dyn_Step(m, dt, 40, 1.0e-11_wp, es, em)
    ok = es == CD_HCDYN_OK
    IF (.NOT. ok) WRITE (*, '(A)') '  step: '//TRIM(em)
  END SUBROUTINE drive_step

  REAL(wp) FUNCTION free_roll(m, kf) RESULT(r)
    !! The roll of the free end's section about +x: its twist angle against its director, which
    !! the straight, unmoving line keeps fixed (no transport).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: m
    INTEGER, INTENT(IN) :: kf
    r = m%tw_phi(MERGE(1, NN, kf == 1))
  END FUNCTION free_roll

  REAL(wp) FUNCTION axial_moment(m, node) RESULT(mx)
    !! The axial (x) component of the line's moment on the support of end node node.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    INTEGER, INTENT(IN) :: node
    REAL(wp) :: mom(3)
    INTEGER :: es
    CHARACTER(300) :: em
    CALL CD_HermiteCable_Dyn_EndConnection_Moment(m, node, mom, es, em)
    CALL require(es == CD_HCDYN_OK, 'end moment: '//TRIM(em))
    mx = mom(1)
  END FUNCTION axial_moment

  REAL(wp) FUNCTION ramp(t, tr) RESULT(s)
    !! C2 quintic from 0 at t = 0 to 1 at t = tr.
    REAL(wp), INTENT(IN) :: t, tr
    REAL(wp) :: x
    x = MIN(MAX(t/tr, 0.0_wp), 1.0_wp)
    s = x**3*(10.0_wp - 15.0_wp*x + 6.0_wp*x**2)
  END FUNCTION ramp

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_modes(kf)
    !! M1: released from a twist, the free end rings at the clamped-free frequencies.
    INTEGER, INTENT(IN) :: kf
    REAL(wp), PARAMETER :: AMP = 0.2_wp
    INTEGER, PARAMETER :: NPP = 200, NPER = 40
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: c, om1, dt, tr, t, ang, err(2), peak(2)
    REAL(wp), ALLOCATABLE :: sig(:), ts(:)
    INTEGER :: k, n, nrec, nstep
    LOGICAL :: ok
    c = SQRT(GJ/IRN)
    om1 = 0.5_wp*PI*c/LL
    dt = 2.0_wp*PI/om1/REAL(NPP, wp)
    tr = 0.25_wp*2.0_wp*PI/om1
    CALL build_line(m, kf, ok)
    IF (.NOT. ok) RETURN
    nstep = NPER*NPP + NINT(tr/dt)
    ALLOCATE (sig(nstep), ts(nstep))
    nrec = 0
    DO k = 1, nstep
      t = dt*REAL(k, wp)
      ang = AMP*ramp(t, tr)
      CALL drive_step(m, kf, ang, dt, ok)
      CALL require(ok, 'M1 ('//end_name(kf)//' free): step')
      IF (.NOT. ok) EXIT
      IF (t > tr) THEN
        nrec = nrec + 1
        sig(nrec) = free_roll(m, kf) - AMP
        ts(nrec) = t
      END IF
    END DO
    IF (ok) THEN
      DO n = 1, 2
        peak(n) = spectrum_peak(sig(1:nrec), ts(1:nrec), REAL(2*n - 1, wp)*om1)
        err(n) = peak(n)/(REAL(2*n - 1, wp)*om1) - 1.0_wp
      END DO
      WRITE (*, '(A,A,A,2F10.5,A,2F10.5,A,2ES10.2)') 'M1 ', end_name(kf), ' free: ring-down peaks ', peak, &
        ' rad/s, quarter-wave ', om1, 3.0_wp*om1, ' rad/s, errors ', err
      CALL require(ABS(err(1)) <= 4.0e-3_wp, 'M1 ('//end_name(kf)//' free): the first mode is the quarter wave')
      CALL require(ABS(err(2)) <= 1.0e-2_wp, 'M1 ('//end_name(kf)//' free): the second mode is three quarter waves')
    END IF
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_modes

  REAL(wp) FUNCTION spectrum_peak(x, t, om0) RESULT(om_pk)
    !! The frequency of the largest Hann-windowed Fourier amplitude of x(t) within 15 % of om0.
    REAL(wp), INTENT(IN) :: x(:), t(:), om0
    INTEGER, PARAMETER :: NGRID = 3001
    INTEGER :: i, j, n
    REAL(wp) :: om, w, re, im, amp, best, t0, span
    n = SIZE(x)
    t0 = t(1)
    span = t(n) - t0
    best = -1.0_wp
    om_pk = om0
    DO j = 1, NGRID
      om = om0*(0.85_wp + 0.3_wp*REAL(j - 1, wp)/REAL(NGRID - 1, wp))
      re = 0.0_wp
      im = 0.0_wp
      DO i = 1, n
        w = 0.5_wp - 0.5_wp*COS(2.0_wp*PI*(t(i) - t0)/span)
        re = re + w*x(i)*COS(om*(t(i) - t0))
        im = im + w*x(i)*SIN(om*(t(i) - t0))
      END DO
      amp = re*re + im*im
      IF (amp > best) THEN
        best = amp
        om_pk = om
      END IF
    END DO
  END FUNCTION spectrum_peak

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_driven(kf, ratio)
    !! M2: the restrained end rolled A sin(Omega t) (amplitude ramped in over eight periods),
    !! Omega = ratio omega_1. Over six periods after one more, the Fourier components at Omega
    !! (orthogonal there to the free modes the ramp leaves ringing, omega_1 and 3 omega_1) of the
    !! free end's roll and of the restrained support's axial reaction are the continuum's:
    !! A/cos kL (in phase below the first mode, in antiphase above it) and GJ A k tan kL, the
    !! latter with a sign the same at both frequencies.
    INTEGER, INTENT(IN) :: kf
    REAL(wp), INTENT(IN) :: ratio
    REAL(wp), PARAMETER :: AMP = 0.2_wp
    INTEGER, PARAMETER :: NPER_RAMP = 8, NPER_MEAS = 6, NPP = 200
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: c, om, dt, t, ramp_t, kw, fmax, roll_ref, mom_ref, e_roll, e_mom, s, co
    REAL(wp) :: rs, rc, ms, mc, a_roll, a_mom, mf
    INTEGER :: k, node_r, node_f, k0
    LOGICAL :: ok
    CHARACTER(8) :: lab
    c = SQRT(GJ/IRN)
    om = ratio*0.5_wp*PI*c/LL
    dt = 2.0_wp*PI/om/REAL(NPP, wp)
    WRITE (lab, '(F4.2)') ratio
    CALL build_line(m, kf, ok)
    IF (.NOT. ok) RETURN
    node_r = MERGE(NN, 1, kf == 1)
    node_f = MERGE(1, NN, kf == 1)
    ramp_t = REAL(NPER_RAMP, wp)*2.0_wp*PI/om
    k0 = (NPER_RAMP + 1)*NPP
    rs = 0.0_wp
    rc = 0.0_wp
    ms = 0.0_wp
    mc = 0.0_wp
    fmax = 0.0_wp
    DO k = 1, k0 + NPER_MEAS*NPP
      t = dt*REAL(k, wp)
      CALL drive_step(m, kf, AMP*ramp(t, ramp_t)*SIN(om*t), dt, ok)
      CALL require(ok, 'M2 ('//end_name(kf)//' free, Omega/omega_1 = '//TRIM(lab)//'): step')
      IF (.NOT. ok) EXIT
      IF (k > k0) THEN
        s = SIN(om*t)
        co = COS(om*t)
        rs = rs + free_roll(m, kf)*s
        rc = rc + free_roll(m, kf)*co
        ms = ms + axial_moment(m, node_r)*s
        mc = mc + axial_moment(m, node_r)*co
        mf = axial_moment(m, node_f)
        fmax = MAX(fmax, ABS(mf))
      END IF
    END DO
    IF (ok) THEN
      rs = 2.0_wp*rs/REAL(NPER_MEAS*NPP, wp)
      rc = 2.0_wp*rc/REAL(NPER_MEAS*NPP, wp)
      ms = 2.0_wp*ms/REAL(NPER_MEAS*NPP, wp)
      mc = 2.0_wp*mc/REAL(NPER_MEAS*NPP, wp)
      kw = om/c
      roll_ref = AMP/COS(kw*LL)
      mom_ref = GJ*AMP*kw*TAN(kw*LL)
      a_roll = rs
      a_mom = ms
      e_roll = a_roll/roll_ref - 1.0_wp
      e_mom = ABS(a_mom/mom_ref) - 1.0_wp
      WRITE (*, '(A,A,A,F4.2,A,2ES13.5,A,2ES13.5,A,2ES10.2,A,2ES9.2,A,ES9.2)') 'M2 ', end_name(kf), &
        ' free, Omega/omega_1 = ', ratio, ': free-end roll and driven torque at Omega ', a_roll, a_mom, &
        ' continuum ', roll_ref, mom_ref, ' errors ', e_roll, e_mom, '; quadrature ', rc/roll_ref, mc/mom_ref, &
        '; free-end axial moment ', fmax
      CALL require(ABS(e_roll) <= 1.0e-2_wp .AND. ABS(rc) <= 1.0e-2_wp*ABS(roll_ref), &
                   'M2 ('//end_name(kf)//' free, '//TRIM(lab)//'): the free end rolls by A/cos kL')
      CALL require(ABS(e_mom) <= 1.0e-2_wp .AND. ABS(mc) <= 1.0e-2_wp*ABS(mom_ref), &
                   'M2 ('//end_name(kf)//' free, '//TRIM(lab)//'): the restrained end reacts with GJ A k tan kL')
      IF (mom_sign(kf) == 0) THEN
        mom_sign(kf) = NINT(SIGN(1.0_wp, a_mom/mom_ref))
      ELSE
        CALL require(mom_sign(kf) == NINT(SIGN(1.0_wp, a_mom/mom_ref)), 'M2 ('//end_name(kf)//' free, '// &
                     TRIM(lab)//'): the reaction turns sign with tan kL across the first mode')
      END IF
      CALL require(fmax <= 1.0e-9_wp*ABS(mom_ref), 'M2 ('//end_name(kf)//' free, '//TRIM(lab)// &
                   '): the free end transmits no torque')
    END IF
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_driven

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_restore()
    !! M3: the driven run of the End A free line: 300 steps, snapshot, 100 more; restored, the
    !! same 100 steps are bit-identical.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: dt, om, qref(NDOF), pref(NN)
    INTEGER :: k, es
    LOGICAL :: ok
    CHARACTER(300) :: em
    om = 0.5_wp*0.5_wp*PI*SQRT(GJ/IRN)/LL
    dt = 2.0_wp*PI/om/200.0_wp
    CALL build_line(m, 2, ok)
    IF (.NOT. ok) RETURN
    DO k = 1, 300
      CALL drive_step(m, 2, 0.2_wp*ramp(dt*k, 50.0_wp*dt)*SIN(om*dt*k), dt, ok)
      IF (.NOT. ok) EXIT
    END DO
    CALL CD_HermiteCable_Dyn_Snapshot(m, es, em)
    CALL require(ok .AND. es == CD_HCDYN_OK, 'M3: snapshot: '//TRIM(em))
    DO k = 301, 400
      CALL drive_step(m, 2, 0.2_wp*SIN(om*dt*k), dt, ok)
      IF (.NOT. ok) EXIT
    END DO
    qref = m%q
    pref = m%tw_phi
    CALL CD_HermiteCable_Dyn_Restore(m, es, em)
    CALL require(es == CD_HCDYN_OK, 'M3: restore: '//TRIM(em))
    DO k = 301, 400
      CALL drive_step(m, 2, 0.2_wp*SIN(om*dt*k), dt, ok)
      IF (.NOT. ok) EXIT
    END DO
    CALL require(ok .AND. ALL(bits(m%q) == bits(qref)) .AND. ALL(bits(m%tw_phi) == bits(pref)), &
                 'M3: the restored one-end run continues bit-identically')
    WRITE (*, '(A,ES13.5,A)') 'M3 restore: free-end roll ', pref(NN), ' rad, restored run identical'
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_restore

  ! ------------------------------------------------------------------------------------------
  ! deck gates
  ! ------------------------------------------------------------------------------------------
  CHARACTER(160) FUNCTION type_row(gj_col, irn) RESULT(row)
    !! The neutral 0.2 m LINE TYPES row (mass rhoW pi d^2/4, EA 1e7, EI 1e6, GAs 1e8) with the GJ
    !! column gj_col and the polar inertia irn.
    CHARACTER(*), INTENT(IN) :: gj_col
    REAL(wp), INTENT(IN) :: irn
    WRITE (row, '(A,ES24.16,A,ES12.5,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, ' 1.0e7 0.0 1.0e6 1.0e8 '// &
      TRIM(gj_col)//' 1.0 ', irn, ' 0.0 0.0 0.0 0.0'
  END FUNCTION type_row

  SUBROUTINE write_deck(path, trow, conns, length, options, outs, ten_cols, atts, end_b)
    !! The straight cable along +x from a Coupled End A (0, 0, -50) to a Fixed End B (100, 0, -50)
    !! (or end_b), 40 elements over length, LINE TYPES row trow (14 columns, or 10 with ten_cols),
    !! END CONNECTIONS rows conns (none when empty), ATTACHMENTS rows atts, then options and outs.
    CHARACTER(*), INTENT(IN) :: path, trow, conns(:), options(:), outs(:)
    REAL(wp), INTENT(IN) :: length
    LOGICAL, INTENT(IN), OPTIONAL :: ten_cols
    CHARACTER(*), INTENT(IN), OPTIONAL :: atts(:)
    REAL(wp), INTENT(IN), OPTIONAL :: end_b(3)
    INTEGER :: u, i
    LOGICAL :: ten
    ten = .FALSE.
    IF (PRESENT(ten_cols)) ten = ten_cols
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'one-end torsion gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    IF (ten) THEN
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    ELSE
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    END IF
    WRITE (u, '(A)') TRIM(trow)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0 0 0 0 0'
    IF (PRESENT(end_b)) THEN
      WRITE (u, '(A,3ES24.16,A)') '2 Fixed ', end_b, ' 0 0 0 0'
    ELSE
      WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0 0 0 0 0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A,F10.4,A)') '1 cab ', length, ' 40'
    IF (PRESENT(atts)) THEN
      WRITE (u, '(A)') '--- ATTACHMENTS ---'
      WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca'
      WRITE (u, '(A)') '(-) (m) (kg) (m3) (m2) (-)'
      DO i = 1, SIZE(atts)
        WRITE (u, '(A)') TRIM(atts(i))
      END DO
    END IF
    IF (SIZE(conns) > 0) THEN
      WRITE (u, '(A)') '--- END CONNECTIONS ---'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
      DO i = 1, SIZE(conns)
        WRITE (u, '(A)') TRIM(conns(i))
      END DO
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    DO i = 1, SIZE(options)
      WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    DO i = 1, SIZE(outs)
      WRITE (u, '(A)') TRIM(outs(i))
    END DO
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE run_deck(path, root, ok, em)
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT) :: em
    LOGICAL :: conv
    INTEGER :: es
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
  END SUBROUTINE run_deck

  SUBROUTINE read_out(path, ncol, rows, nrow)
    !! Every data row of a driver .out file (time first, then ncol - 1 channels).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: ncol
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: rows(:, :)
    INTEGER, INTENT(OUT) :: nrow
    REAL(wp), ALLOCATABLE :: tmp(:, :)
    REAL(wp) :: v(ncol)
    INTEGER :: u, ios
    CHARACTER(4096) :: buf
    nrow = 0
    ALLOCATE (rows(ncol, 64))
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO
      READ (u, *, IOSTAT=ios) v
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      IF (nrow > SIZE(rows, 2)) THEN
        ALLOCATE (tmp(ncol, 2*SIZE(rows, 2)))
        tmp(:, 1:nrow - 1) = rows(:, 1:nrow - 1)
        CALL MOVE_ALLOC(tmp, rows)
      END IF
      rows(:, nrow) = v
    END DO
    CLOSE (u)
  END SUBROUTINE read_out

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_deck_statics()
    !! C1: the static coupling twist of a line free at one end.
    CHARACTER(16), PARAMETER :: OUTS(8) = [CHARACTER(16) :: 'FairTen1', 'Torq1N1', 'Torq1N21', 'Torq1N41', &
                                                                          'Twist1N21', 'Twist1N41', 'Twist1', 'Ten1N21']
    CHARACTER(48) :: conns(2, 3)
    CHARACTER(24), PARAMETER :: LABEL(3) = [CHARACTER(24) :: 'End A free', 'End B free', 'End A without a row']
    REAL(wp), ALLOCATABLE :: rows(:, :)
    REAL(wp) :: eps, t_ref, tw_ref, e_t, e_tw, e_m
    INTEGER :: iv, nrow, nconn
    LOGICAL :: ok
    CHARACTER(512) :: em
    conns(:, 1) = [CHARACTER(48) :: '1 A Rigid 1 0 0 Free 0 0 1', '1 B Rigid 1 0 0 Rigid 0 0 1 30']
    conns(:, 2) = [CHARACTER(48) :: '1 A Rigid 1 0 0 Rigid 0 0 1 -30', '1 B Rigid 1 0 0 Free 0 0 1']
    conns(:, 3) = [CHARACTER(48) :: '1 B Rigid 1 0 0 1.0e5 0 0 1 10', '']
    eps = SPAN/L0_D - 1.0_wp
    t_ref = (EA_D - K_D**2/GJ_D)*eps
    tw_ref = -(K_D/GJ_D)*(SPAN - L0_D)/DEG
    DO iv = 1, 3
      nconn = MERGE(1, 2, iv == 3)
      CALL write_deck('t1e_static.dat', type_row('5.0e4|4.0e5', 1.0e-9_wp), conns(1:nconn, iv), L0_D, &
                      [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], OUTS)
      CALL run_deck('t1e_static.dat', 't1e_static', ok, em)
      CALL require(ok, 'C1 ('//TRIM(LABEL(iv))//'): the static deck runs with its twist channels: '//TRIM(em))
      IF (.NOT. ok) CYCLE
      CALL read_out('t1e_static.out', 9, rows, nrow)
      CALL require(nrow == 1, 'C1: one static row')
      IF (nrow < 1) CYCLE
      e_t = MAX(ABS(rows(2, 1) - t_ref), ABS(rows(9, 1) - t_ref))/t_ref
      e_tw = MAX(ABS(rows(8, 1) - tw_ref), ABS(rows(7, 1) - tw_ref), ABS(rows(6, 1) - 0.5_wp*tw_ref))/ABS(tw_ref)
      e_m = nan_max_abs(rows(3:5, 1))
      WRITE (*, '(A,A,A,F12.5,A,F12.5,A,ES14.7,A,ES14.7,A,3ES10.2)') 'C1 ', TRIM(LABEL(iv)), ': Twist1 ', &
        rows(8, 1), ' deg (expected ', tw_ref, '), FairTen1 ', rows(2, 1), ' N (expected ', t_ref, &
        '); errors twist, tension, |torque| ', e_tw, e_t, e_m
      CALL require(e_tw <= 1.0e-6_wp, 'C1 ('//TRIM(LABEL(iv))//'): the stretch twists the free line by -(K/GJ) dl')
      CALL require(e_t <= 1.0e-6_wp, 'C1 ('//TRIM(LABEL(iv))//'): the tension is (EA - K^2/GJ) eps')
      CALL require(e_m <= 1.0e-6_wp, 'C1 ('//TRIM(LABEL(iv))//'): no static torque')
    END DO
  END SUBROUTINE check_deck_statics

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE stretch_motion(path)
    !! End A held at its place, moved by -DX s(t) along x (s a C2 quintic over 20 s), then held.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, PARAMETER :: NSTEP = 500
    REAL(wp), PARAMETER :: TR = 20.0_wp, DTM = 0.05_wp, DX = 0.1_wp
    REAL(wp) :: t, tau, s, sd, sdd
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az'
    DO k = 0, NSTEP
      t = DTM*REAL(k, wp)
      tau = MIN(t/TR, 1.0_wp)
      s = 10.0_wp*tau**3 - 15.0_wp*tau**4 + 6.0_wp*tau**5
      sd = (30.0_wp*tau**2 - 60.0_wp*tau**3 + 30.0_wp*tau**4)/TR
      sdd = (60.0_wp*tau - 180.0_wp*tau**2 + 120.0_wp*tau**3)/TR**2
      IF (t > TR) THEN
        sd = 0.0_wp
        sdd = 0.0_wp
      END IF
      WRITE (u, '(ES16.8,A,ES16.8,A,ES16.8,A,ES16.8,A)') t, ' 1 ', -DX*s, ' 0.0 -50.0 ', -DX*sd, ' 0 0 ', -DX*sdd, &
        ' 0 0'
    END DO
    CLOSE (u)
  END SUBROUTINE stretch_motion

  SUBROUTINE check_deck_stretch()
    !! C2: the free end turns with the stretch at every step of the march.
    REAL(wp), PARAMETER :: TR = 20.0_wp, DX = 0.1_wp
    CHARACTER(48) :: conns(2, 2)
    CHARACTER(24), PARAMETER :: LABEL(2) = [CHARACTER(24) :: 'End A free', 'End B free']
    REAL(wp), ALLOCATABLE :: rows(:, :)
    REAL(wp) :: tau, s, dl, e_tw, e_t
    INTEGER :: iv, k, nrow
    LOGICAL :: ok
    CHARACTER(512) :: em
    conns(:, 1) = [CHARACTER(48) :: '1 A Rigid 1 0 0 Free 0 0 1', '1 B Rigid 1 0 0 Rigid 0 0 1 0']
    conns(:, 2) = [CHARACTER(48) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1']
    CALL stretch_motion('t1e_stretch.txt')
    DO iv = 1, 2
      CALL write_deck('t1e_stretch.dat', type_row('5.0e4|4.0e5', 1.0e-9_wp), conns(:, iv), L0_D, &
                      [CHARACTER(32) :: '0.05 dtM', '25.0 TMax', 't1e_stretch.txt motionFile'], &
                      [CHARACTER(16) :: 'FairTen1', 'Twist1'])
      CALL run_deck('t1e_stretch.dat', 't1e_stretch', ok, em)
      CALL require(ok, 'C2 ('//TRIM(LABEL(iv))//'): the stretching march runs: '//TRIM(em))
      IF (.NOT. ok) CYCLE
      CALL read_out('t1e_stretch.out', 3, rows, nrow)
      CALL require(nrow == 501, 'C2: one row per step')
      e_tw = 0.0_wp
      e_t = 0.0_wp
      DO k = 1, nrow
        tau = MIN(rows(1, k)/TR, 1.0_wp)
        s = 10.0_wp*tau**3 - 15.0_wp*tau**4 + 6.0_wp*tau**5
        dl = SPAN + DX*s - L0_D
        e_tw = MAX(e_tw, ABS(rows(3, k) + (K_D/GJ_D)*dl/DEG)/((K_D/GJ_D)*dl/DEG))
        e_t = MAX(e_t, ABS(rows(2, k) - (EA_D - K_D**2/GJ_D)*dl/L0_D)/((EA_D - K_D**2/GJ_D)*dl/L0_D))
      END DO
      WRITE (*, '(A,A,A,F12.5,A,F12.5,A,2ES10.2)') 'C2 ', TRIM(LABEL(iv)), ': Twist1 from ', rows(3, 1), &
        ' to ', rows(3, nrow), ' deg; largest errors twist, tension ', e_tw, e_t
      CALL require(e_tw <= 1.0e-6_wp, 'C2 ('//TRIM(LABEL(iv))//'): the free end turns with the stretch at every step')
      ! (the axial inertia of the ramp, about 3e-5 of the tension, included)
      CALL require(e_t <= 1.0e-4_wp, 'C2 ('//TRIM(LABEL(iv))//'): the tension is (EA - K^2/GJ) eps(t)')
    END DO
  END SUBROUTINE check_deck_stretch

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE inertia_expect(amp, kw, len, ne_d, tw_amp, mt_a, mt_b)
    !! The continuum's response at Omega to a roll amp sin(Omega t) of the restrained End A of a
    !! line free at End B, theta(s) = amp cos(k (L - s))/cos(kL) (s from End A): the twist of End
    !! B relative to End A, and GJ times the mean twist rate over the End A and End B elements
    !! (an end node's torque is its element's).
    REAL(wp), INTENT(IN) :: amp, kw, len
    INTEGER, INTENT(IN) :: ne_d
    REAL(wp), INTENT(OUT) :: tw_amp, mt_a, mt_b
    REAL(wp) :: h
    h = len/REAL(ne_d, wp)
    tw_amp = amp*(1.0_wp/COS(kw*len) - 1.0_wp)
    mt_a = GJ_D*amp*(COS(kw*(len - h)) - COS(kw*len))/(h*COS(kw*len))
    mt_b = GJ_D*amp*(1.0_wp - COS(kw*h))/(h*COS(kw*len))
  END SUBROUTINE inertia_expect

  SUBROUTINE check_deck_inertia()
    !! D: the motionFile roll of the restrained End A spins the line, whose free End B follows.
    REAL(wp), PARAMETER :: IRN_D = 1.0_wp, AMP = 0.1_wp
    INTEGER, PARAMETER :: NPP = 120, NPER_RAMP = 8, NPER_MEAS = 4
    REAL(wp), ALLOCATABLE :: rows(:, :)
    REAL(wp) :: c, om, dt, t, kw, tw_ref, ma_ref, mb_ref, proj(3), e(3)
    INTEGER :: u, k, nrow, k0, nstep
    LOGICAL :: ok
    CHARACTER(512) :: em
    CHARACTER(64) :: opt(3)
    c = SQRT(GJ_D/IRN_D)
    om = 0.25_wp*0.5_wp*PI*c/SPAN
    dt = 2.0_wp*PI/om/REAL(NPP, wp)
    nstep = (NPER_RAMP + 1 + NPER_MEAS)*NPP
    OPEN (NEWUNIT=u, FILE='t1e_roll.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az roll'
    DO k = 0, nstep
      t = dt*REAL(k, wp)
      WRITE (u, '(ES24.16,A,ES24.16)') t, ' 1 0.0 0.0 -50.0 0 0 0 0 0 0 ', &
        AMP*ramp(t, REAL(NPER_RAMP, wp)*2.0_wp*PI/om)*SIN(om*t)/DEG
    END DO
    CLOSE (u)
    WRITE (opt(1), '(ES24.16,A)') dt, ' dtM'
    WRITE (opt(2), '(ES24.16,A)') dt*REAL(nstep, wp), ' TMax'
    opt(3) = 't1e_roll.txt motionFile'
    CALL write_deck('t1e_roll.dat', type_row('5.0e4', IRN_D), &
                    [CHARACTER(48) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1'], SPAN, opt, &
                    [CHARACTER(16) :: 'Twist1', 'Torq1N1', 'Torq1N41'])
    CALL run_deck('t1e_roll.dat', 't1e_roll', ok, em)
    CALL require(ok, 'D: the rolling march runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_out('t1e_roll.out', 4, rows, nrow)
    CALL require(nrow == nstep + 1, 'D: one row per step')
    IF (nrow /= nstep + 1) RETURN
    k0 = (NPER_RAMP + 1)*NPP + 1
    proj = 0.0_wp
    DO k = k0 + 1, nrow
      proj = proj + rows(2:4, k)*SIN(om*rows(1, k))
    END DO
    proj = 2.0_wp*proj/REAL(NPER_MEAS*NPP, wp)
    kw = om/c
    CALL inertia_expect(AMP, kw, SPAN, 40, tw_ref, ma_ref, mb_ref)
    ! Twist1 in degrees
    e(1) = proj(1)*DEG/tw_ref - 1.0_wp
    e(2) = proj(2)/ma_ref - 1.0_wp
    e(3) = proj(3)/mb_ref - 1.0_wp
    WRITE (*, '(A,3ES13.5,A,3ES13.5,A,3ES10.2)') 'D roll of the restrained End A (kL = pi/8): Twist1, Torq1N1, '// &
      'Torq1N41 at Omega ', proj(1)*DEG, proj(2:3), ' continuum ', tw_ref, ma_ref, mb_ref, ' errors ', e
    CALL require(ABS(e(1)) <= 1.0e-2_wp, 'D: the free End B follows the roll with the continuum''s twist')
    CALL require(ABS(e(2)) <= 1.0e-2_wp, 'D: the restrained End A carries the continuum''s inertial torque')
    CALL require(ABS(e(3)) <= 3.0e-2_wp, 'D: the free End B''s element carries the continuum''s small torque')
  END SUBROUTINE check_deck_inertia

  ! ------------------------------------------------------------------------------------------
  FUNCTION roll_dcm(phi) RESULT(r)
    !! OpenFAST mesh orientation (global to local) of a roll phi about +x.
    REAL(wp), INTENT(IN) :: phi
    REAL(wp) :: r(3, 3)
    r = 0.0_wp
    r(1, 1) = 1.0_wp
    r(2, 2) = COS(phi)
    r(2, 3) = SIN(phi)
    r(3, 2) = -SIN(phi)
    r(3, 3) = COS(phi)
  END FUNCTION roll_dcm

  SUBROUTINE check_aggregate()
    !! A: the coupled aggregate, End A on the platform (host orientation).
    REAL(wp), PARAMETER :: IRN_D = 1.0_wp, AMP = 0.1_wp, DT_A = 0.05_wp, RATE = 60.0_wp*PI/180.0_wp
    INTEGER, PARAMETER :: NPP = 120, NPER_RAMP = 8, NPER_MEAS = 4
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1), moment(3, 1), orient(3, 3, 1), omega(3, 1)
    REAL(wp) :: alpha(3, 1), tw0, tw, ta, tb, werr, merr, c, om, dt, t, ang, kw, tw_ref, ma_ref, mb_ref, proj(3), e(3)
    REAL(wp) :: s, sd, sdd, tr
    INTEGER :: es, ni, k, k0, nstep
    LOGICAL :: cv, st, ok
    CHARACTER(512) :: em
    ! A1: the C1 line free at End A, the platform rolling at 60 deg/s
    CALL write_deck('t1e_agg1.dat', type_row('5.0e4|4.0e5', 1.0e-9_wp), &
                    [CHARACTER(48) :: '1 A Rigid 1 0 0 Free 0 0 1', '1 B Rigid 1 0 0 Rigid 0 0 1 0'], L0_D, &
                    [CHARACTER(16) :: '0.05 dtM'], [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1'])
    CALL CD_AGG_Init_From_Deck(agg, 't1e_agg1.dat', DT_A, es, em, host_orientation=.TRUE.)
    ok = es == CD_AGG_OK
    CALL require(ok, 'A1: the line free at End A builds on the aggregate: '//TRIM(em))
    IF (ok) THEN
      CALL agg_channels(agg, ta, tb, tw0)
      CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient)
      omega = 0.0_wp
      alpha = 0.0_wp
      omega(1, 1) = RATE
      werr = 0.0_wp
      merr = 0.0_wp
      DO k = 1, 10
        orient(:, :, 1) = roll_dcm(RATE*DT_A*k)
        CALL CD_AGG_Step_Moving(agg, DT_A, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                                angular_velocity=omega, angular_acceleration=alpha)
        CALL require(es == CD_AGG_OK .AND. cv, 'A1: the rolling step converges: '//TRIM(em))
        IF (es /= CD_AGG_OK) EXIT
        CALL CD_AGG_CalcOutput(agg, es, em)
        CALL agg_channels(agg, ta, tb, tw)
        CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, moment=moment)
        werr = MAX(werr, ABS(tw - tw0))
        merr = MAX(merr, ABS(ta), ABS(tb), ABS(moment(1, 1)))
        IF (k == 10) WRITE (*, '(A,3ES12.4)') '  A1 last step: Torq1N1, Torq1N41, axial moment ', ta, tb, moment(1, 1)
      END DO
      WRITE (*, '(A,F12.5,A,ES10.2,A,ES10.2,A)') 'A1 aggregate, End A free, platform roll 30 deg: Twist1 ', tw0, &
        ' deg, change ', werr, ' deg; torques and axial fairlead moment ', merr, ' N m'
      CALL require(ABS(tw0 + (K_D/GJ_D)*(SPAN - L0_D)/DEG) <= 1.0e-6_wp*ABS(tw0), &
                   'A1: the static coupling twist on the aggregate')
      CALL require(werr <= 1.0e-6_wp, 'A1: the platform roll does not twist a line free at End A')
      ! (against the torque GJ phi/L the roll would put into a line restrained at both ends)
      CALL require(merr <= 1.0e-6_wp*GJ_D*RATE*DT_A*10.0_wp/SPAN, 'A1: no torque, and no axial moment on the platform')
      CALL CD_AGG_End(agg, es, em)
    END IF
    ! A2: the D line restrained at End A, rolled by the platform
    c = SQRT(GJ_D/IRN_D)
    om = 0.25_wp*0.5_wp*PI*c/SPAN
    dt = 2.0_wp*PI/om/REAL(NPP, wp)
    tr = REAL(NPER_RAMP, wp)*2.0_wp*PI/om
    CALL write_deck('t1e_agg2.dat', type_row('5.0e4', IRN_D), &
                    [CHARACTER(48) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1'], SPAN, &
                    [CHARACTER(16) :: '0.05 dtM'], [CHARACTER(16) :: 'Torq1N1', 'Torq1N41', 'Twist1'])
    CALL CD_AGG_Init_From_Deck(agg, 't1e_agg2.dat', dt, es, em, host_orientation=.TRUE.)
    ok = es == CD_AGG_OK
    CALL require(ok, 'A2: the line free at End B builds on the aggregate: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em, orientation=orient)
    nstep = (NPER_RAMP + 1 + NPER_MEAS)*NPP
    k0 = (NPER_RAMP + 1)*NPP
    proj = 0.0_wp
    DO k = 1, nstep
      t = dt*REAL(k, wp)
      ! the roll AMP s(t) sin(Omega t) with its rate and acceleration (s the quintic ramp)
      CALL ramp_derivs(t, tr, s, sd, sdd)
      ang = AMP*s*SIN(om*t)
      orient(:, :, 1) = roll_dcm(ang)
      omega = 0.0_wp
      alpha = 0.0_wp
      omega(1, 1) = AMP*(sd*SIN(om*t) + s*om*COS(om*t))
      alpha(1, 1) = AMP*(sdd*SIN(om*t) + 2.0_wp*sd*om*COS(om*t) - s*om*om*SIN(om*t))
      CALL CD_AGG_Step_Moving(agg, dt, pos, vel, acc, cv, st, ni, es, em, orientation=orient, &
                              angular_velocity=omega, angular_acceleration=alpha)
      CALL require(es == CD_AGG_OK .AND. cv, 'A2: the rolling step converges: '//TRIM(em))
      IF (es /= CD_AGG_OK) EXIT
      IF (k > k0) THEN
        CALL CD_AGG_CalcOutput(agg, es, em)
        CALL agg_channels(agg, ta, tb, tw)
        proj = proj + [tw, ta, tb]*SIN(om*t)
      END IF
    END DO
    IF (es == CD_AGG_OK) THEN
      proj = 2.0_wp*proj/REAL(NPER_MEAS*NPP, wp)
      kw = om/c
      CALL inertia_expect(AMP, kw, SPAN, 40, tw_ref, ma_ref, mb_ref)
      e(1) = proj(1)*DEG/tw_ref - 1.0_wp
      e(2) = proj(2)/ma_ref - 1.0_wp
      e(3) = proj(3)/mb_ref - 1.0_wp
      WRITE (*, '(A,3ES13.5,A,3ES10.2)') 'A2 aggregate, platform roll of the restrained End A: Twist1, Torq1N1, '// &
        'Torq1N41 at Omega ', proj(1)*DEG, proj(2:3), ' errors against the continuum ', e
      CALL require(ABS(e(1)) <= 1.0e-2_wp, 'A2: the free End B follows the platform roll')
      CALL require(ABS(e(2)) <= 1.0e-2_wp, 'A2: the fairlead End A carries the continuum''s inertial torque')
      CALL require(ABS(e(3)) <= 3.0e-2_wp, 'A2: the free End B''s element carries the continuum''s small torque')
    END IF
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_aggregate

  SUBROUTINE ramp_derivs(t, tr, s, sd, sdd)
    !! The quintic ramp of ramp() and its first two time derivatives.
    REAL(wp), INTENT(IN) :: t, tr
    REAL(wp), INTENT(OUT) :: s, sd, sdd
    REAL(wp) :: x
    x = MIN(MAX(t/tr, 0.0_wp), 1.0_wp)
    s = x**3*(10.0_wp - 15.0_wp*x + 6.0_wp*x**2)
    sd = 0.0_wp
    sdd = 0.0_wp
    IF (t < tr) THEN
      sd = 30.0_wp*x**2*(1.0_wp - x)**2/tr
      sdd = 60.0_wp*x*(1.0_wp - x)*(1.0_wp - 2.0_wp*x)/tr**2
    END IF
  END SUBROUTINE ramp_derivs

  SUBROUTINE agg_channels(agg, torq_a, torq_b, twist)
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    REAL(wp), INTENT(OUT) :: torq_a, torq_b, twist
    INTEGER :: es
    CHARACTER(256) :: em
    CALL CD_AGG_EvalChannel(agg, 1, torq_a, es, em)
    CALL require(es == CD_AGG_OK, 'Torq1N1 evaluates: '//TRIM(em))
    CALL CD_AGG_EvalChannel(agg, 2, torq_b, es, em)
    CALL require(es == CD_AGG_OK, 'Torq1N41 evaluates: '//TRIM(em))
    CALL CD_AGG_EvalChannel(agg, 3, twist, es, em)
    CALL require(es == CD_AGG_OK, 'Twist1 evaluates: '//TRIM(em))
  END SUBROUTINE agg_channels

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_not_solved()
    !! N: a 10-column LINE TYPES row (no GJ) with one restrained end: the twist channel is refused
    !! with the reason, and without it the deck runs as before.
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_deck('t1e_n.dat', 'cab 0.2 60.0 1.0e9 0.0 1.0e5 0.0 0.0 0.0 0.0', &
                    [CHARACTER(48) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1'], L0_D, &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], [CHARACTER(16) :: 'FairTen1', 'Twist1'], &
                    ten_cols=.TRUE.)
    CALL run_deck('t1e_n.dat', 't1e_n', ok, em)
    CALL require(.NOT. ok .AND. INDEX(em, 'restrained at one end only and its torsion is not solved') > 0 .AND. &
                 INDEX(em, 'give no GJ') > 0, 'N: the twist channel of a line not solved in torsion is refused '// &
                 'with the reason (got: '//TRIM(em)//')')
    CALL write_deck('t1e_n.dat', 'cab 0.2 60.0 1.0e9 0.0 1.0e5 0.0 0.0 0.0 0.0', &
                    [CHARACTER(48) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1'], L0_D, &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], [CHARACTER(16) :: 'FairTen1'], ten_cols=.TRUE.)
    CALL run_deck('t1e_n.dat', 't1e_n', ok, em)
    CALL require(ok, 'N: without the twist channel the deck runs: '//TRIM(em))
    ! a solved line's imposed twist, its restrained end's Pretwist, is held within 1000 turns
    CALL write_deck('t1e_n2.dat', type_row('5.0e4', 1.0_wp), &
                    [CHARACTER(48) :: '1 A Rigid 1 0 0 Free 0 0 1 0', '1 B Rigid 1 0 0 Rigid 0 0 1 4.0e5'], L0_D, &
                    [CHARACTER(16) :: '0.1 dtM', '0.0 TMax'], [CHARACTER(16) :: 'Twist1'])
    CALL run_deck('t1e_n2.dat', 't1e_n2', ok, em)
    CALL require(.NOT. ok .AND. INDEX(em, 'the Pretwist of its restrained End B = 4.00000E+05 deg exceeds 1000 '// &
                                      'turns') > 0, 'N: a restrained Pretwist beyond 1000 turns is named (got: '// &
                 TRIM(em)//')')
  END SUBROUTINE check_not_solved

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_attachments_statics()
    !! T1: the static coupling twist of a vertical line free at one end carrying attachments.
    INTEGER, PARAMETER :: NE_D = 40, NATT = 3, NODE(NATT) = [11, 21, 31]
    REAL(wp), PARAMETER :: MASS(NATT) = [2000.0_wp, 100.0_wp, 800.0_wp], VOL(NATT) = [0.5_wp, 1.0_wp, 0.2_wp]
    CHARACTER(16), PARAMETER :: OUTS(7) = [CHARACTER(16) :: 'FairTen1', 'AnchTen1', 'Torq1N1', 'Torq1N41', &
                                                                                     'Twist1N21', 'Twist1', 'Twist1N41']
    CHARACTER(48) :: conns(2, 2), atts(NATT)
    CHARACTER(24), PARAMETER :: LABEL(2) = [CHARACTER(24) :: 'End A free', 'End B free']
    REAL(wp), ALLOCATABLE :: rows(:, :)
    REAL(wp) :: w(NATT), l0, ea_eff, t_a, t_e, tw_ref, tw_mid, tw_mid0, e_tw, e_mid, e_t, e_m
    INTEGER :: iv, k, e, nrow
    LOGICAL :: ok
    CHARACTER(512) :: em
    l0 = L0_D/REAL(NE_D, wp)
    w = (MASS - RHOW*VOL)*9.80665_wp
    DO k = 1, NATT
      WRITE (atts(k), '(A,F12.6,F10.2,F8.3,A)') '1 ', REAL(NODE(k) - 1, wp)*l0, MASS(k), VOL(k), ' 0.0 0.0'
    END DO
    ! the element tensions from End A down, their strains and the twists
    ea_eff = EA_D - K_D**2/GJ_D
    t_a = ea_eff*(SPAN - L0_D)/l0
    DO k = 1, NATT
      t_a = t_a + w(k)*REAL(NE_D + 1 - NODE(k), wp)
    END DO
    t_a = t_a/REAL(NE_D, wp)
    tw_ref = -(K_D/GJ_D)*(SPAN - L0_D)/DEG
    tw_mid = 0.0_wp
    DO e = 1, 20
      t_e = t_a - SUM(w, MASK=NODE <= e)
      tw_mid = tw_mid - (K_D/GJ_D)*l0*t_e/ea_eff
    END DO
    tw_mid = tw_mid/DEG
    tw_mid0 = 0.5_wp*tw_ref
    conns(:, 1) = [CHARACTER(48) :: '1 A Rigid 0 0 -1 Free 1 0 0', '1 B Rigid 0 0 -1 Rigid 1 0 0 30']
    conns(:, 2) = [CHARACTER(48) :: '1 A Rigid 0 0 -1 Rigid 1 0 0 -30', '1 B Rigid 0 0 -1 Free 1 0 0']
    DO iv = 1, 2
      CALL write_deck('t1e_att.dat', type_row('5.0e4|4.0e5', 1.0e-9_wp), conns(:, iv), L0_D, &
                      [CHARACTER(16) :: '200.0 WtrDpth', '0.1 dtM', '0.0 TMax'], OUTS, atts=atts, &
                      end_b=[0.0_wp, 0.0_wp, -50.0_wp - SPAN])
      CALL run_deck('t1e_att.dat', 't1e_att', ok, em)
      CALL require(ok, 'T1 ('//TRIM(LABEL(iv))//'): the deck with attachments runs with its twist channels: '//TRIM(em))
      IF (.NOT. ok) CYCLE
      CALL read_out('t1e_att.out', 8, rows, nrow)
      CALL require(nrow == 1, 'T1: one static row')
      IF (nrow < 1) CYCLE
      e_tw = MAX(ABS(rows(7, 1) - tw_ref), ABS(rows(8, 1) - tw_ref))/ABS(tw_ref)
      e_mid = ABS(rows(6, 1) - tw_mid)/ABS(tw_mid)
      e_t = MAX(ABS(rows(2, 1) - t_a), ABS(rows(3, 1) - (t_a - SUM(w))))/t_a
      e_m = nan_max_abs(rows(4:5, 1))
      WRITE (*, '(A,A,A,F12.5,A,F12.5,A,F12.5,A,F12.5,A,F12.5,A,4ES10.2)') 'T1 ', TRIM(LABEL(iv)), ': Twist1 ', &
        rows(7, 1), ' deg (expected ', tw_ref, '), Twist1N21 ', rows(6, 1), ' (expected ', tw_mid, &
        '; uniform strain ', tw_mid0, '); errors twist, mid twist, tensions, |torque| ', e_tw, e_mid, e_t, e_m
      CALL require(e_tw <= 1.0e-6_wp, 'T1 ('//TRIM(LABEL(iv))//'): the free end turns by -(K/GJ) dl with the modules')
      CALL require(e_mid <= 1.0e-3_wp, 'T1 ('//TRIM(LABEL(iv))//'): the mid-line twist follows the module tensions')
      CALL require(e_t <= 1.0e-6_wp, 'T1 ('//TRIM(LABEL(iv))//'): the end tensions carry the module weights')
      CALL require(e_m <= 1.0e-6_wp, 'T1 ('//TRIM(LABEL(iv))//'): no static torque')
    END DO
  END SUBROUTINE check_attachments_statics

  SUBROUTINE check_attachments_inertia()
    !! T2: the D roll of the restrained End A with three neutral modules (mass rhoW V, no drag), the
    !! line taut (an attachment polish of the slack-free D line does not converge, with or without
    !! torsion).
    REAL(wp), PARAMETER :: IRN_D = 1.0_wp, AMP = 0.1_wp, LEN_T = 99.9_wp
    INTEGER, PARAMETER :: NPP = 120, NPER_RAMP = 8, NPER_MEAS = 4
    REAL(wp), ALLOCATABLE :: rows(:, :)
    REAL(wp) :: c, om, dt, t, kw, tw_ref, ma_ref, mb_ref, proj(3), e(3)
    INTEGER :: u, k, nrow, k0, nstep
    LOGICAL :: ok
    CHARACTER(512) :: em
    CHARACTER(64) :: opt(3)
    c = SQRT(GJ_D/IRN_D)
    om = 0.25_wp*0.5_wp*PI*c/SPAN
    dt = 2.0_wp*PI/om/REAL(NPP, wp)
    nstep = (NPER_RAMP + 1 + NPER_MEAS)*NPP
    OPEN (NEWUNIT=u, FILE='t1e_att_roll.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az roll'
    DO k = 0, nstep
      t = dt*REAL(k, wp)
      WRITE (u, '(ES24.16,A,ES24.16)') t, ' 1 0.0 0.0 -50.0 0 0 0 0 0 0 ', &
        AMP*ramp(t, REAL(NPER_RAMP, wp)*2.0_wp*PI/om)*SIN(om*t)/DEG
    END DO
    CLOSE (u)
    WRITE (opt(1), '(ES24.16,A)') dt, ' dtM'
    WRITE (opt(2), '(ES24.16,A)') dt*REAL(nstep, wp), ' TMax'
    opt(3) = 't1e_att_roll.txt motionFile'
    CALL write_deck('t1e_att_roll.dat', type_row('5.0e4', IRN_D), &
                    [CHARACTER(48) :: '1 A Rigid 1 0 0 Rigid 0 0 1 0', '1 B Rigid 1 0 0 Free 0 0 1'], LEN_T, opt, &
                    [CHARACTER(16) :: 'Twist1', 'Torq1N1', 'Torq1N41'], &
                    atts=[CHARACTER(48) :: '1 25.0 512.5 0.5 0.0 0.0', '1 50.0 1025.0 1.0 0.0 0.0', &
                          '1 75.0 205.0 0.2 0.0 0.0'])
    CALL run_deck('t1e_att_roll.dat', 't1e_att_roll', ok, em)
    CALL require(ok, 'T2: the rolling march with neutral modules runs: '//TRIM(em))
    IF (.NOT. ok) RETURN
    CALL read_out('t1e_att_roll.out', 4, rows, nrow)
    CALL require(nrow == nstep + 1, 'T2: one row per step')
    IF (nrow /= nstep + 1) RETURN
    k0 = (NPER_RAMP + 1)*NPP + 1
    proj = 0.0_wp
    DO k = k0 + 1, nrow
      proj = proj + rows(2:4, k)*SIN(om*rows(1, k))
    END DO
    proj = 2.0_wp*proj/REAL(NPER_MEAS*NPP, wp)
    kw = om/c
    CALL inertia_expect(AMP, kw, LEN_T, 40, tw_ref, ma_ref, mb_ref)
    e(1) = proj(1)*DEG/tw_ref - 1.0_wp
    e(2) = proj(2)/ma_ref - 1.0_wp
    e(3) = proj(3)/mb_ref - 1.0_wp
    WRITE (*, '(A,3ES13.5,A,3ES13.5,A,3ES10.2)') 'T2 roll with neutral modules (kL = pi/8): Twist1, Torq1N1, '// &
      'Torq1N41 at Omega ', proj(1)*DEG, proj(2:3), ' continuum ', tw_ref, ma_ref, mb_ref, ' errors ', e
    CALL require(ABS(e(1)) <= 1.0e-2_wp, 'T2: the free End B follows the roll with the continuum''s twist')
    CALL require(ABS(e(2)) <= 1.0e-2_wp, 'T2: the restrained End A carries the continuum''s inertial torque')
    CALL require(ABS(e(3)) <= 3.0e-2_wp, 'T2: the free End B''s element carries the continuum''s small torque')
  END SUBROUTINE check_attachments_inertia

  ELEMENTAL INTEGER(8) FUNCTION bits(x)
    REAL(wp), INTENT(IN) :: x
    bits = TRANSFER(x, 0_8)
  END FUNCTION bits

END PROGRAM test_torsion_one_end
