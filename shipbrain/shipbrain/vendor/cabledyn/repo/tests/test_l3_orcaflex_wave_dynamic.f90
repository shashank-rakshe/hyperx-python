! File: tests/test_l3_orcaflex_wave_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_orcaflex_wave_dynamic
  !! L3-2 regular-wave OrcaFlex parity on the Fortran core, self-contained (no
  !! non-Fortran code at build or run time).
  !!
  !! The WD0050 grounded chain (410 m, 41 segments, anchor at [400, 0, -50],
  !! fairlead held at the origin) is solved to static equilibrium (catenary seed
  !! + load continuation + penalty seabed) and then marched with the implicit
  !! generalised-alpha integrator under a regular Airy wave (H = 3 m, T = 8 s,
  !! direction 180 deg). The composed dynamic load set is the one the deck driver's
  !! EI=0 line models apply: penalty seabed + Morison drag +
  !! Froude-Krylov / fluid inertia + surface-piercing buoyancy recovery, with
  !! Morison added mass in the effective mass. The wave field is sampled at the
  !! fixed still-water mean positions (the static solution) at the gen-alpha
  !! intermediate force time, so the hydro effective tangent stays consistent --
  !! matching the validated Fortran dynamic reference bridge.
  !!
  !! The held fairlead makes still water a zero-motion fixed point; the wave
  !! breaks it into a kN-scale fairlead-tension swing. The steady last two of six
  !! periods are scored against a PINNED, dt-CONVERGED OrcaFlex reference
  !! (OrcFxAPI 11.6d, regenerated 2026-07-03 by validation/scripts/orcaflex_wave_stretching_probe.py's
  !! matched protocol: 41 segments, Single Airy H = 3 m / T = 8 s / dir 180 deg,
  !! vertical stretching -- OrcaFlex's own default; Wheeler-vs-vertical moves this
  !! swing by only 0.18% -- implicit dt = log interval = 0.005 s, 16 s build-up +
  !! 6 periods, latest-period window; dt 0.01 -> 0.005 moves the swing 0.019%):
  !!   mean fairlead tension = 998148.768523274 N  (gate: rel err < 2%)
  !!   peak-to-peak swing    = 7881.65283203125 N  (gate: rel err < 15%)
  !! The reference must be dt-converged: at OrcaFlex's default dt = 0.1 s the swing reads
  !! 8771 N. Against the converged reference CableDyn's production-dt swing sits at ~8.4%;
  !! the residual is discretization of the surface-piercing loads on the 10 m top
  !! segment: under joint mesh refinement the two codes' swings rise together (matched-
  !! discretization differences 11.4% -> 7.4% -> 4.9% at 41seg/dt0.05, 41seg/dt->0,
  !! 82seg/dt0.02). The mean is the tight, physics-defining metric.
  !!
  !! rho_inf = 0.4 follows the OrcaFlex dynamic generalised-alpha convention (the
  !! WD0050 wave deck setting); the static/dynamic Newton tolerances mirror that
  !! deck so this gate exercises the same numerical path the driver does.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, CD_LINE_OK
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load, CD_Seabed_Penalty_Load
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  USE CableDyn_Hydro, ONLY: CD_Airy_Wave_Kinematics, CD_Cable_Morison_Drag_Force, &
                            CD_Cable_Froude_Krylov_Force, CD_Cable_Buoyancy_Recovery_Force, &
                            CD_Cable_Added_Mass_Matrix, CD_HYDRO_OK
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_Cable_Gen_Alpha_Step, &
                              CD_Cable_Initial_Acceleration, CD_DYN_OK
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension, CD_Assemble_Cable_Internal_Force
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  ! --- WD0050 chain + environment (scalars of the regular-wave reference case) ---
  REAL(wp), PARAMETER :: GRAV = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: EA0 = 1.674e9_wp, MASS0 = 390.0_wp, DIAM0 = 0.252_wp
  REAL(wp), PARAMETER :: CDN = 1.37_wp, CDT = 0.64_wp, CAN = 1.0_wp, CAT = 0.0_wp
  REAL(wp), PARAMETER :: KN_NODE = 1.0e5_wp
  REAL(wp), PARAMETER :: WATER_DEPTH = 50.0_wp, SEABED_Z = -50.0_wp
  REAL(wp), PARAMETER :: WAVE_H = 3.0_wp, WAVE_T = 8.0_wp, WAVE_DIR = 180.0_wp
  REAL(wp), PARAMETER :: ANCHOR_X = 400.0_wp, TOTAL_LEN = 410.0_wp
  INTEGER, PARAMETER  :: N_SEG = 41
  REAL(wp), PARAMETER :: DT = 0.05_wp, RHO_INF = 0.4_wp
  INTEGER, PARAMETER  :: N_PERIODS = 6, N_STEADY_PERIODS = 2

  ! --- OrcaFlex reference scalars + gates (validation/scripts/orcaflex_wave_stretching_probe.py) ---
  REAL(wp), PARAMETER :: ORCA_MEAN_N = 998148.768523274_wp
  REAL(wp), PARAMETER :: ORCA_SWING_N = 7881.65283203125_wp
  REAL(wp), PARAMETER :: MEAN_RTOL = 0.02_wp, SWING_RTOL = 0.15_wp

  ! --- host state shared with the load procedures (host association) ---
  INTEGER :: NE, NN, NDOF
  INTEGER, ALLOCATABLE :: conn(:, :)
  REAL(wp), ALLOCATABLE :: l0(:), diam(:), kn(:)
  REAL(wp), ALLOCATABLE :: q_wave_ref(:)   ! fixed mean sample positions for the wave field
  REAL(wp) :: t_eval                       ! gen-alpha intermediate force time

  INTEGER :: nfail, output_unit, output_ios
  CHARACTER(500) :: output_path
  nfail = 0
  output_unit = -1; output_path = ''
  CALL GET_COMMAND_ARGUMENT(1, output_path)
  IF (LEN_TRIM(output_path) > 0) THEN
    OPEN (NEWUNIT=output_unit, FILE=TRIM(output_path), STATUS='REPLACE', ACTION='WRITE', IOSTAT=output_ios)
    IF (output_ios /= 0) ERROR STOP 'cannot open regular-wave comparison output'
    WRITE (output_unit, '(A)') 'model mean_tension_kN tension_swing_kN mean_difference_pct swing_difference_pct'
  END IF

  CALL run_wave_cell()

  IF (output_unit /= -1) CLOSE (output_unit)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-2 regular-wave OrcaFlex fairlead-tension parity (mean < 2%, swing < 15%)'

