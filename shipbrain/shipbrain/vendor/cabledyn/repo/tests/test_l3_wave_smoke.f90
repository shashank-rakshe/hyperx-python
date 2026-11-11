! File: tests/test_l3_wave_smoke.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_wave_smoke
  !! Fortran regular-wave dynamic smoke for the EI=0 cable path. This is the
  !! first self-contained src/ bridge from Airy wave kinematics to in-loop
  !! Morison drag, Froude-Krylov / fluid inertia, wetting correction, and Morison
  !! added mass through CD_Cable_Gen_Alpha_Step. It corresponds to the dynamic
  !! load set in ARCHITECTURE.md and exercises the L3-2 dynamic-bridge
  !! wiring (OrcaFlex parity and the deck-driver path are gated in the L3-2 tests).
  !!
  !! References:
  !! * The Morison normal/tangential decomposition of the line loads.
  !! * Dean & Dalrymple (1991), linear Airy wave theory.
  !! * Wheeler (1970), vertical stretching through the splash zone.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_Cable_Gen_Alpha_Step, &
                              CD_Cable_Initial_Acceleration, CD_DYN_OK
  USE CableDyn_Hydro, ONLY: CD_Airy_Wave_Kinematics, CD_Cable_Morison_Drag_Load, &
                            CD_Cable_Froude_Krylov_Load, CD_Cable_Buoyancy_Recovery_Load, &
                            CD_Cable_Added_Mass, CD_HYDRO_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 8, NN = NE + 1, NDOF = 3*NN, NSTEP = 32
  REAL(wp), PARAMETER :: SPAN = 100.0_wp, Z0 = -15.0_wp, PRESTRETCH = 0.005_wp
  REAL(wp), PARAMETER :: EA0 = 1.0e7_wp, RHO_A0 = 50.0_wp
  REAL(wp), PARAMETER :: RHO_W = 1025.0_wp, DIAM = 0.252_wp, GRAV = 9.80665_wp
  REAL(wp), PARAMETER :: CDN = 1.37_wp, CDT = 0.64_wp, CAN = 1.0_wp, CAT = 0.0_wp
  REAL(wp), PARAMETER :: WATER_DEPTH = 50.0_wp, WAVE_HEIGHT = 3.0_wp, WAVE_PERIOD = 8.0_wp
  REAL(wp), PARAMETER :: WAVE_DIR = 0.0_wp, DT = 0.025_wp

  INTEGER :: nfail, conn(2, NE), fixed(6), es, n_iter, i, step
  REAL(wp) :: l0(NE), ea(NE), rho_a(NE), f_ext(NDOF)
  REAL(wp) :: q(NDOF), v(NDOF), a(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF)
  REAL(wp) :: q_start(NDOF), q_wave_ref(NDOF), vnorm_max, disp_norm, wave_time
  LOGICAL :: converged, stalled
  TYPE(GenAlphaConfig) :: cfg
  CHARACTER(160) :: em

  nfail = 0
  f_ext = 0.0_wp
  cfg%abs_tol = 1.0e-7_wp
  cfg%rel_tol = 1.0e-8_wp
  cfg%max_iter = 12

  DO i = 1, NE
    conn(1, i) = i
    conn(2, i) = i + 1
    l0(i) = (SPAN/REAL(NE, wp))/(1.0_wp + PRESTRETCH)
    ea(i) = EA0
    rho_a(i) = RHO_A0
  END DO
  DO i = 1, NN
    q(3*i - 2) = REAL(i - 1, wp)*SPAN/REAL(NE, wp)
    q(3*i - 1) = 0.0_wp
    q(3*i) = Z0
  END DO
  v = 0.0_wp
  fixed = [1, 2, 3, NDOF - 2, NDOF - 1, NDOF]
  q_start = q
  ! wave field sampled at the fixed mean (initial) positions -> consistent tangent
  q_wave_ref = q_start

  wave_time = 0.0_wp
  CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a, es, em, &
                                     load_proc=wave_load, added_mass_proc=wave_added_mass)
  CALL require(es == CD_DYN_OK, 'wave-smoke:a0-ErrStat')
  CALL require(NORM2(a(4:NDOF - 3)) > 1.0e-8_wp, 'wave-smoke:wave-load-drives-free-dofs')

  vnorm_max = 0.0_wp
  DO step = 1, NSTEP
    ! gen-alpha intermediate force time t_alpha = t_n + (1 - alpha_f) dt
    wave_time = REAL(step - 1, wp)*DT + (1.0_wp - cfg%rho_inf/(cfg%rho_inf + 1.0_wp))*DT
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 DT, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em, &
                                 load_proc=wave_load, added_mass_proc=wave_added_mass)
    CALL require(es == CD_DYN_OK .AND. converged .AND. .NOT. stalled, 'wave-smoke:step-converged')
    q = q_new
    v = v_new
    a = a_new
    vnorm_max = MAX(vnorm_max, NORM2(v(4:NDOF - 3)))
  END DO

  disp_norm = NORM2(q(4:NDOF - 3) - q_start(4:NDOF - 3))
  CALL require(vnorm_max > 1.0e-7_wp, 'wave-smoke:velocity-response')
  CALL require(disp_norm > 1.0e-8_wp, 'wave-smoke:displacement-response')
  CALL require(nan_max_abs(q(fixed) - q_start(fixed)) < 1.0e-13_wp, 'wave-smoke:fixed-endpoints')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A,ES12.4,A,ES12.4)') 'PASS: Fortran wave dynamic smoke, max |v_free| = ', &
    vnorm_max, ', |dq_free| = ', disp_norm

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE wave_load(q_in, v_in, force, jac_q, jac_v, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: u(3, NN), udot(3, NN), waterline(NN)
    REAL(wp) :: fd(NDOF), kdq(NDOF, NDOF), kdv(NDOF, NDOF)

    force = 0.0_wp
    jac_q = 0.0_wp
    jac_v = 0.0_wp
    CALL build_wave_fields(u, udot, waterline, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN

    CALL CD_Cable_Morison_Drag_Load(q_in, v_in, conn, l0, u, waterline, &
                                    RHO_W, DIAM, CDN, CDT, fd, kdq, kdv, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    force = force + fd
    jac_q = jac_q + kdq
    jac_v = jac_v + kdv

    CALL CD_Cable_Froude_Krylov_Load(q_in, v_in, conn, l0, udot, waterline, &
                                     RHO_W, DIAM, CAN, CAT, fd, kdq, kdv, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    force = force + fd
    jac_q = jac_q + kdq
    jac_v = jac_v + kdv

    CALL CD_Cable_Buoyancy_Recovery_Load(q_in, v_in, conn, l0, waterline, &
                                         RHO_W, DIAM, GRAV, fd, kdq, kdv, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    force = force + fd
    jac_q = jac_q + kdq
    jac_v = jac_v + kdv
  END SUBROUTINE wave_load

  SUBROUTINE wave_added_mass(q_in, accel, M_add, dMa_a_dq, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), accel(:)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: u(3, NN), udot(3, NN), waterline(NN)

    CALL build_wave_fields(u, udot, waterline, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL CD_Cable_Added_Mass(q_in, accel, conn, l0, waterline, RHO_W, DIAM, CAN, CAT, &
                             M_add, dMa_a_dq, ErrStat, ErrMsg)
  END SUBROUTINE wave_added_mass

  SUBROUTINE build_wave_fields(velocity, acceleration, waterline, ErrStat, ErrMsg)
    !! Wave field at the FIXED mean sample positions q_wave_ref (host-associated),
    !! not the Newton trial q -- keeps the hydro effective tangent consistent.
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
      CALL CD_Airy_Wave_Kinematics(q_wave_ref(base), q_wave_ref(base + 1), q_wave_ref(base + 2), wave_time, &
                                   WAVE_HEIGHT, WAVE_PERIOD, WATER_DEPTH, GRAV, WAVE_DIR, .TRUE., &
                                   waterline(nd), velocity(:, nd), acceleration(:, nd), ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
    END DO
  END SUBROUTINE build_wave_fields

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_wave_smoke
