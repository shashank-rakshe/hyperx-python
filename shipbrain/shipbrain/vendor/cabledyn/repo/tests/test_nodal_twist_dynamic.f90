! File: tests/test_nodal_twist_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_nodal_twist_dynamic
  !! Gates of the nodal twist (a twist angle at every node, with the polar rotary inertia Irn)
  !! on the cubic-Hermite cable, a 10 m line restrained in torsion at both ends:
  !!   Q  quasi-static limit: with a negligible Irn the nodal twist reproduces the condensed
  !!      torsion on a bowed line that sways, rolls through more than a turn at its coupled end
  !!      and takes an imposed twist: the centreline, the mean and nodal torques, the coupled
  !!      end force and moment agree, for clamped ends, bending-pinned ends (the end tangent
  !!      moves off the end director) and elastic torsional ends;
  !!   W  torsional waves: a straight line, clamped and rigid in torsion at both ends, driven in
  !!      roll at one end below its first torsional mode, carries at the other end the torque of
  !!      the continuum, GJ A k / sin(kL) with k = Omega sqrt(Irn/GJ); at kL = pi/2 the driven end's
  !!      reaction moment is zero, GJ A k cot(kL), its held section's polar inertia included,
  !!      for a roll of the parent and for an imposed twist;
  !!   D  torsional damping: the first torsional mode rings down at zeta_1 = omega_1 Bt/(2 GJ);
  !!      a parent rolling its end frame at a steady rate Omega (negligible Irn) loads the held
  !!      end with (GJ theta + Bt Omega)/L, the damping of the frame's own turn included;
  !!   E  energy: free vibration of a bowed, twisted line with a real Irn (rho_inf = 1): kinetic
  !!      (with the polar part) + elastic (with the twist) stays within the band of the line
  !!      without torsion; a parent rolling the clamped line's end frame at a steady rate puts
  !!      the continuum's polar kinetic energy into it, the held end section's spin included;
  !!      a line pinned in bending and rigid in torsion at both ends, twisted and swinging (13 deg
  !!      end bend angle): the spin c = (t x d).dt/dt / (1 + d.t) of the end section that the
  !!      carry G(d -> t) adds as the end tangent t moves, which the model leaves out of the
  !!      kinetic energy, the line's equations and the reaction alike (theory, Nodal twist),
  !!      carries at most 4e-6 of the peak kinetic energy with an extreme Irn = 1 kg m (6e-8 at
  !!      0.02 kg m), below the step's own energy band;
  !!   R  restart: a rolling, torsionally damped run restored from a snapshot, and one rebuilt
  !!      from the checkpoint mirror, continue bit-identically.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Line, CD_HermiteTorsion_Unwrap, &
                                     CD_HTORS_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Energy, &
                                          CD_HermiteCable_Dyn_End, CD_HermiteCable_Dyn_Set_EndConnection, &
                                          CD_HermiteCable_Dyn_Set_Torsion, CD_HermiteCable_Dyn_Torsion_State, &
                                          CD_HermiteCable_Dyn_Node_Torque, CD_HCDYN_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_Init, CD_HFMF_Set_EndConnection, &
                                          CD_HFMF_Set_Torsion, CD_HFMF_UpdateStates, CD_HFMF_CalcOutput, &
                                          CD_HFMF_Snapshot, CD_HFMF_Restore, CD_HFMF_MirrorSize, &
                                          CD_HFMF_PackMirror, CD_HFMF_UnpackMirror, CD_HFMF_End, CD_HFMF_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: LL = 10.0_wp, EA = 1.0e5_wp, EI = 100.0_wp, GJ = 80.0_wp, RHOA = 1.0_wp
  INTEGER, PARAMETER :: NE = 20, NN = NE + 1, NDOF = 6*NN
  INTEGER :: nfail = 0

  CALL check_quasi_static('clamped', .FALSE., 0.0_wp)
  CALL check_quasi_static('bending-pinned', .TRUE., 0.0_wp)
  CALL check_quasi_static('elastic', .FALSE., 0.05_wp)
  CALL check_waves()
  CALL check_driven_end('parent roll')
  CALL check_driven_end('imposed twist')
  CALL check_damping()
  CALL check_frame_damping()
  CALL check_energy()
  CALL check_frame_energy()
  CALL check_pinned_energy()
  CALL check_restart()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: nodal twist gates'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: '//TRIM(label)
  END SUBROUTINE require

  FUNCTION roll_x(psi) RESULT(r)
    !! Global-to-parent DCM of a parent rolled by psi about +x (the transpose of the rotation).
    REAL(wp), INTENT(IN) :: psi
    REAL(wp) :: r(3, 3)
    r = 0.0_wp
    r(1, 1) = 1.0_wp
    r(2, 2) = COS(psi)
    r(3, 3) = COS(psi)
    r(2, 3) = SIN(psi)
    r(3, 2) = -SIN(psi)
  END FUNCTION roll_x

  SUBROUTINE line_seed(bow_y, bow_z, q)
    !! Straight line along +x (node 1 at the origin), optionally bowed by y = bow_y sin^2(pi s/L),
    !! z = bow_z sin^2(2 pi s/L) (end tangents stay along +x, as the clamps require).
    REAL(wp), INTENT(IN) :: bow_y, bow_z
    REAL(wp), INTENT(OUT) :: q(NDOF)
    INTEGER :: k
    REAL(wp) :: s
    q = 0.0_wp
    DO k = 1, NN
      s = LL*REAL(k - 1, wp)/REAL(NE, wp)
      q(6*k - 5) = s
      q(6*k - 4) = bow_y*SIN(PI*s/LL)**2
      q(6*k - 3) = bow_z*SIN(2.0_wp*PI*s/LL)**2
      q(6*k - 2) = 1.0_wp
      q(6*k - 1) = bow_y*(PI/LL)*SIN(2.0_wp*PI*s/LL)
      q(6*k) = bow_z*(2.0_wp*PI/LL)*SIN(4.0_wp*PI*s/LL)
    END DO
  END SUBROUTINE line_seed

  SUBROUTINE torsion_of(q, phi, tors, irn, compliance, bt)
    !! Torsion of the line: both ends along +x with reference normal +z, GJ on every element,
    !! imposed twist phi, Theta of the seed q (branch nearest 0); irn > 0 adds the polar inertia
    !! (nodal twist), compliance the torsional end compliances, bt the torsional damping.
    REAL(wp), INTENT(IN) :: q(NDOF), phi, irn, compliance
    TYPE(CD_HermiteTorsionType), INTENT(OUT) :: tors
    REAL(wp), INTENT(IN), OPTIONAL :: bt
    REAL(wp) :: g(NDOF), raw, l0(NE)
    INTEGER :: es
    CHARACTER(200) :: em
    l0 = LL/REAL(NE, wp)
    tors%active = .TRUE.
    tors%phi = phi
    tors%ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                         0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    tors%end_compliance = compliance
    ALLOCATE (tors%gj(NE))
    tors%gj = GJ
    IF (irn > 0.0_wp) THEN
      ALLOCATE (tors%irn(NE))
      tors%irn = irn
    END IF
    IF (PRESENT(bt)) THEN
      ALLOCATE (tors%bt(NE))
      tors%bt = bt
    END IF
    CALL CD_HermiteTorsion_Line(q, l0, tors%ends, raw, g, es, em)
    CALL require(es == CD_HTORS_OK, 'seed twist evaluates: '//TRIM(em))
    tors%theta = CD_HermiteTorsion_Unwrap(raw, 0.0_wp)
    tors%has_theta = .TRUE.
  END SUBROUTINE torsion_of

  SUBROUTINE build_cable(cab, q, phi, dt, tol, rho_inf, pinned, irn, compliance, bt)
    !! HFMF cable on seed q: node NN coupled (driven), node 1 held; Rigid bending connections
    !! along +x at both ends (none with pinned), the coupled one in parent axes (identity
    !! attitude); torsion with the coupled end's frame attached to the parent (damping bt).
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cab
    REAL(wp), INTENT(IN) :: q(NDOF), phi, dt, tol, rho_inf, irn, compliance
    LOGICAL, INTENT(IN) :: pinned
    REAL(wp), INTENT(IN), OPTIONAL :: bt
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: l0(NE), eye(3, 3), frame(3, 2)
    INTEGER :: es
    CHARACTER(300) :: em
    l0 = LL/REAL(NE, wp)
    eye = roll_x(0.0_wp)
    CALL CD_HFMF_Init(cab, l0, [(EA, es=1, NE)], [(EI, es=1, NE)], [(RHOA, es=1, NE)], [(0.0_wp, es=1, NE)], q, &
                      [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], 0.0_wp, 0.0_wp, rho_inf, dt, NN, es, em, &
                      max_iter=60, tol=tol)
    CALL require(es == CD_HFMF_OK, 'cable init: '//TRIM(em))
    IF (.NOT. pinned) THEN
      CALL CD_HFMF_Set_EndConnection(cab, [0.0_wp, 0.0_wp], RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                    [3, 2]), es, em, &
                                     coupled_d0_parent=[1.0_wp, 0.0_wp, 0.0_wp], parent_orientation=eye, &
                                     connection_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
      CALL require(es == CD_HFMF_OK, 'cable end connections: '//TRIM(em))
    END IF
    CALL torsion_of(q, phi, tors, irn, compliance, bt)
    frame(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
    frame(:, 2) = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL CD_HFMF_Set_Torsion(cab, tors, es, em, coupled_frame_parent=frame, parent_orientation=eye)
    CALL require(es == CD_HFMF_OK, 'cable torsion: '//TRIM(em))
  END SUBROUTINE build_cable

  SUBROUTINE drive(k, x, v, a, dcm, w, al, phi)
    !! Coupled-end drive: a lateral sway with a roll of the parent about the line axis (3 rad/s,
    !! more than a turn by step 250) and an imposed twist following it.
    INTEGER, INTENT(IN) :: k
    REAL(wp), INTENT(OUT) :: x(3), v(3), a(3), dcm(3, 3), w(3), al(3), phi
    REAL(wp), PARAMETER :: DT = 0.01_wp, AMP = 0.05_wp, OM = 2.0_wp, ROLL_RATE = 3.0_wp
    REAL(wp) :: t
    t = DT*REAL(k, wp)
    x = [LL, AMP*SIN(OM*t), 0.0_wp]
    v = [0.0_wp, AMP*OM*COS(OM*t), 0.0_wp]
    a = [0.0_wp, -AMP*OM*OM*SIN(OM*t), 0.0_wp]
    dcm = roll_x(ROLL_RATE*t)
    w = [ROLL_RATE, 0.0_wp, 0.0_wp]
    al = 0.0_wp
    phi = 1.0_wp - ROLL_RATE*t + 0.5_wp*SIN(OM*t)
  END SUBROUTINE drive

  SUBROUTINE march(cab, k0, k1, ok)
    TYPE(CD_HFMF_ModuleType), INTENT(INOUT) :: cab
    INTEGER, INTENT(IN) :: k0, k1
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp) :: x(3), v(3), a(3), dcm(3, 3), w(3), al(3), phi
    INTEGER :: k, es
    CHARACTER(300) :: em
    ok = .TRUE.
    DO k = k0 + 1, k1
      CALL drive(k, x, v, a, dcm, w, al, phi)
      CALL CD_HFMF_UpdateStates(cab, x, v, a, es, em, u_orientation=dcm, u_angular_velocity=w, &
                                u_angular_acceleration=al, u_twist=phi)
      IF (es /= CD_HFMF_OK) THEN
        WRITE (*, '(A,I0,A)') '  march step ', k, ': '//TRIM(em)
        ok = .FALSE.
        RETURN
      END IF
    END DO
  END SUBROUTINE march

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_quasi_static(label, pinned, compliance)
    !! Q: the nodal twist with Irn = 1e-9 kg m against the condensed torsion on the same run.
    CHARACTER(*), INTENT(IN) :: label
    LOGICAL, INTENT(IN) :: pinned
    REAL(wp), INTENT(IN) :: compliance
    INTEGER, PARAMETER :: NSTEP = 300
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cc, cn
    REAL(wp) :: q(NDOF), x(3), v(3), a(3), dcm(3, 3), w(3), al(3), phi, fc(3), mc(3), fn(3), mn(3)
    REAL(wp) :: err_q, err_t, err_n, err_f, err_m, mref, thc, mtc, thn, mtn, ntq(NN)
    INTEGER :: k, es, esc, esn
    CHARACTER(300) :: em
    ALLOCATE (cc, cn)
    CALL line_seed(0.3_wp, 0.1_wp, q)
    CALL build_cable(cc, q, 1.0_wp, 0.01_wp, 1.0e-10_wp, 0.8_wp, pinned, 0.0_wp, compliance)
    CALL build_cable(cn, q, 1.0_wp, 0.01_wp, 1.0e-10_wp, 0.8_wp, pinned, 1.0e-9_wp, compliance)
    CALL require(cn%line%tw_active .AND. .NOT. cc%line%tw_active, 'Q '//label//': the nodal twist is active')
    err_q = 0.0_wp
    err_t = 0.0_wp
    err_n = 0.0_wp
    err_f = 0.0_wp
    err_m = 0.0_wp
    mref = GJ/LL
    DO k = 1, NSTEP
      CALL drive(k, x, v, a, dcm, w, al, phi)
      CALL CD_HFMF_UpdateStates(cc, x, v, a, esc, em, u_orientation=dcm, u_angular_velocity=w, &
                                u_angular_acceleration=al, u_twist=phi)
      CALL require(esc == CD_HFMF_OK, 'Q '//label//': condensed step: '//TRIM(em))
      CALL CD_HFMF_UpdateStates(cn, x, v, a, esn, em, u_orientation=dcm, u_angular_velocity=w, &
                                u_angular_acceleration=al, u_twist=phi)
      CALL require(esn == CD_HFMF_OK, 'Q '//label//': nodal step: '//TRIM(em))
      IF (esc /= CD_HFMF_OK .OR. esn /= CD_HFMF_OK) EXIT
      err_q = nan_max_abs([err_q, nan_max_abs(cn%line%q - cc%line%q)])
      CALL CD_HermiteCable_Dyn_Torsion_State(cc%line, thc, mtc, es, em)
      CALL CD_HermiteCable_Dyn_Torsion_State(cn%line, thn, mtn, es, em)
      err_t = nan_max_abs([err_t, ABS(mtn - mtc)/mref])
      CALL CD_HermiteCable_Dyn_Node_Torque(cn%line, ntq, es, em)
      err_n = nan_max_abs([err_n, nan_max_abs(ntq - mtc)/mref])
      CALL CD_HFMF_CalcOutput(cc, fc, es, em, y_moment=mc)
      CALL CD_HFMF_CalcOutput(cn, fn, es, em, y_moment=mn)
      err_f = nan_max_abs([err_f, NORM2(fn - fc)/MAX(1.0_wp, NORM2(fc))])
      err_m = nan_max_abs([err_m, NORM2(mn - mc)/MAX(mref, NORM2(mc))])
    END DO
    WRITE (*, '(A,A,A,5ES10.2)') 'Q quasi-static limit (', label, '): q, torque, node torque, end force, '// &
      'end moment ', err_q, err_t, err_n, err_f, err_m
    CALL require(err_q <= 1.0e-7_wp, 'Q '//label//': the centreline follows the condensed torsion')
    CALL require(err_t <= 1.0e-6_wp, 'Q '//label//': the mean torque is the condensed torque')
    CALL require(err_n <= 1.0e-6_wp, 'Q '//label//': every node carries the condensed torque')
    CALL require(err_f <= 1.0e-6_wp, 'Q '//label//': the coupled end force agrees')
    CALL require(err_m <= 1.0e-6_wp, 'Q '//label//': the coupled end moment agrees')
    CALL CD_HFMF_End(cc)
    CALL CD_HFMF_End(cn)
  END SUBROUTINE check_quasi_static

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_waves()
    !! W: a roll A sin(Omega t) of the coupled end (amplitude ramped in over the first eight
    !! periods) below the first torsional mode of the clamped line, Irn = 0.5 kg m; after the
    !! ramp the held end's torque swings with the continuum's amplitude GJ A k / sin(kL).
    REAL(wp), PARAMETER :: IRN = 0.5_wp, AMPR = 0.2_wp
    INTEGER, PARAMETER :: NPER_RAMP = 8, NPER = 14, NPP = 200
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab
    REAL(wp) :: q(NDOF), c, om1, om, dt, t, env, ang, x(3), kw, ntq(NN), tmax, tmin, expect, ramp_t
    INTEGER :: k, es, nstep
    CHARACTER(300) :: em
    ALLOCATE (cab)
    c = SQRT(GJ/IRN)
    om1 = PI*c/LL
    om = 0.5_wp*om1
    dt = 2.0_wp*PI/om/REAL(NPP, wp)
    CALL line_seed(0.0_wp, 0.0_wp, q)
    CALL build_cable(cab, q, 0.0_wp, dt, 1.0e-10_wp, 0.9_wp, .FALSE., IRN, 0.0_wp)
    x = q(NDOF - 5:NDOF - 3)
    nstep = NPER*NPP
    ramp_t = REAL(NPER_RAMP, wp)*2.0_wp*PI/om
    tmax = -HUGE(1.0_wp)
    tmin = HUGE(1.0_wp)
    DO k = 1, nstep
      t = dt*REAL(k, wp)
      env = MIN(t/ramp_t, 1.0_wp)
      env = env**3*(10.0_wp - 15.0_wp*env + 6.0_wp*env**2)
      ang = AMPR*env*SIN(om*t)
      CALL CD_HFMF_UpdateStates(cab, x, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                u_orientation=roll_x(ang))
      CALL require(es == CD_HFMF_OK, 'W: step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      IF (t > ramp_t + 2.0_wp*PI/om) THEN
        CALL CD_HermiteCable_Dyn_Node_Torque(cab%line, ntq, es, em)
        tmax = MAX(tmax, ntq(1))
        tmin = MIN(tmin, ntq(1))
      END IF
    END DO
    kw = om/c
    expect = GJ*AMPR*kw/SIN(kw*LL)
    WRITE (*, '(A,F8.4,A,2ES14.6,A,ES14.6)') 'W torsional wave (Omega/omega_1 = ', om/om1, &
      '): held-end torque swing ', 0.5_wp*(tmax - tmin), 0.5_wp*(tmax + tmin), ' expected amplitude ', expect
    CALL require(ABS(0.5_wp*(tmax - tmin) - expect) <= 1.0e-2_wp*expect, &
                 'W: the held end carries the continuum torque GJ A k / sin(kL)')
    CALL require(ABS(0.5_wp*(tmax + tmin)) <= 1.0e-2_wp*expect, 'W: the torque swings about zero')
    CALL CD_HFMF_End(cab)
  END SUBROUTINE check_waves

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_driven_end(label)
    !! W: the drive of check_waves at Omega = omega_1/2 (kL = pi/2), by the parent's roll or by
    !! the imposed twist: the continuum's torque at the driven end, GJ A k cos(kL)/sin(kL), is
    !! zero, so the axial reaction moment there swings only by the discretisation; without the
    !! held end section's inertia (Irn l0/2) it would swing by Irn l0/2 Omega^2 A, 4 % of
    !! GJ A k here.
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: IRN = 0.5_wp, AMPR = 0.2_wp
    INTEGER, PARAMETER :: NPER_RAMP = 8, NPER = 14, NPP = 200
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab
    REAL(wp) :: q(NDOF), c, om, dt, t, env, ang, x(3), f(3), m(3), mmax, mmin, scale, ramp_t
    INTEGER :: k, es
    CHARACTER(300) :: em
    ALLOCATE (cab)
    c = SQRT(GJ/IRN)
    om = 0.5_wp*PI*c/LL
    dt = 2.0_wp*PI/om/REAL(NPP, wp)
    CALL line_seed(0.0_wp, 0.0_wp, q)
    CALL build_cable(cab, q, 0.0_wp, dt, 1.0e-10_wp, 0.9_wp, .FALSE., IRN, 0.0_wp)
    x = q(NDOF - 5:NDOF - 3)
    ramp_t = REAL(NPER_RAMP, wp)*2.0_wp*PI/om
    mmax = -HUGE(1.0_wp)
    mmin = HUGE(1.0_wp)
    DO k = 1, NPER*NPP
      t = dt*REAL(k, wp)
      env = MIN(t/ramp_t, 1.0_wp)
      env = env**3*(10.0_wp - 15.0_wp*env + 6.0_wp*env**2)
      ang = AMPR*env*SIN(om*t)
      IF (label == 'parent roll') THEN
        CALL CD_HFMF_UpdateStates(cab, x, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                  u_orientation=roll_x(ang))
      ELSE
        CALL CD_HFMF_UpdateStates(cab, x, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                  u_orientation=roll_x(0.0_wp), u_twist=ang)
      END IF
      CALL require(es == CD_HFMF_OK, 'W '//label//': step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      IF (t > ramp_t + 2.0_wp*PI/om) THEN
        CALL CD_HFMF_CalcOutput(cab, f, es, em, y_moment=m)
        mmax = MAX(mmax, m(1))
        mmin = MIN(mmin, m(1))
      END IF
    END DO
    scale = GJ*AMPR*(om/c)
    WRITE (*, '(A,A,A,ES12.4,A,ES12.4)') 'W driven end at kL = pi/2 (', label, '): axial reaction swing ', &
      0.5_wp*(mmax - mmin), ' of GJ A k ', scale
    CALL require(0.5_wp*(mmax - mmin) <= 1.0e-2_wp*scale, &
                 'W '//label//': the driven end reacts with the continuum torque, its section inertia included')
    CALL CD_HFMF_End(cab)
  END SUBROUTINE check_driven_end

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_damping()
    !! D: torsional damping Bt (torque Bt dtau/dt) is stiffness-proportional, so the first
    !! torsional mode of the clamped line has zeta_1 = omega_1 Bt/(2 GJ). The coupled end rolls
    !! by 0.2 rad in a quarter period of that mode and holds; the held end's torque then rings
    !! down about GJ 0.2/L with the logarithmic decrement 2 pi zeta_1/sqrt(1 - zeta_1^2) of the
    !! first mode (the higher modes, damped in proportion to their frequency, die first).
    REAL(wp), PARAMETER :: IRN = 0.5_wp, ZETA = 0.05_wp, ROLL = 0.2_wp
    INTEGER, PARAMETER :: NPP = 400, NPER = 12
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: q(NDOF), c, om1, dt, t, ang, x(3), ntq(NN), bt, mst, prev, prev2, delta, expect, tq
    REAL(wp) :: peaks(64), l0(NE), eye(3, 3), frame(3, 2)
    INTEGER :: k, es, npk
    CHARACTER(300) :: em
    ALLOCATE (cab)
    c = SQRT(GJ/IRN)
    om1 = PI*c/LL
    bt = 2.0_wp*GJ*ZETA/om1
    dt = 2.0_wp*PI/om1/REAL(NPP, wp)
    l0 = LL/REAL(NE, wp)
    eye = roll_x(0.0_wp)
    CALL line_seed(0.0_wp, 0.0_wp, q)
    CALL CD_HFMF_Init(cab, l0, [(EA, es=1, NE)], [(EI, es=1, NE)], [(RHOA, es=1, NE)], [(0.0_wp, es=1, NE)], q, &
                      [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], 0.0_wp, 0.0_wp, 1.0_wp, dt, NN, es, em, &
                      max_iter=60, tol=1.0e-10_wp)
    CALL CD_HFMF_Set_EndConnection(cab, [0.0_wp, 0.0_wp], RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                  [3, 2]), es, em, &
                                   coupled_d0_parent=[1.0_wp, 0.0_wp, 0.0_wp], parent_orientation=eye, &
                                   connection_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
    CALL torsion_of(q, 0.0_wp, tors, IRN, 0.0_wp)
    ALLOCATE (tors%bt(NE))
    tors%bt = bt
    frame(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
    frame(:, 2) = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL CD_HFMF_Set_Torsion(cab, tors, es, em, coupled_frame_parent=frame, parent_orientation=eye)
    CALL require(es == CD_HFMF_OK, 'D: damped torsion: '//TRIM(em))
    x = q(NDOF - 5:NDOF - 3)
    mst = GJ*ROLL/LL
    npk = 0
    prev = 0.0_wp
    prev2 = 0.0_wp
    DO k = 1, NPER*NPP
      t = dt*REAL(k, wp)
      ang = ROLL*MIN(1.0_wp, t/(0.25_wp*2.0_wp*PI/om1))
      CALL CD_HFMF_UpdateStates(cab, x, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                u_orientation=roll_x(ang))
      CALL require(es == CD_HFMF_OK, 'D: step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      CALL CD_HermiteCable_Dyn_Node_Torque(cab%line, ntq, es, em)
      tq = ntq(1) - mst
      ! local maxima of the deviation after the first two periods
      IF (k > 2 .AND. t > 2.0_wp*2.0_wp*PI/om1 .AND. prev > prev2 .AND. prev >= tq .AND. prev > 0.0_wp) THEN
        IF (npk < SIZE(peaks)) THEN
          npk = npk + 1
          peaks(npk) = prev
        END IF
      END IF
      prev2 = prev
      prev = tq
    END DO
    CALL require(npk >= 4, 'D: the torque rings down through several periods')
    IF (npk < 4) RETURN
    delta = LOG(peaks(1)/peaks(4))/3.0_wp
    expect = 2.0_wp*PI*ZETA/SQRT(1.0_wp - ZETA**2)
    WRITE (*, '(A,F8.5,A,F8.5,A,ES10.3)') 'D torsional damping: logarithmic decrement ', delta, ' expected ', &
      expect, '; mean torque - GJ roll/L ', ntq(1) - mst
    CALL require(ABS(delta - expect) <= 0.1_wp*expect, 'D: the first torsional mode decays at zeta = omega Bt/(2 GJ)')
    CALL CD_HFMF_End(cab)
  END SUBROUTINE check_damping

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_frame_damping()
    !! D: the straight clamped line with Irn = 1e-9 kg m and Bt = 40 N m2 s; the parent rolls the
    !! coupled end's frame (the imposed twist stays 0) at a rate eased in to OMR over 1 s, then
    !! steady. Every element carries the torque, so the held end reads (GJ theta + Bt theta_dot)/L
    !! with theta the parent's roll: the damping of the twist the frame's turn puts into the end
    !! element (a sixth of the torque here) included.
    REAL(wp), PARAMETER :: BT = 40.0_wp, OMR = 0.5_wp, TR = 1.0_wp, DT = 0.01_wp
    INTEGER, PARAMETER :: NSTEP = 300
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab
    REAL(wp) :: q(NDOF), x(3), t, ang, rate, ntq(NN), expect, err, mref
    INTEGER :: k, es
    CHARACTER(300) :: em
    ALLOCATE (cab)
    CALL line_seed(0.0_wp, 0.0_wp, q)
    CALL build_cable(cab, q, 0.0_wp, DT, 1.0e-11_wp, 0.8_wp, .FALSE., 1.0e-9_wp, 0.0_wp, bt=BT)
    x = q(NDOF - 5:NDOF - 3)
    err = 0.0_wp
    mref = (GJ*OMR*REAL(NSTEP, wp)*DT + BT*OMR)/LL
    DO k = 1, NSTEP
      t = DT*REAL(k, wp)
      IF (t < TR) THEN
        ang = OMR*(t**3/TR**2 - 0.5_wp*t**4/TR**3)
        rate = OMR*(3.0_wp*t**2/TR**2 - 2.0_wp*t**3/TR**3)
      ELSE
        ang = OMR*(t - 0.5_wp*TR)
        rate = OMR
      END IF
      CALL CD_HFMF_UpdateStates(cab, x, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                u_orientation=roll_x(ang))
      CALL require(es == CD_HFMF_OK, 'D frame: step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      IF (t > TR + 0.5_wp) THEN
        CALL CD_HermiteCable_Dyn_Node_Torque(cab%line, ntq, es, em)
        expect = (GJ*ang + BT*rate)/LL
        err = MAX(err, MAXVAL(ABS(ABS(ntq) - expect))/mref)
      END IF
    END DO
    WRITE (*, '(A,ES10.3,A,ES12.5,A,ES12.5)') 'D frame-driven damping: node torques against (GJ theta + Bt Omega)/L ', &
      err, '; held end ', ntq(1), ', elastic part ', GJ*ang/LL
    CALL require(err <= 1.0e-4_wp, 'D: a turning end frame loads the line with its torsional damping')
    CALL CD_HFMF_End(cab)
  END SUBROUTINE check_frame_damping

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE energy_run(phi, irn, band, e_vib)
    !! Free vibration of the bowed line clamped at both ends (no gravity, no fluid), rho_inf = 1,
    !! ten periods of the first bending mode; band = (max - min) of kinetic + elastic over the
    !! run, relative to the vibration energy above the straight twisted state.
    REAL(wp), INTENT(IN) :: phi, irn
    REAL(wp), INTENT(OUT) :: band, e_vib
    TYPE(CD_HermiteCableDynType) :: m
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: q(NDOF), l0(NE), ke, se, e0, emax, emin, t1, dt, e_straight
    INTEGER :: k, es, nstep
    CHARACTER(300) :: em
    l0 = LL/REAL(NE, wp)
    CALL line_seed(0.05_wp, 0.03_wp, q)
    CALL CD_HermiteCable_Dyn_Init(m, l0, [(EA, k=1, NE)], [(EI, k=1, NE)], [(RHOA, k=1, NE)], [(0.0_wp, k=1, NE)], q, &
                                  [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'E: init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_EndConnection(m, [0.0_wp, 0.0_wp], &
                                               RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], [3, 2]), &
                                               es, em, connection_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
    CALL require(es == CD_HCDYN_OK, 'E: end connections: '//TRIM(em))
    e_straight = 0.0_wp
    IF (phi > 0.0_wp) THEN
      CALL torsion_of(q, phi, tors, irn, 0.0_wp)
      CALL CD_HermiteCable_Dyn_Set_Torsion(m, tors, es, em)
      CALL require(es == CD_HCDYN_OK, 'E: torsion: '//TRIM(em))
      e_straight = 0.5_wp*(LL/GJ)*(GJ*phi/LL)**2
    END IF
    t1 = 2.0_wp*PI/(22.373_wp*SQRT(EI/(RHOA*LL**4)))
    dt = t1/400.0_wp
    nstep = 4000
    CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
    e0 = ke + se
    e_vib = e0 - e_straight
    emax = e0
    emin = e0
    DO k = 1, nstep
      CALL CD_HermiteCable_Dyn_Step(m, dt, 40, 1.0e-10_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'E: step: '//TRIM(em))
        EXIT
      END IF
      CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
      emax = nan_max_abs([emax, ke + se])
      emin = MIN(emin, ke + se)
    END DO
    band = (emax - emin)/e_vib
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE energy_run

  SUBROUTINE check_energy()
    REAL(wp) :: band0, band1, ev0, ev1
    CALL energy_run(0.0_wp, 0.0_wp, band0, ev0)
    CALL energy_run(4.0_wp, 0.02_wp, band1, ev1)
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'E energy band over 10 periods (rho_inf = 1): nodal twist ', band1, &
      ', untwisted ', band0, ' of the vibration energy'
    CALL require(band1 <= 5.0e-3_wp, 'E: kinetic + elastic energy with the nodal twist conserved within 0.5 %')
  END SUBROUTINE check_energy

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_frame_energy()
    !! E: the straight clamped line with Irn = 0.5 kg m and Bt = 10 N m2 s (zeta_1 = 0.25); the
    !! parent rolls the coupled end's frame (the imposed twist stays 0) at a rate eased in to OMR
    !! over 5 s, then steady. The sections spin as the continuum's, OMR s/L, so the kinetic
    !! energy is 1/2 sum I_j (OMR s_j/L)^2 over the lumped polar inertias, the held end's
    !! (I l0/2, its section spinning at OMR with a held angle) 7 % of it here.
    REAL(wp), PARAMETER :: IRN = 0.5_wp, BT = 10.0_wp, OMR = 0.5_wp, TR = 5.0_wp, DT = 0.01_wp
    INTEGER, PARAMETER :: NSTEP = 1000
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab
    REAL(wp) :: q(NDOF), x(3), t, ang, ke, se, expect, err, l0, mj
    INTEGER :: k, j, es
    CHARACTER(300) :: em
    ALLOCATE (cab)
    CALL line_seed(0.0_wp, 0.0_wp, q)
    CALL build_cable(cab, q, 0.0_wp, DT, 1.0e-11_wp, 0.8_wp, .FALSE., IRN, 0.0_wp, bt=BT)
    x = q(NDOF - 5:NDOF - 3)
    l0 = LL/REAL(NE, wp)
    expect = 0.0_wp
    DO j = 1, NN
      mj = MERGE(0.5_wp, 1.0_wp, j == 1 .OR. j == NN)*IRN*l0
      expect = expect + 0.5_wp*mj*(OMR*REAL(j - 1, wp)/REAL(NE, wp))**2
    END DO
    err = 0.0_wp
    DO k = 1, NSTEP
      t = DT*REAL(k, wp)
      IF (t < TR) THEN
        ang = OMR*(t**3/TR**2 - 0.5_wp*t**4/TR**3)
      ELSE
        ang = OMR*(t - 0.5_wp*TR)
      END IF
      CALL CD_HFMF_UpdateStates(cab, x, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], es, em, &
                                u_orientation=roll_x(ang))
      CALL require(es == CD_HFMF_OK, 'E frame: step: '//TRIM(em))
      IF (es /= CD_HFMF_OK) EXIT
      IF (t > 0.8_wp*REAL(NSTEP, wp)*DT) THEN
        CALL CD_HermiteCable_Dyn_Energy(cab%line, ke, se, es, em)
        CALL require(es == CD_HCDYN_OK, 'E frame: energy: '//TRIM(em))
        err = MAX(err, ABS(ke - expect)/expect)
      END IF
    END DO
    WRITE (*, '(A,ES10.3,A,ES12.5)') 'E frame-driven spin: kinetic energy against the continuum''s ', err, &
      ' of ', expect
    CALL require(err <= 1.0e-2_wp, 'E: a held end section spinning with its frame carries its kinetic energy')
    CALL CD_HFMF_End(cab)
  END SUBROUTINE check_frame_energy

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_pinned_energy()
    REAL(wp) :: band_lo, band_hi
    CALL check_pinned_carry(0.02_wp, 1.0e-6_wp, band_lo)
    CALL check_pinned_carry(1.0_wp, 1.0e-5_wp, band_hi)
    CALL require(ABS(band_hi - band_lo) <= 0.05_wp*band_lo, &
                 'E pinned: the energy band does not depend on the held sections'' polar inertia')
  END SUBROUTINE check_pinned_energy

  SUBROUTINE check_pinned_carry(irn, bound, band)
    !! E: the straight line pinned in bending and rigid in torsion at both ends (no gravity, no
    !! fluid, rho_inf = 1), twisted by 4 rad and released with the first pinned bending mode's
    !! velocity, 6 m/s at mid-span, for ten periods. Each step evaluates, from the end tangents
    !! m and their rates, the spin c = (t x d).dt/dt / (1 + d.t) of the carry G(d -> t) at both
    !! ends (d the end director +x) and the kinetic energy 1/2 I c^2 of the held end sections
    !! (I = Irn l0/2) that the model omits; its largest value against the peak kinetic energy
    !! must stay below bound. band: (max - min) of kinetic + elastic over E0.
    REAL(wp), INTENT(IN) :: irn, bound
    REAL(wp), INTENT(OUT) :: band
    TYPE(CD_HermiteCableDynType) :: m
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: q(NDOF), l0(NE), s, ke, se, e0, emax, emin, ke_max, tc, tc_max, th_max, dt, mm(3), mv(3), t(3)
    REAL(wp) :: td(3), c
    INTEGER :: k, es, iend, b
    CHARACTER(300) :: em
    l0 = LL/REAL(NE, wp)
    CALL line_seed(0.0_wp, 0.0_wp, q)
    CALL CD_HermiteCable_Dyn_Init(m, l0, [(EA, k=1, NE)], [(EI, k=1, NE)], [(RHOA, k=1, NE)], [(0.0_wp, k=1, NE)], q, &
                                  [1, 2, 3, NDOF - 5, NDOF - 4, NDOF - 3], 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'E pinned: init: '//TRIM(em))
    CALL torsion_of(q, 4.0_wp, tors, irn, 0.0_wp)
    CALL CD_HermiteCable_Dyn_Set_Torsion(m, tors, es, em)
    CALL require(es == CD_HCDYN_OK, 'E pinned: torsion: '//TRIM(em))
    band = HUGE(1.0_wp)
    IF (es /= CD_HCDYN_OK) RETURN
    DO k = 1, NN
      s = LL*REAL(k - 1, wp)/REAL(NE, wp)
      m%v(6*k - 4) = 6.0_wp*SIN(PI*s/LL)
      m%v(6*k - 1) = 6.0_wp*(PI/LL)*COS(PI*s/LL)
    END DO
    dt = 2.0_wp*PI/(PI*PI*SQRT(EI/(RHOA*LL**4)))/400.0_wp
    CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
    e0 = ke + se
    emax = e0
    emin = e0
    ke_max = ke
    tc_max = 0.0_wp
    th_max = 0.0_wp
    DO k = 1, 4000
      CALL CD_HermiteCable_Dyn_Step(m, dt, 40, 1.0e-11_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'E pinned: step: '//TRIM(em))
        EXIT
      END IF
      CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
      emax = nan_max_abs([emax, ke + se])
      emin = MIN(emin, ke + se)
      ke_max = MAX(ke_max, ke)
      tc = 0.0_wp
      DO iend = 1, 2
        b = MERGE(3, 6*(NN - 1) + 3, iend == 1)
        mm = m%q(b + 1:b + 3)
        mv = m%v(b + 1:b + 3)
        t = mm/NORM2(mm)
        td = (mv - DOT_PRODUCT(t, mv)*t)/NORM2(mm)
        ! (t x d) . td with d = +x: (0, t3, -t2) . td
        c = (t(3)*td(2) - t(2)*td(3))/(1.0_wp + t(1))
        tc = tc + 0.25_wp*irn*l0(1)*c*c
        th_max = MAX(th_max, ACOS(MIN(1.0_wp, t(1))))
      END DO
      tc_max = MAX(tc_max, tc)
    END DO
    WRITE (*, '(A,ES9.2,A,F5.1,A,ES10.3,A,ES10.3)') 'E pinned, Irn ', irn, ' kg m: end bend angle up to ', &
      th_max*180.0_wp/PI, ' deg; omitted carry-spin energy / peak kinetic energy ', tc_max/ke_max, &
      ', energy band / E0 ', (emax - emin)/e0
    CALL require(tc_max <= bound*ke_max, 'E pinned: the end sections'' carry spin holds a negligible energy')
    CALL require(th_max > 0.2_wp, 'E pinned: the end tangents swing off their directors')
    band = (emax - emin)/e0
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_pinned_carry

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_restart()
    !! R: 150 steps, snapshot, 100 more; restore and redo the 100: identical. A fresh module
    !! rebuilt from the mirror at step 150 continues identically too.
    TYPE(CD_HFMF_ModuleType), ALLOCATABLE :: cab, cab2
    REAL(wp) :: q(NDOF), qref(NDOF), pref(NN), qb(NDOF), pb(NN)
    REAL(wp), ALLOCATABLE :: mirror(:)
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(300) :: em
    ALLOCATE (cab, cab2)
    CALL line_seed(0.3_wp, 0.1_wp, q)
    CALL build_cable(cab, q, 1.0_wp, 0.01_wp, 1.0e-10_wp, 0.8_wp, .FALSE., 0.05_wp, 0.0_wp, bt=0.5_wp)
    CALL march(cab, 0, 150, ok)
    CALL require(ok, 'R: first leg')
    CALL CD_HFMF_Snapshot(cab, es, em)
    CALL require(es == CD_HFMF_OK, 'R: snapshot: '//TRIM(em))
    ALLOCATE (mirror(CD_HFMF_MirrorSize(cab)))
    CALL CD_HFMF_PackMirror(cab, mirror, es, em)
    CALL require(es == CD_HFMF_OK, 'R: mirror pack: '//TRIM(em))
    CALL march(cab, 150, 250, ok)
    CALL require(ok, 'R: second leg')
    qref = cab%line%q
    pref = cab%line%tw_phi
    CALL CD_HFMF_Restore(cab, es, em)
    CALL require(es == CD_HFMF_OK, 'R: restore: '//TRIM(em))
    CALL march(cab, 150, 250, ok)
    qb = cab%line%q
    pb = cab%line%tw_phi
    CALL require(ok .AND. ALL(bits(qb) == bits(qref)) .AND. ALL(bits(pb) == bits(pref)), &
                 'R: the restored run continues bit-identically')
    CALL line_seed(0.3_wp, 0.1_wp, q)
    CALL build_cable(cab2, q, 1.0_wp, 0.01_wp, 1.0e-10_wp, 0.8_wp, .FALSE., 0.05_wp, 0.0_wp, bt=0.5_wp)
    CALL CD_HFMF_UnpackMirror(cab2, mirror, 1.5_wp, es, em)
    CALL require(es == CD_HFMF_OK, 'R: mirror reload: '//TRIM(em))
    CALL march(cab2, 150, 250, ok)
    CALL require(ok .AND. ALL(bits(cab2%line%q) == bits(qref)) .AND. ALL(bits(cab2%line%tw_phi) == bits(pref)), &
                 'R: the run rebuilt from the mirror continues bit-identically')
    WRITE (*, '(A,F10.4,A)') 'R restart: end twist angle ', pref(NN), ' rad, snapshot and mirror runs identical'
    CALL CD_HFMF_End(cab)
    CALL CD_HFMF_End(cab2)
  END SUBROUTINE check_restart

  ELEMENTAL INTEGER(8) FUNCTION bits(x)
    REAL(wp), INTENT(IN) :: x
    bits = TRANSFER(x, 0_8)
  END FUNCTION bits

END PROGRAM test_nodal_twist_dynamic