CONTAINS

  SUBROUTINE run_wave_cell()
    INTEGER :: i, k, es, n_iter, n_stages, step, nstep, n_steady
    TYPE(CD_LineType) :: lts(1)
    TYPE(CD_LineSection) :: secs(1)
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp), ALLOCATABLE :: ea(:), mpl(:), w(:), f_ext(:), load(:, :), q0(:), q(:)
    REAL(wp), ALLOCATABLE :: v(:), a(:), q_new(:), v_new(:), a_new(:), tension(:), fair_trace(:)
    REAL(wp), ALLOCATABLE :: chan_trace(:), fint_c(:), fhyd(:)
    REAL(wp) :: anchor(3), fairlead(3), h, gl, factors(4), alpha_f
    REAL(wp) :: mean_n, fmin, fmax, swing_n, mean_err, swing_err, steady_start
    LOGICAL  :: conv, st, af
    TYPE(CableSolverConfig) :: scfg
    TYPE(GenAlphaConfig) :: dcfg
    CHARACTER(200) :: em

    factors = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
    NE = N_SEG; NN = NE + 1; NDOF = 3*NN
    anchor = [ANCHOR_X, 0.0_wp, SEABED_Z]; fairlead = [0.0_wp, 0.0_wp, 0.0_wp]

    ! --- mesh + per-element props (host state for the load procs) ---
    lts(1) = CD_LineType(ea=EA0, mass_per_length=MASS0, diameter=DIAM0)
    secs(1) = CD_LineSection(line_type=1, length=TOTAL_LEN, n_segments=NE)
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, mpl, diam, es, em)
    CALL require(es == CD_LINE_OK, 'build-mesh')
    ALLOCATE (kn(NN)); kn = KN_NODE

    ! --- self-weight + static equilibrium IC (catenary seed + continuation + seabed) ---
    ALLOCATE (w(NE), f_ext(NDOF), load(3, NE), q0(NDOF), q(NDOF), tension(NE), q_wave_ref(NDOF))
    CALL CD_Submerged_Weight(mpl, diam, RHO, GRAV, w, es, em)
    CALL require(es == 0, 'submerged-weight')
    DO i = 1, NE
      load(:, i) = [0.0_wp, 0.0_wp, -w(i)]
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL require(es == 0, 'distributed-load')
    CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, q0, h, gl, es, em)
    CALL require(es == CD_CAT_OK, 'catenary-seed')

    ! Fixed DOFs: anchor xyz, fairlead xyz, all internal y-DOFs (planar case) -- the
    ! held fairlead is what lets the wave drive a tension swing against a fixed point.
    ALLOCATE (fixed(6 + (NE - 1)))
    fixed(1:3) = [1, 2, 3]; k = 3
    DO i = 2, NE
      k = k + 1; fixed(k) = 3*i - 1
    END DO
    fixed(k + 1:k + 3) = [NDOF - 2, NDOF - 1, NDOF]

    scfg%rel_tol = 1.0e-8_wp; scfg%abs_tol = 1.0e-5_wp
    scfg%max_iter = 80; scfg%armijo_max_backtracks = 12
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, scfg, factors, &
                                            q, conv, st, af, n_iter, n_stages, es, em, &
                                            seabed_z_floor=SEABED_Z, seabed_kn=kn)
    CALL require(es == CD_STATIC_OK .AND. conv, 'static-IC')
    IF (nfail > 0) RETURN

    ! --- dynamic march under the regular Airy wave ---
    dcfg%rho_inf = RHO_INF
    dcfg%rel_tol = 1.0e-8_wp; dcfg%abs_tol = 1.0e-3_wp
    dcfg%max_iter = 30; dcfg%armijo_max_backtracks = 14
    alpha_f = dcfg%rho_inf/(dcfg%rho_inf + 1.0_wp)

    nstep = NINT(REAL(N_PERIODS, wp)*WAVE_T/DT)
    ALLOCATE (v(NDOF), a(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), fair_trace(nstep), chan_trace(nstep), &
              fint_c(NDOF), fhyd(NDOF))
    v = 0.0_wp
    q_wave_ref = q          ! sample the wave field at the fixed still-water mean positions
    t_eval = 0.0_wp
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, mpl, .FALSE., f_ext, fixed, a, es, em, &
                                       load_proc=wave_load, added_mass_proc=wave_added_mass, &
                                       load_force_proc=wave_force)
    CALL require(es == CD_DYN_OK, 'initial-acceleration')
    IF (nfail > 0) RETURN

    DO step = 1, nstep
      ! gen-alpha intermediate force time t_alpha = t_n + (1 - alpha_f) dt
      t_eval = REAL(step - 1, wp)*DT + (1.0_wp - alpha_f)*DT
      CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, mpl, .FALSE., f_ext, fixed, DT, dcfg, &
                                   q_new, v_new, a_new, conv, st, n_iter, es, em, &
                                   load_proc=wave_load, added_mass_proc=wave_added_mass, &
                                   load_force_proc=wave_force)
      CALL require(es == CD_DYN_OK .AND. conv, 'dynamic-step')
      IF (nfail > 0) RETURN
      q = q_new; v = v_new; a = a_new
      CALL CD_Compute_Cable_Tension(reshape3(q), conn, l0, ea, .FALSE., tension, es, em)
      CALL require(es == 0, 'tension')
      IF (nfail > 0) RETURN
      fair_trace(step) = tension(NE)
      ! the FairTen channel: the force the line exerts on the held fairlead at the end of the
      ! step -- the end element's force plus the end node's submerged weight and wave loads at
      ! the actual velocity (f_ext + f_hydro - f_int at the node)
      t_eval = REAL(step, wp)*DT
      CALL CD_Assemble_Cable_Internal_Force(reshape3(q), conn, l0, ea, .FALSE., fint_c, es, em)
      CALL require(es == 0, 'end-force internal')
      CALL wave_force(q, v, fhyd, es, em)
      CALL require(es == 0, 'end-force hydro')
      IF (nfail > 0) RETURN
      chan_trace(step) = NORM2(f_ext(NDOF - 2:NDOF) + fhyd(NDOF - 2:NDOF) - fint_c(NDOF - 2:NDOF))
    END DO

    ! --- score the steady last two periods vs OrcaFlex (matches the previous reference checker) ---
    steady_start = REAL(N_PERIODS - N_STEADY_PERIODS, wp)*WAVE_T
    mean_n = 0.0_wp; fmin = HUGE(1.0_wp); fmax = -HUGE(1.0_wp); n_steady = 0
    DO step = 1, nstep
      IF (REAL(step, wp)*DT >= steady_start - 1.0e-12_wp) THEN
        mean_n = mean_n + fair_trace(step)
        fmin = MIN(fmin, fair_trace(step))
        fmax = MAX(fmax, fair_trace(step))
        n_steady = n_steady + 1
      END IF
    END DO
    CALL require(n_steady >= NINT(REAL(N_STEADY_PERIODS, wp)*WAVE_T/DT), 'steady-window-samples')
    IF (nfail > 0) RETURN
    mean_n = mean_n/REAL(n_steady, wp)
    swing_n = fmax - fmin
    mean_err = ABS(mean_n - ORCA_MEAN_N)/ORCA_MEAN_N
    swing_err = ABS(swing_n - ORCA_SWING_N)/ORCA_SWING_N

    WRITE (*, '(A,F9.3,A,F9.3,A,F7.3,A)') 'L3-2 Fortran vs OrcaFlex: mean=', mean_n/1.0e3_wp, &
      ' kN (ref ', ORCA_MEAN_N/1.0e3_wp, ', err ', 100.0_wp*mean_err, '%)'
    WRITE (*, '(A,F9.3,A,F9.3,A,F7.3,A)') '                          swing=', swing_n/1.0e3_wp, &
      ' kN (ref ', ORCA_SWING_N/1.0e3_wp, ', err ', 100.0_wp*swing_err, '%)'
    IF (output_unit /= -1) THEN
      WRITE (output_unit, '(A,4(1X,ES16.8))') 'CableDyn', mean_n/1.0e3_wp, swing_n/1.0e3_wp, &
        100.0_wp*mean_err, 100.0_wp*swing_err
      WRITE (output_unit, '(A,4(1X,ES16.8))') 'OrcaFlex', ORCA_MEAN_N/1.0e3_wp, ORCA_SWING_N/1.0e3_wp, &
        0.0_wp, 0.0_wp
    END IF

    CALL require(swing_n > 1.0e3_wp, 'kN-scale-wave-swing')
    CALL require(mean_err < MEAN_RTOL, 'mean-within-2pct')
    CALL require(swing_err < SWING_RTOL, 'swing-within-15pct')

    ! the same scoring on the FairTen channel (the line-end force on the fairlead)
    mean_n = 0.0_wp; fmin = HUGE(1.0_wp); fmax = -HUGE(1.0_wp); n_steady = 0
    DO step = 1, nstep
      IF (REAL(step, wp)*DT >= steady_start - 1.0e-12_wp) THEN
        mean_n = mean_n + chan_trace(step)
        fmin = MIN(fmin, chan_trace(step))
        fmax = MAX(fmax, chan_trace(step))
        n_steady = n_steady + 1
      END IF
    END DO
    mean_n = mean_n/REAL(n_steady, wp)
    swing_n = fmax - fmin
    mean_err = ABS(mean_n - ORCA_MEAN_N)/ORCA_MEAN_N
    swing_err = ABS(swing_n - ORCA_SWING_N)/ORCA_SWING_N
    WRITE (*, '(A,F9.3,A,F7.3,A,F9.3,A,F7.3,A)') 'L3-2 FairTen channel vs OrcaFlex: mean=', mean_n/1.0e3_wp, &
      ' kN (err ', 100.0_wp*mean_err, '%), swing=', swing_n/1.0e3_wp, ' kN (err ', 100.0_wp*swing_err, '%)'
    CALL require(mean_err < MEAN_RTOL, 'FairTen-channel-mean-within-2pct')
    CALL require(swing_err < SWING_RTOL, 'FairTen-channel-swing-within-15pct')

    DEALLOCATE (conn, l0, ea, mpl, diam, kn, w, f_ext, load, q0, q, tension, q_wave_ref, &
                fixed, v, a, q_new, v_new, a_new, fair_trace, chan_trace, fint_c, fhyd)
  END SUBROUTINE run_wave_cell

  ! --- composed dynamic load: penalty seabed + Morison drag + Froude-Krylov + buoyancy ---

  SUBROUTINE wave_load(q_in, v_in, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Quasi-Newton: exact external force residual, zero dense hydro Jacobians (the
    !! structural tangent + added mass dominate convergence -- the same choice the
    !! L2-2 parity gate makes).
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    jac_q = 0.0_wp
    jac_v = 0.0_wp
    CALL wave_force(q_in, v_in, force, ErrStat, ErrMsg)
  END SUBROUTINE wave_load

  SUBROUTINE wave_force(q_in, v_in, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: u(3, NN), udot(3, NN), waterline(NN)
    REAL(wp) :: fd(NDOF), kdq(NDOF, NDOF)
    REAL(wp) :: q2(6), v2(6), u2(3, 2), udot2(3, 2), wl2(2), fd2(6), l02(1)
    INTEGER :: e, a_nd, b_nd, conn2(2, 1)
    force = 0.0_wp
    CALL build_wave_fields(u, udot, waterline, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL CD_Seabed_Penalty_Load(reshape3_state(q_in), kn, SEABED_Z, fd, kdq, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    force = force + fd
    conn2(:, 1) = [1, 2]
    DO e = 1, NE
      a_nd = conn(1, e)
      b_nd = conn(2, e)
      q2(1:3) = q_in(3*a_nd - 2:3*a_nd)
      q2(4:6) = q_in(3*b_nd - 2:3*b_nd)
      v2(1:3) = v_in(3*a_nd - 2:3*a_nd)
      v2(4:6) = v_in(3*b_nd - 2:3*b_nd)
      u2(:, 1) = u(:, a_nd); u2(:, 2) = u(:, b_nd)
      udot2(:, 1) = udot(:, a_nd); udot2(:, 2) = udot(:, b_nd)
      wl2 = [waterline(a_nd), waterline(b_nd)]
      l02 = [l0(e)]

      CALL CD_Cable_Morison_Drag_Force(q2, v2, conn2, l02, u2, wl2, &
                                       RHO, diam(e), CDN, CDT, fd2, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      CALL scatter_elem_force(fd2, a_nd, b_nd, force)

      CALL CD_Cable_Froude_Krylov_Force(q2, v2, conn2, l02, udot2, wl2, &
                                        RHO, diam(e), CAN, CAT, fd2, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      CALL scatter_elem_force(fd2, a_nd, b_nd, force)

      CALL CD_Cable_Buoyancy_Recovery_Force(q2, v2, conn2, l02, wl2, &
                                            RHO, diam(e), GRAV, fd2, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      CALL scatter_elem_force(fd2, a_nd, b_nd, force)
    END DO
  END SUBROUTINE wave_force

  SUBROUTINE wave_added_mass(q_in, accel, M_add, dMa_a_dq, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), accel(:)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: u(3, NN), udot(3, NN), waterline(NN)
    REAL(wp) :: q2(6), wl2(2), M2(6, 6), l02(1)
    INTEGER :: e, a_nd, b_nd, conn2(2, 1)
    IF (SIZE(accel) /= SIZE(q_in)) THEN
      ErrStat = 1
      ErrMsg = 'wave_added_mass: acceleration and position sizes differ'
      RETURN
    END IF
    M_add = 0.0_wp
    conn2(:, 1) = [1, 2]
    CALL build_wave_fields(u, udot, waterline, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    DO e = 1, NE
      a_nd = conn(1, e)
      b_nd = conn(2, e)
      q2(1:3) = q_in(3*a_nd - 2:3*a_nd)
      q2(4:6) = q_in(3*b_nd - 2:3*b_nd)
      wl2 = [waterline(a_nd), waterline(b_nd)]
      l02 = [l0(e)]
      CALL CD_Cable_Added_Mass_Matrix(q2, conn2, l02, wl2, RHO, diam(e), CAN, CAT, M2, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      CALL scatter_elem_matrix(M2, a_nd, b_nd, M_add)
    END DO
    dMa_a_dq = 0.0_wp
  END SUBROUTINE wave_added_mass

  SUBROUTINE build_wave_fields(velocity, acceleration, waterline, ErrStat, ErrMsg)
    !! Airy velocity / acceleration / waterline at the FIXED mean sample positions
    !! q_wave_ref (host-associated), independent of the Newton trial, at t_eval.
    REAL(wp), INTENT(OUT) :: velocity(3, NN), acceleration(3, NN), waterline(NN)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nd, base
    velocity = 0.0_wp
    acceleration = 0.0_wp
    waterline = 0.0_wp
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    DO nd = 1, NN
      base = 3*nd - 2
      CALL CD_Airy_Wave_Kinematics(q_wave_ref(base), q_wave_ref(base + 1), q_wave_ref(base + 2), t_eval, &
                                   WAVE_H, WAVE_T, WATER_DEPTH, GRAV, WAVE_DIR, .TRUE., &
                                   waterline(nd), velocity(:, nd), acceleration(:, nd), ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
    END DO
  END SUBROUTINE build_wave_fields

  SUBROUTINE scatter_elem_force(f_elem, a_nd, b_nd, force)
    REAL(wp), INTENT(IN) :: f_elem(6)
    INTEGER, INTENT(IN) :: a_nd, b_nd
    REAL(wp), INTENT(INOUT) :: force(:)
    force(3*a_nd - 2:3*a_nd) = force(3*a_nd - 2:3*a_nd) + f_elem(1:3)
    force(3*b_nd - 2:3*b_nd) = force(3*b_nd - 2:3*b_nd) + f_elem(4:6)
  END SUBROUTINE scatter_elem_force

  SUBROUTINE scatter_elem_matrix(M_elem, a_nd, b_nd, M_global)
    REAL(wp), INTENT(IN) :: M_elem(6, 6)
    INTEGER, INTENT(IN) :: a_nd, b_nd
    REAL(wp), INTENT(INOUT) :: M_global(:, :)
    INTEGER :: map(6), ii, jj
    map = [3*a_nd - 2, 3*a_nd - 1, 3*a_nd, 3*b_nd - 2, 3*b_nd - 1, 3*b_nd]
    DO jj = 1, 6
      DO ii = 1, 6
        M_global(map(ii), map(jj)) = M_global(map(ii), map(jj)) + M_elem(ii, jj)
      END DO
    END DO
  END SUBROUTINE scatter_elem_matrix

  FUNCTION reshape3(q_in) RESULT(nodes)
    REAL(wp), INTENT(IN) :: q_in(NDOF)
    REAL(wp) :: nodes(3, NN)
    nodes = RESHAPE(q_in, [3, NN])
  END FUNCTION reshape3

  FUNCTION reshape3_state(q_in) RESULT(nodes)
    REAL(wp), INTENT(IN) :: q_in(:)
    REAL(wp) :: nodes(3, NN)
    nodes = RESHAPE(q_in, [3, NN])
  END FUNCTION reshape3_state

  SUBROUTINE require(cond, lbl)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: lbl
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', lbl, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_orcaflex_wave_dynamic
