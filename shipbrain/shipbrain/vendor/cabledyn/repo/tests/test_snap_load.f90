! File: tests/test_snap_load.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_snap_load
  !! Snap-load response + the implicit-vs-explicit timestep-stability advantage (L5),
  !! on the Fortran core. A near-taut grounded mooring (line length 1.02x the
  !! anchor->fairlead chord, legacy axial damping BA/-zeta = -1) is driven by a
  !! prescribed harmonic fairlead heave (smooth rest-start ramp) large enough to take
  !! the legacy-style TENSION-ONLY line fully SLACK on the down-stroke and SNAP it
  !! taut on the up-stroke. Slack elements carry zero axial force (tension-only), so the
  !! slack phase is genuine -- not a compressive rod.
  !!
  !! This checks the stability of the implicit generalised-alpha step on a snap load. An
  !! explicit integrator is CFL-limited to
  !! dt < L_seg / sqrt(EA/m) (the axial-wave Courant condition, ~3.1 ms here); the
  !! implicit generalised-alpha path integrates the same snap stably at dt = 20 ms,
  !! more than six times the explicit CFL ceiling. The six-level study uses 0.5 ms
  !! as its self-reference and includes 1 and 2 ms points for an apparent-order estimate;
  !! the BA damping + Morison added mass regularise the snap so the peak is dt-convergent
  !! rather than a step-phasing artefact.
  !!
  !! A snap-load dt-stability gate. This Fortran gate composes the
  !! tension-only structure + penalty seabed + BA axial damping + Morison added mass
  !! (Morison drag and Froude-Krylov loads are not included in this gate). Self-
  !! contained (no external reference). The prescribed fairlead heave uses the
  !! time-varying-Dirichlet path (CD_Cable_Gen_Alpha_Step prescribed_q/v/a).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, &
                           CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load, CD_Seabed_Penalty_Load
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  USE CableDyn_Damping, ONLY: CD_Resolve_Legacy_BA, CD_Cable_Axial_Damping_Load, &
                              CD_Cable_Axial_Damping_Force, CD_Cable_Element_Damping_Tension, CD_DAMP_OK
  USE CableDyn_Hydro, ONLY: CD_Cable_Added_Mass
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_Cable_Gen_Alpha_Step, &
                              CD_Cable_Initial_Acceleration, CD_DYN_OK
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 20, NN = NE + 1, NDOF = 3*NN
  REAL(wp), PARAMETER :: GRAV = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: EA0 = 1.674e9_wp, MASS0 = 390.0_wp, DIAM0 = 0.252_wp
  REAL(wp), PARAMETER :: ANCHOR(3) = [120.0_wp, 0.0_wp, -50.0_wp]
  REAL(wp), PARAMETER :: FAIRLEAD(3) = [0.0_wp, 0.0_wp, -5.0_wp]
  REAL(wp), PARAMETER :: SLACK_FACTOR = 1.02_wp
  REAL(wp), PARAMETER :: SEABED_Z = -50.0_wp, KN_BASE = 1.0e5_wp
  REAL(wp), PARAMETER :: SLACK_TOL = 1.0e3_wp   ! N: elastic floor must reach ~0 (genuine slack)
  REAL(wp), PARAMETER :: HEAVE_AMP = 4.0_wp, HEAVE_PERIOD = 4.0_wp, RAMP_TIME = 4.0_wp, SIM_TIME = 8.0_wp
  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  ! Legacy-style TENSION-ONLY line: slack elements carry zero force, used consistently
  ! for the static equilibrium, the initial acceleration, the step, and the tension.
  LOGICAL, PARAMETER :: TENSION_ONLY = .TRUE.

  ! host state for the load procedures (host-associated by ba_load/ba_force/am_proc)
  INTEGER  :: conn_h(2, NE)
  REAL(wp) :: l0_h(NE), ba_h(NE), ea_h(NE), rho_a_h(NE), kn_h(NN)
  REAL(wp) :: q_eq(NDOF), fl0(3)
  INTEGER  :: fixed_h(3 + (NE - 1) + 3)

  INTEGER, PARAMETER :: NDT = 6
  REAL(wp), PARAMETER :: DTS(NDT) = [0.0005_wp, 0.001_wp, 0.002_wp, 0.005_wp, 0.010_wp, 0.020_wp]
  INTEGER :: nfail, j, out_unit, arg_status
  REAL(wp) :: chord, seg_len, dt_cfl, peak_err
  REAL(wp) :: tmins(NDT), tmaxs(NDT), peak_errors(NDT), observed_order
  LOGICAL  :: converged(NDT)
  INTEGER  :: nsteps(NDT)
  CHARACTER(512) :: output_path
  nfail = 0

  CALL build_equilibrium()

  chord = NORM2(FAIRLEAD - ANCHOR)
  seg_len = SLACK_FACTOR*chord/REAL(NE, wp)
  dt_cfl = seg_len/SQRT(EA0/MASS0)
  CALL require(DTS(1) < dt_cfl, 'setup:fine-below-cfl')
  CALL require(DTS(NDT)/dt_cfl > 6.0_wp, 'setup:coarse-well-above-cfl')

  DO j = 1, NDT
    CALL run_snap(DTS(j), tmins(j), tmaxs(j), converged(j), nsteps(j))
    CALL require(converged(j), 'stability:all requested time steps converged')
  END DO
  peak_errors = ABS(tmaxs - tmaxs(1))/tmaxs(1)
  observed_order = LOG(peak_errors(3)/peak_errors(2))/LOG(DTS(3)/DTS(2))
  ! Slack is judged on the elastic-tension floor (tmin_*) against an ABSOLUTE near-zero
  ! tolerance: tension-only slack clamps the elastic tension to exactly 0, so the floor
  ! must reach ~0 (SLACK_TOL = 1 kN, far below any taut tension and the MN-scale peak).
  ! A relative-to-peak threshold would tolerate a lightly-taut line that never slacks.
  ! The peak (tmax_*) is the total dynamic tension magnitude.
  CALL require(tmins(1) < SLACK_TOL, 'signature:fine-slack')
  CALL require(tmaxs(1) > 2.5e6_wp, 'signature:fine-snap-spike')
  CALL require(tmins(NDT) < SLACK_TOL, 'signature:coarse-slack')
  CALL require(tmaxs(NDT) > 2.5e6_wp, 'signature:coarse-snap-spike')
  peak_err = peak_errors(NDT)
  CALL require(peak_err < 0.05_wp, 'fidelity:coarse-peak-within-5pct')

  WRITE (*, '(A,F8.3,A,F8.3,A,F8.3,A)') 'snap dt_cfl=', dt_cfl*1.0e3_wp, ' ms, fine=', &
    DTS(1)*1.0e3_wp, ' ms, coarse=', DTS(NDT)*1.0e3_wp, ' ms'
  DO j = 1, NDT
    WRITE (*, '(A,F7.3,A,F10.4,A,F8.4,A,L1)') '  dt=', DTS(j)*1.0e3_wp, ' ms, peak=', &
      tmaxs(j)*1.0e-6_wp, ' MN, relative change=', 100.0_wp*peak_errors(j), '%, converged=', converged(j)
  END DO
  WRITE (*, '(A,F7.3)') '  apparent peak-convergence order from 1 to 2 ms = ', observed_order

  output_path = ''
  CALL GET_COMMAND_ARGUMENT(1, output_path, STATUS=arg_status)
  IF (arg_status == 0 .AND. LEN_TRIM(output_path) > 0) THEN
    OPEN (NEWUNIT=out_unit, FILE=TRIM(output_path), STATUS='REPLACE', ACTION='WRITE')
    WRITE (out_unit, '(A)') &
      'step_ms courant_ratio peak_MN relative_change_pct stable n_steps rho_infinity'
    DO j = 1, NDT
      WRITE (out_unit, '(F0.4,1X,F0.10,1X,F0.8,1X,F0.8,1X,I0,1X,I0,1X,F0.3)') DTS(j)*1.0e3_wp, &
        DTS(j)/dt_cfl, tmaxs(j)*1.0e-6_wp, 100.0_wp*peak_errors(j), &
        MERGE(1, 0, converged(j)), nsteps(j), 0.8_wp
    END DO
    CLOSE (out_unit)
  END IF

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: snap-load implicit dt-stability (tension-only, stable + accurate above the explicit CFL)'

CONTAINS

  SUBROUTINE build_equilibrium()
    !! Build the mesh + resolve BA + per-node seabed stiffness, solve the tension-only
    !! grounded static equilibrium (catenary seed + continuation + penalty seabed), and
    !! set the host state for the load procedures and the fixed-DOF list.
    TYPE(CD_LineType) :: lts(1)
    TYPE(CD_LineSection) :: secs(1)
    INTEGER, ALLOCATABLE :: conn(:, :)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), mpl(:), diam(:), w(:), f_extb(:), load(:, :), q0(:), q(:), kn(:)
    REAL(wp) :: ba1, h, gl, factors(4)
    INTEGER  :: i, k, n_iter, n_stages, esb
    LOGICAL  :: conv, st, af
    TYPE(CableSolverConfig) :: scfg
    CHARACTER(200) :: emb
    factors = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]

    lts(1) = CD_LineType(ea=EA0, mass_per_length=MASS0, diameter=DIAM0)
    secs(1) = CD_LineSection(line_type=1, length=SLACK_FACTOR*NORM2(FAIRLEAD - ANCHOR), n_segments=NE)
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, mpl, diam, esb, emb)
    CALL require(esb == CD_LINE_OK, 'eq:build')
    conn_h = conn; l0_h = l0; ea_h = ea; rho_a_h = mpl

    CALL CD_Resolve_Legacy_BA(-1.0_wp, l0(1), EA0, MASS0, ba1, esb, emb)
    CALL require(esb == CD_DAMP_OK .AND. ba1 > 0.0_wp, 'eq:resolve-ba')
    ba_h = ba1

    CALL CD_Nodal_Seabed_Stiffness(KN_BASE, diam, l0, kn, esb, emb)
    CALL require(esb == CD_LINE_OK, 'eq:kn')
    kn_h = kn

    ALLOCATE (w(NE), f_extb(NDOF), load(3, NE), q0(NDOF), q(NDOF))
    CALL CD_Submerged_Weight(mpl, diam, RHO, GRAV, w, esb, emb)
    CALL require(esb == 0, 'eq:weight')
    DO i = 1, NE
      load(:, i) = [0.0_wp, 0.0_wp, -w(i)]
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_extb, esb, emb)
    CALL require(esb == 0, 'eq:load')

    CALL CD_Catenary_Seed(ANCHOR, FAIRLEAD, l0, ea, w, q0, h, gl, esb, emb)
    CALL require(esb == CD_CAT_OK, 'eq:seed')

    ! fixed DOFs: anchor (xyz) + all interior y (planar) + fairlead (xyz)
    fixed_h(1:3) = [1, 2, 3]
    k = 3
    DO i = 2, NE
      k = k + 1; fixed_h(k) = 3*i - 1
    END DO
    fixed_h(k + 1:k + 3) = [NDOF - 2, NDOF - 1, NDOF]

    ! tension-only grounded equilibrium with the penalty seabed (the robust L2-1 pattern)
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, TENSION_ONLY, f_extb, fixed_h, scfg, &
                                            factors, q, conv, st, af, n_iter, n_stages, esb, emb, &
                                            seabed_z_floor=SEABED_Z, seabed_kn=kn)
    CALL require(esb == CD_STATIC_OK .AND. conv, 'eq:static-converged')
    CALL require(MINVAL(q(3:NDOF:3)) > SEABED_Z - 0.1_wp, 'eq:above-seabed')
    q_eq = q
    fl0 = q(NDOF - 2:NDOF)
  END SUBROUTINE build_equilibrium

  SUBROUTINE heave_kin(t, heave, vz, az)
    !! Prescribed fairlead heave A env(t) sin(wt) and its first two time derivatives,
    !! with a smooth half-cosine rest-start envelope (env=env'=env''=0 at t=0).
    REAL(wp), INTENT(IN)  :: t
    REAL(wp), INTENT(OUT) :: heave, vz, az
    REAL(wp) :: wf, env, env_d, env_dd, x, wr, s, c
    wf = 2.0_wp*PI/HEAVE_PERIOD
    IF (t >= RAMP_TIME) THEN
      env = 1.0_wp; env_d = 0.0_wp; env_dd = 0.0_wp
    ELSE
      x = PI*t/RAMP_TIME
      wr = PI/RAMP_TIME
      env = 0.5_wp*(1.0_wp - COS(x))
      env_d = 0.5_wp*wr*SIN(x)
      env_dd = 0.5_wp*wr*wr*COS(x)
    END IF
    s = SIN(wf*t); c = COS(wf*t)
    heave = HEAVE_AMP*env*s
    vz = HEAVE_AMP*(env_d*s + env*wf*c)
    az = HEAVE_AMP*(env_dd*s + 2.0_wp*env_d*wf*c - env*wf*wf*s)
  END SUBROUTINE heave_kin

  SUBROUTINE run_snap(dt, t_min, t_max, all_converged, n)
    !! March the ramped harmonic heave at `dt`; return the post-ramp fairlead tension
    !! extremes and whether every step converged. `t_min` is the minimum CLAMPED
    !! ELASTIC tension (the genuine slack indicator -- zero when the line goes slack);
    !! `t_max` is the maximum total magnitude |elastic + Td| (the snap peak).
    REAL(wp), INTENT(IN)  :: dt
    REAL(wp), INTENT(OUT) :: t_min, t_max
    LOGICAL, INTENT(OUT) :: all_converged
    INTEGER, INTENT(OUT) :: n
    REAL(wp) :: q(NDOF), v(NDOF), a(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF)
    REAL(wp) :: pq(NDOF), pv(NDOF), pa(NDOF), f_ext0(NDOF)
    REAL(wp) :: tension(NE), td(NE), heave, vz, az, t_np1, fl_ten
    INTEGER  :: step, esr, n_iter
    LOGICAL  :: conv, st
    TYPE(GenAlphaConfig) :: dcfg
    CHARACTER(200) :: emr

    CALL gravity_fext(f_ext0)
    q = q_eq; v = 0.0_wp
    CALL CD_Cable_Initial_Acceleration(q, v, conn_h, l0_h, ea_h, rho_a_h, TENSION_ONLY, &
                                       f_ext0, fixed_h, a, esr, emr, &
                                       load_proc=ba_load, added_mass_proc=am_proc, load_force_proc=ba_force)
    all_converged = (esr == CD_DYN_OK)
    t_min = HUGE(1.0_wp); t_max = -HUGE(1.0_wp)
    n = INT(SIM_TIME/dt)
    DO step = 1, n
      t_np1 = REAL(step, wp)*dt
      CALL heave_kin(t_np1, heave, vz, az)
      pq = q_eq; pv = 0.0_wp; pa = 0.0_wp
      pq(NDOF) = fl0(3) + heave
      pv(NDOF) = vz
      pa(NDOF) = az
      CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn_h, l0_h, ea_h, rho_a_h, TENSION_ONLY, &
                                   f_ext0, fixed_h, dt, dcfg, q_new, v_new, a_new, conv, st, n_iter, &
                                   esr, emr, load_proc=ba_load, added_mass_proc=am_proc, &
                                   load_force_proc=ba_force, &
                                   prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
      all_converged = all_converged .AND. (esr == CD_DYN_OK) .AND. conv
      IF (esr /= CD_DYN_OK) RETURN
      q = q_new; v = v_new; a = a_new
      CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, NN]), conn_h, l0_h, ea_h, TENSION_ONLY, tension, esr, emr)
      IF (esr /= 0) THEN
        all_converged = .FALSE.; RETURN
      END IF
      CALL CD_Cable_Element_Damping_Tension(q, v, conn_h, l0_h, ba_h, td, esr, emr)
      IF (esr /= CD_DAMP_OK) THEN
        all_converged = .FALSE.; RETURN
      END IF
      IF (t_np1 >= RAMP_TIME) THEN
        ! Slack is judged on the CLAMPED ELASTIC tension only (tension-only ->
        ! genuinely 0 when slack); t_min is that elastic floor. The reported snap PEAK
        ! uses the total magnitude |elastic + Td|. Mixing the (signed, possibly
        ! negative) damping Td into the slack metric could read as slack by elastic/
        ! damping cancellation while the elastic line is still taut, so they are split.
        t_min = MIN(t_min, tension(NE))               ! elastic floor (slack indicator)
        fl_ten = ABS(tension(NE) + td(NE))            ! total magnitude (snap peak)
        t_max = MAX(t_max, fl_ten)
      END IF
    END DO
  END SUBROUTINE run_snap

  SUBROUTINE gravity_fext(f_ext0)
    REAL(wp), INTENT(OUT) :: f_ext0(NDOF)
    REAL(wp) :: w(NE), load(3, NE), diam(NE), mpl(NE)
    INTEGER  :: i, esg
    CHARACTER(200) :: emg
    mpl = MASS0; diam = DIAM0
    CALL CD_Submerged_Weight(mpl, diam, RHO, GRAV, w, esg, emg)
    DO i = 1, NE
      load(:, i) = [0.0_wp, 0.0_wp, -w(i)]
    END DO
    CALL CD_Assemble_Distributed_Load(conn_h, l0_h, load, f_ext0, esg, emg)
  END SUBROUTINE gravity_fext

  SUBROUTINE ba_load(q, v, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Composed dynamic load (matches CD_Cable_Dynamic_Load_Proc): BA axial damping +
    !! penalty seabed contact. Both return the force to subtract and the residual
    !! Jacobian -d(force)/dq; the seabed has no velocity dependence.
    REAL(wp), INTENT(IN)  :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: f_ba(NDOF), f_sb(NDOF)
    ! The three Jacobian blocks (about 95 KB) live on the heap, not the stack.
    REAL(wp), ALLOCATABLE :: jq_ba(:, :), jv_ba(:, :), kr_sb(:, :)
    ALLOCATE (jq_ba(NDOF, NDOF), jv_ba(NDOF, NDOF), kr_sb(NDOF, NDOF))
    CALL CD_Cable_Axial_Damping_Load(q, v, conn_h, l0_h, ba_h, f_ba, jq_ba, jv_ba, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DAMP_OK) RETURN
    CALL CD_Seabed_Penalty_Load(RESHAPE(q, [3, NN]), kn_h, SEABED_Z, f_sb, kr_sb, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    force = f_ba + f_sb
    jac_q = jq_ba + kr_sb
    jac_v = jv_ba
  END SUBROUTINE ba_load

  SUBROUTINE ba_force(q, v, force, ErrStat, ErrMsg)
    !! Composed force only (BA damping + seabed), matching CD_Cable_Dynamic_Force_Proc.
    REAL(wp), INTENT(IN)  :: q(:), v(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: f_ba(NDOF), f_sb(NDOF), kr_sb(NDOF, NDOF)
    CALL CD_Cable_Axial_Damping_Force(q, v, conn_h, l0_h, ba_h, f_ba, ErrStat, ErrMsg)
    IF (ErrStat /= CD_DAMP_OK) RETURN
    CALL CD_Seabed_Penalty_Load(RESHAPE(q, [3, NN]), kn_h, SEABED_Z, f_sb, kr_sb, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    force = f_ba + f_sb
  END SUBROUTINE ba_force

  SUBROUTINE am_proc(q, accel, M_add, dMa_a_dq, ErrStat, ErrMsg)
    !! Morison added mass (matches CD_Cable_Added_Mass_Proc). The line is submerged
    !! (z < 0), so the waterline sits above every node (z = 0) and the added mass is
    !! fully active (Ca_n = 1.0, Ca_t = 0.0). The extra effective inertia regularises
    !! the snap so the implicit step stays stable + accurate above the explicit CFL.
    REAL(wp), INTENT(IN)  :: q(:), accel(:)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: waterline(NN)
    waterline = 0.0_wp
    CALL CD_Cable_Added_Mass(q, accel, conn_h, l0_h, waterline, RHO, DIAM0, 1.0_wp, 0.0_wp, &
                             M_add, dMa_a_dq, ErrStat, ErrMsg)
  END SUBROUTINE am_proc

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_snap_load
