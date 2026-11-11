! File: tests/test_cable_dynamic.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_cable_dynamic
  !! Unit tests for CableDyn_Dynamic -- the base positions-only EI=0 generalized-alpha
  !! step (no hydro / damping / contact / prescribed motion). Cross-validated against
  !! an independent generalized-alpha step computation:
  !!   1. zero-load fixed-fixed taut line is a fixed point
  !!   2. a single stretched free node oscillates at the analytical axial period
  !!   3. one step matches the reference q/v/a to the float64 floor
  !!   4. fixed DOFs are returned exactly fixed
  !!   5. invalid dt / config / fixed_dofs fail closed
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Loads, ONLY: CD_Assemble_Distributed_Load
  USE CableDyn_Assemble, ONLY: CD_Assemble_Cable_Mass
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_CableGenAlphaWorkspace, CD_Cable_Gen_Alpha_Step, &
                              CD_Cable_Initial_Acceleration, CD_DYN_OK, CD_DYN_BADINPUT
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  INTEGER :: nfail
  REAL(wp) :: callback_force(9)
  REAL(wp) :: callback_mass(9, 9)
  REAL(wp) :: callback_kq, callback_cv
  INTEGER :: callback_tangent_count, callback_force_count
  nfail = 0
  callback_force = 0.0_wp
  callback_mass = 0.0_wp
  callback_kq = 0.0_wp
  callback_cv = 0.0_wp
  callback_tangent_count = 0
  callback_force_count = 0

  CALL case_fixed_point()
  CALL case_axial_period()
  CALL case_reference_one_step()
  CALL case_dynamic_load_callback_matches_fext()
  CALL case_banded_load_callback_matches_dense()
  CALL case_workspace_matches_legacy_step()
  CALL case_workspace_mass_band_follows_inputs()
  CALL case_modified_newton_reuses_tangent()
  CALL case_line_search_fallback_handles_bad_tangent()
  CALL case_added_mass_callback_changes_initial_acceleration()
  CALL case_preassembled_mass_matches_internal_assembly()
  CALL case_preassembled_mass_rejects_offband_entries()
  CALL case_banded_added_mass_honors_structural_mass()
  CALL case_banded_dense_callback_mix_rejected()
  CALL case_junction_tangent_after_allowance_exit()
  CALL case_fixed_dofs_held()
  CALL case_fail_closed()
  CALL case_failure_returns_input_state()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_Dynamic matches the independent reference values'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE expect(got, want, label)
    REAL(wp), INTENT(IN) :: got, want
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), PARAMETER :: atol = 1.0e-8_wp, rtol = 1.0e-9_wp
    IF (.NOT. (ABS(got - want) <= atol + rtol*ABS(want))) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE expect_es(es, want, label)
    INTEGER, INTENT(IN) :: es, want
    CHARACTER(*), INTENT(IN) :: label
    IF (es /= want) THEN
      WRITE (*, '(A,A,A,I0,A,I0)') 'MISMATCH [', label, ']: ErrStat ', es, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect_es

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE three_node_chain(conn, l0, ea, rho_a, q0)
    !! span-2 taut line: 3 nodes along x, 2 elements, 10% pre-stretch (L0 = 0.9).
    INTEGER, INTENT(OUT) :: conn(2, 2)
    REAL(wp), INTENT(OUT) :: l0(2), ea(2), rho_a(2), q0(9)
    INTEGER :: i
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    l0 = [0.9_wp, 0.9_wp]
    ea = [1000.0_wp, 1000.0_wp]
    rho_a = [5.0_wp, 5.0_wp]
    q0 = 0.0_wp
    DO i = 1, 3
      q0(3*i - 2) = REAL(i - 1, wp)   ! x = 0,1,2 ; y = z = 0
    END DO
  END SUBROUTINE three_node_chain

  SUBROUTINE case_fixed_point()
    !! A taut line with both ends fully fixed, no external load and at rest, stays
    !! put: the interior internal forces cancel, so one step reproduces the state.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9)
    REAL(wp) :: q(9), v(9), a(9), q_new(9), v_new(9), a_new(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    f_ext = 0.0_wp
    q = q0; v = 0.0_wp; a = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_OK, 'fixedpt:ErrStat')
    CALL require(converged, 'fixedpt:converged')
    CALL require(.NOT. stalled, 'fixedpt:not-stalled')
    DO i = 1, 9
      CALL expect(q_new(i), q0(i), 'fixedpt:q-unchanged')
      CALL expect(v_new(i), 0.0_wp, 'fixedpt:v-zero')
      CALL expect(a_new(i), 0.0_wp, 'fixedpt:a-zero')
    END DO
  END SUBROUTINE case_fixed_point

  SUBROUTINE case_axial_period()
    !! A single element with node 1 fully fixed and node 2 free ONLY along x is an
    !! exact linear axial SDOF: M_BB xddot + (EA/L0)(x - L0) = 0 with the consistent
    !! free-node mass M_BB = rho_a L0 / 3, so omega^2 = 3 EA / (rho_a L0^2). Stretched
    !! by A and released, after one analytical period T = 2 pi / omega the node
    !! returns to its start (the generalized-alpha dissipation at rho_inf = 0.8 is
    !! ~1e-6/period), and at the half period it has crossed to the far side. This
    !! gates the period against the closed form, NOT just reference parity.
    INTEGER  :: conn(2, 1), fixed(5), es, n_iter, step, i
    REAL(wp) :: l0(1), ea(1), rho_a(1), f_ext(6)
    REAL(wp) :: q(6), v(6), a(6), q_new(6), v_new(6), a_new(6)
    REAL(wp) :: omega, period, dt, x0, x_half
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
    REAL(wp), PARAMETER :: AMP = 0.01_wp
    INTEGER, PARAMETER :: NSTEP = 100
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]; ea = [1000.0_wp]; rho_a = [4.0_wp]
    omega = SQRT(3.0_wp*ea(1)/(rho_a(1)*l0(1)**2))
    period = 2.0_wp*PI/omega
    dt = period/REAL(NSTEP, wp)
    ! node1 at origin (fully fixed); node2 at x = L0 + AMP, free only in x (y,z fixed)
    q = 0.0_wp
    q(4) = l0(1) + AMP
    v = 0.0_wp
    f_ext = 0.0_wp
    fixed = [1, 2, 3, 5, 6]
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a, es, em)
    CALL expect_es(es, CD_DYN_OK, 'period:a0-ErrStat')
    CALL expect(a(4), -7.5_wp, 'period:a0-x')          ! -(EA/L0)A / M_BB = -1000*0.01/(4/3)
    x0 = q(4) - l0(1)
    x_half = 0.0_wp
    DO step = 1, NSTEP
      CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                   dt, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
      CALL expect_es(es, CD_DYN_OK, 'period:step-ErrStat')
      CALL require(converged, 'period:step-converged')
      q = q_new; v = v_new; a = a_new
      IF (step == NSTEP/2) x_half = q(4) - l0(1)
    END DO
    ! one full analytical period recovers the start (period is correct)
    CALL require(ABS((q(4) - l0(1)) - x0)/AMP < 1.0e-3_wp, 'period:recovers-after-T')
    ! half a period puts the node on the far side, past equilibrium
    CALL require(x_half < -0.5_wp*AMP, 'period:far-side-at-half')
    ! every DOF but node 2's x stays at zero (pure axial motion)
    DO i = 1, 6
      IF (i /= 4) CALL expect(q(i), 0.0_wp, 'period:no-transverse')
    END DO
  END SUBROUTINE case_axial_period

  SUBROUTINE case_reference_one_step()
    !! One generalized-alpha step of a taut 3-node chain under gravity (node 2 free,
    !! ends fixed) reproduces the reference q/v/a to the float64 floor, for the force blend
    !! (the default) and the configuration blend. The references solve the same step for
    !! the middle node's z in 40-digit decimal arithmetic: G(z) = M a_alpha + f(z) - F with
    !! f the force blend (1 - af) f_z(q_{n+1}) + af f_z(q_n) or the configuration blend
    !! f_z((1 - af) q_{n+1} + af q_n), rho_inf = 0.8, dt = 0.01, from rest with a0 = -15.
    !! The tight tolerance keeps the Newton error below the reference precision.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, i, k
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), load(3, 2)
    REAL(wp) :: q(9), v(9), a(9), q_new(9), v_new(9), a_new(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    REAL(wp), PARAMETER :: want_z(2) = [-7.4857381553276945e-4_wp, -7.4857381801437368e-4_wp]
    REAL(wp), PARAMETER :: want_vz(2) = [-0.149717615475488341_wp, -0.149717615966845990_wp]
    REAL(wp), PARAMETER :: want_az(2) = [-14.95379162326173_wp, -14.95379170366571_wp]
    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 2)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL expect_es(es, 0, 'reference:fext-ErrStat')
    fixed = [1, 2, 3, 7, 8, 9]
    cfg%rel_tol = 1.0e-14_wp
    DO k = 1, 2
      cfg%force_blend = k == 1
      q = q0; v = 0.0_wp
      CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a, es, em)
      CALL expect_es(es, CD_DYN_OK, 'reference:a0-ErrStat')
      CALL expect(a(6), -15.0_wp, 'reference:a0-z')
      CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                   0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
      CALL expect_es(es, CD_DYN_OK, 'reference:step-ErrStat')
      CALL require(converged, 'reference:converged')
      DO i = 1, 9
        IF (i == 6) CYCLE
        CALL expect(q_new(i), q0(i), 'reference:q-held')
        CALL expect(v_new(i), 0.0_wp, 'reference:v-held')
        CALL expect(a_new(i), 0.0_wp, 'reference:a-held')
      END DO
      CALL expect(q_new(6), want_z(k), 'reference:q')
      CALL expect(v_new(6), want_vz(k), 'reference:v')
      CALL expect(a_new(6), want_az(k), 'reference:a')
    END DO
  END SUBROUTINE case_reference_one_step

  SUBROUTINE case_dynamic_load_callback_matches_fext()
    !! A constant dynamic-load callback with zero Jacobians is algebraically
    !! equivalent to passing the same vector as f_ext. This gates the optional
    !! in-loop load hook without introducing hydro-specific physics into the
    !! base dynamic test.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), zero_ext(9), load(3, 2)
    REAL(wp) :: q(9), v(9), a_ref(9), a_cb(9), a_force(9), q_ref(9), v_ref(9), q_cb(9), v_cb(9)
    REAL(wp) :: q_force(9), v_force(9), anew_ref(9), anew_cb(9), anew_force(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 2)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL expect_es(es, 0, 'callback:fext-ErrStat')
    zero_ext = 0.0_wp
    q = q0
    v = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]

    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a_ref, es, em)
    CALL expect_es(es, CD_DYN_OK, 'callback:a-ref')
    callback_force = f_ext
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, a_cb, es, em, &
                                       load_proc=constant_load)
    CALL expect_es(es, CD_DYN_OK, 'callback:a-cb')
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, a_force, es, em, &
                                       load_force_proc=constant_force_only)
    CALL expect_es(es, CD_DYN_OK, 'callback:a-force-only')

    CALL CD_Cable_Gen_Alpha_Step(q, v, a_ref, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_ref, v_ref, anew_ref, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_OK, 'callback:step-ref')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a_cb, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q_cb, v_cb, anew_cb, converged, stalled, n_iter, es, em, &
                                 load_proc=constant_load)
    CALL expect_es(es, CD_DYN_OK, 'callback:step-cb')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a_force, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q_force, v_force, anew_force, converged, stalled, n_iter, es, em, &
                                 load_proc=constant_load, load_force_proc=constant_force_only)
    CALL expect_es(es, CD_DYN_OK, 'callback:step-force-only')
    DO i = 1, 9
      CALL expect(a_cb(i), a_ref(i), 'callback:a-match')
      CALL expect(a_force(i), a_ref(i), 'callback:a-force-match')
      CALL expect(q_cb(i), q_ref(i), 'callback:q-match')
      CALL expect(q_force(i), q_ref(i), 'callback:q-force-match')
      CALL expect(v_cb(i), v_ref(i), 'callback:v-match')
      CALL expect(v_force(i), v_ref(i), 'callback:v-force-match')
      CALL expect(anew_cb(i), anew_ref(i), 'callback:anew-match')
      CALL expect(anew_force(i), anew_ref(i), 'callback:anew-force-match')
    END DO

  END SUBROUTINE case_dynamic_load_callback_matches_fext

  SUBROUTINE case_banded_load_callback_matches_dense()
    !! A reduced-band dynamic-load callback must produce the same Newton step as
    !! the dense callback for the same force and residual Jacobian. This gates the
    !! production model path that scatters local hydro/damping Jacobians directly
    !! into LAPACK band storage.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), zero_ext(9)
    REAL(wp) :: q(9), v(9), a0(9), q_dense(9), v_dense(9), a_dense(9)
    REAL(wp) :: q_band(9), v_band(9), a_band(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    fixed = [1, 2, 3, 7, 8, 9]
    f_ext = 0.0_wp
    zero_ext = 0.0_wp
    q = q0
    q(6) = -0.05_wp
    v = 0.0_wp
    v(6) = -0.1_wp
    callback_kq = 20.0_wp
    callback_cv = 3.0_wp

    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a0, es, em, &
                                       load_proc=dense_linear_load)
    CALL expect_es(es, CD_DYN_OK, 'band-load:a0')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q_dense, v_dense, a_dense, converged, stalled, n_iter, es, em, &
                                 load_proc=dense_linear_load, load_force_proc=linear_force_only)
    CALL expect_es(es, CD_DYN_OK, 'band-load:dense-step')
    CALL require(converged .AND. .NOT. stalled, 'band-load:dense-converged')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q_band, v_band, a_band, converged, stalled, n_iter, es, em, &
                                 load_force_proc=linear_force_only, load_band_proc=banded_linear_load)
    CALL expect_es(es, CD_DYN_OK, 'band-load:band-step')
    CALL require(converged .AND. .NOT. stalled, 'band-load:band-converged')
    DO i = 1, 9
      CALL expect(q_band(i), q_dense(i), 'band-load:q')
      CALL expect(v_band(i), v_dense(i), 'band-load:v')
      CALL expect(a_band(i), a_dense(i), 'band-load:a')
    END DO
  END SUBROUTINE case_banded_load_callback_matches_dense

  SUBROUTINE case_workspace_matches_legacy_step()
    !! Optional reusable workspace must be a storage optimization only: direct
    !! callers get the same q/v/a as the legacy self-contained allocation path.
    INTEGER :: conn(2, 2), fixed(6), es, n_iter, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), q(9), v(9)
    REAL(wp) :: a_legacy(9), a_work(9), q_legacy(9), v_legacy(9), anew_legacy(9)
    REAL(wp) :: q_work(9), v_work(9), anew_work(9)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    TYPE(CD_CableGenAlphaWorkspace) :: work
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    fixed = [1, 2, 3, 7, 8, 9]
    f_ext = 0.0_wp
    f_ext(6) = -15.0_wp
    q = q0
    q(6) = -0.04_wp
    v = 0.0_wp
    v(6) = -0.05_wp

    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                       a_legacy, es, em)
    CALL expect_es(es, CD_DYN_OK, 'workspace:a-legacy')
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                       a_work, es, em, workspace=work)
    CALL expect_es(es, CD_DYN_OK, 'workspace:a-work')
    ! The element-band route keeps O(n_dof * bandwidth) scratch only: the dense global
    ! mass exists solely for a supplied structural mass or a dense added-mass callback.
    CALL require(.NOT. ALLOCATED(work%M) .AND. ALLOCATED(work%M_band) .AND. ALLOCATED(work%R_free), &
                 'workspace:band-only-after-initial')

    CALL CD_Cable_Gen_Alpha_Step(q, v, a_legacy, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_legacy, v_legacy, anew_legacy, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_OK, 'workspace:step-legacy')
    CALL require(converged .AND. .NOT. stalled, 'workspace:legacy-converged')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a_work, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_work, v_work, anew_work, converged, stalled, n_iter, es, em, &
                                 workspace=work)
    CALL expect_es(es, CD_DYN_OK, 'workspace:step-work')
    CALL require(converged .AND. .NOT. stalled, 'workspace:work-converged')
    CALL require(work%n_dof_capacity >= 9 .AND. work%n_free_capacity >= 3, 'workspace:capacity-recorded')
    CALL require(.NOT. ALLOCATED(work%M), 'workspace:no-dense-mass-after-step')
    DO i = 1, 9
      CALL expect(a_work(i), a_legacy(i), 'workspace:a')
      CALL expect(q_work(i), q_legacy(i), 'workspace:q')
      CALL expect(v_work(i), v_legacy(i), 'workspace:v')
      CALL expect(anew_work(i), anew_legacy(i), 'workspace:anew')
    END DO
  END SUBROUTINE case_workspace_matches_legacy_step

  SUBROUTINE case_workspace_mass_band_follows_inputs()
    !! A reusable workspace keeps the element mass band of its last step and reuses it while
    !! the connectivity, free list, l0 and rho_a are unchanged. A change of any of them, or an
    !! initial-acceleration solve (which factors the band in place), rebuilds it: every step
    !! equals the same step through a fresh workspace bit for bit.
    INTEGER :: conn(2, 2), es
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), q(9), v(9), a(9), l0b(2), rhob(2)
    TYPE(CD_CableGenAlphaWorkspace) :: work
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    f_ext = 0.0_wp
    f_ext(6) = -15.0_wp
    q = q0
    q(6) = -0.04_wp
    v = 0.0_wp
    v(6) = -0.05_wp
    a = 0.0_wp
    a(5) = 0.2_wp
    l0b = [0.9_wp, 0.93_wp]
    rhob = [5.0_wp, 6.5_wp]

    ! each step states whether it must reuse the remembered band (the workspace's test-only
    ! hit counter), so a cache that never hits fails here
    CALL mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, [1, 2, 3, 7, 8, 9], .FALSE., &
                             'mass-band:first')
    CALL require(work%mb_valid, 'mass-band:remembered')
    CALL mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, [1, 2, 3, 7, 8, 9], .TRUE., &
                             'mass-band:reused')
    CALL mass_band_step_pair(work, q, v, a, conn, l0b, ea, rho_a, f_ext, [1, 2, 3, 7, 8, 9], .FALSE., &
                             'mass-band:new-l0')
    CALL mass_band_step_pair(work, q, v, a, conn, l0b, ea, rhob, f_ext, [1, 2, 3, 7, 8, 9], .FALSE., &
                             'mass-band:new-rho')
    CALL mass_band_step_pair(work, q, v, a, conn, l0b, ea, rhob, f_ext, [1, 2, 3, 7, 8, 9], .TRUE., &
                             'mass-band:new-rho-reused')
    CALL mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, [1, 2, 3, 7, 8, 9], .FALSE., &
                             'mass-band:back')
    CALL mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, [1, 2, 3], .FALSE., &
                             'mass-band:new-free-list')
    CALL mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, [1, 2, 3], .TRUE., &
                             'mass-band:new-free-list-reused')
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3], &
                                       a, es, em, workspace=work)
    CALL expect_es(es, CD_DYN_OK, 'mass-band:initial-acceleration')
    CALL require(.NOT. work%mb_valid, 'mass-band:initial-acceleration-clears')
    CALL mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, [1, 2, 3], .FALSE., &
                             'mass-band:after-initial-acceleration')
    CALL mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, [1, 2, 3], .TRUE., &
                             'mass-band:after-initial-acceleration-reused')
  END SUBROUTINE case_workspace_mass_band_follows_inputs

  SUBROUTINE mass_band_step_pair(work, q, v, a, conn, l0, ea, rho_a, f_ext, fixed, expect_hit, label)
    !! One step through the shared workspace and the same step through a fresh one; the shared
    !! step reuses the remembered mass band exactly when expect_hit (test-only counter mb_hits).
    TYPE(CD_CableGenAlphaWorkspace), INTENT(INOUT) :: work
    REAL(wp), INTENT(IN) :: q(9), v(9), a(9), l0(2), ea(2), rho_a(2), f_ext(9)
    INTEGER, INTENT(IN) :: conn(2, 2), fixed(:)
    LOGICAL, INTENT(IN) :: expect_hit
    CHARACTER(*), INTENT(IN) :: label
    INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
    TYPE(GenAlphaConfig) :: cfg
    TYPE(CD_CableGenAlphaWorkspace) :: fresh
    REAL(wp) :: q_w(9), v_w(9), a_w(9), q_f(9), v_f(9), a_f(9)
    INTEGER :: es_w, es_f, it_w, it_f, hits
    LOGICAL :: conv_w, conv_f, stall_w, stall_f
    CHARACTER(120) :: em_w, em_f

    hits = work%mb_hits
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, 0.01_wp, cfg, &
                                 q_w, v_w, a_w, conv_w, stall_w, it_w, es_w, em_w, workspace=work)
    CALL require(work%mb_hits == hits + MERGE(1, 0, expect_hit), label//':cache-hit')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, 0.01_wp, cfg, &
                                 q_f, v_f, a_f, conv_f, stall_f, it_f, es_f, em_f, workspace=fresh)
    CALL require(fresh%mb_hits == 0, label//':fresh-no-hit')
    CALL expect_es(es_w, CD_DYN_OK, label//':status')
    CALL require(conv_w .AND. conv_f .AND. it_w == it_f .AND. es_w == es_f, label//':flags')
    CALL require(ALL(TRANSFER(q_w, [0_I8]) == TRANSFER(q_f, [0_I8])) .AND. &
                 ALL(TRANSFER(v_w, [0_I8]) == TRANSFER(v_f, [0_I8])) .AND. &
                 ALL(TRANSFER(a_w, [0_I8]) == TRANSFER(a_f, [0_I8])), label//':bitwise')
  END SUBROUTINE mass_band_step_pair

  SUBROUTINE case_modified_newton_reuses_tangent()
    !! The EI=0 generalized-alpha config advertises modified Newton. It must reuse
    !! the tangent within a step without changing the accepted state.
    INTEGER :: conn(2, 2), fixed(6), es, n_iter, count_full, count_modified, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), zero_ext(9), q(9), v(9), a0(9)
    REAL(wp) :: q_full(9), v_full(9), a_full(9), q_modified(9), v_modified(9), a_modified(9)
    REAL(wp) :: q_band_full(9), v_band_full(9), a_band_full(9), q_band_mod(9), v_band_mod(9), a_band_mod(9)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg, cfg_modified
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    fixed = [1, 2, 3, 7, 8, 9]
    zero_ext = 0.0_wp
    q = q0
    q(6) = -0.05_wp
    v = 0.0_wp
    v(6) = -0.1_wp
    callback_kq = 20.0_wp
    callback_cv = 3.0_wp
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, a0, es, em, &
                                       load_proc=dense_linear_load)
    CALL expect_es(es, CD_DYN_OK, 'mod-newton:a0')

    callback_tangent_count = 0
    callback_force_count = 0
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q_full, v_full, a_full, converged, stalled, n_iter, es, em, &
                                 load_proc=dense_linear_load, load_force_proc=linear_force_only)
    CALL expect_es(es, CD_DYN_OK, 'mod-newton:full-step')
    CALL require(converged .AND. .NOT. stalled, 'mod-newton:full-converged')
    count_full = callback_tangent_count

    cfg_modified = cfg
    cfg_modified%modified_newton = .TRUE.
    callback_tangent_count = 0
    callback_force_count = 0
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg_modified, q_modified, v_modified, a_modified, &
                                 converged, stalled, n_iter, es, em, &
                                 load_proc=dense_linear_load, load_force_proc=linear_force_only)
    CALL expect_es(es, CD_DYN_OK, 'mod-newton:modified-step')
    CALL require(converged .AND. .NOT. stalled, 'mod-newton:modified-converged')
    count_modified = callback_tangent_count
    CALL require(count_modified <= count_full, 'mod-newton:tangent-count-not-higher')
    DO i = 1, 9
      CALL expect(q_modified(i), q_full(i), 'mod-newton:q')
      CALL expect(v_modified(i), v_full(i), 'mod-newton:v')
      CALL expect(a_modified(i), a_full(i), 'mod-newton:a')
    END DO

    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, a0, es, em)
    CALL expect_es(es, CD_DYN_OK, 'mod-newton:band-a0')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q_band_full, v_band_full, a_band_full, &
                                 converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_OK, 'mod-newton:band-full-step')
    CALL require(converged .AND. .NOT. stalled, 'mod-newton:band-full-converged')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg_modified, q_band_mod, v_band_mod, a_band_mod, &
                                 converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_OK, 'mod-newton:band-modified-step')
    CALL require(converged .AND. .NOT. stalled, 'mod-newton:band-modified-converged')
    DO i = 1, 9
      CALL expect(q_band_mod(i), q_band_full(i), 'mod-newton:band-q')
      CALL expect(v_band_mod(i), v_band_full(i), 'mod-newton:band-v')
      CALL expect(a_band_mod(i), a_band_full(i), 'mod-newton:band-a')
    END DO
  END SUBROUTINE case_modified_newton_reuses_tangent

  SUBROUTINE case_line_search_fallback_handles_bad_tangent()
    !! A callback with zero force but a deliberately wrong tangent can make the
    !! Newton direction point uphill. The solver may only recover by accepting a
    !! residual-reducing fallback step; the final physics must match the clean
    !! no-callback gravity step.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), load(3, 2)
    REAL(wp) :: q_ref(9), v_ref(9), a_ref(9), q_bad(9), v_bad(9), a_bad(9)
    REAL(wp) :: q_clean_out(9), v_clean_out(9), a_clean_out(9), q_bad_out(9), v_bad_out(9), a_bad_out(9)
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 2)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL expect_es(es, 0, 'fallback:fext')
    fixed = [1, 2, 3, 7, 8, 9]
    q_ref = q0
    v_ref = 0.0_wp
    CALL CD_Cable_Initial_Acceleration(q_ref, v_ref, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a_ref, es, em)
    CALL expect_es(es, CD_DYN_OK, 'fallback:a-ref')
    q_bad = q_ref
    v_bad = v_ref
    a_bad = a_ref
    cfg%max_iter = 80
    cfg%armijo_max_backtracks = 14
    ! both steps converged far below the comparison tolerance (a = (q - q_pred)/(beta dt^2)
    ! magnifies the Newton error in q by 4e4 at this step)
    cfg%rel_tol = 1.0e-12_wp

    CALL CD_Cable_Gen_Alpha_Step(q_ref, v_ref, a_ref, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_clean_out, v_clean_out, a_clean_out, &
                                 converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_OK, 'fallback:clean-step')
    CALL require(converged .AND. .NOT. stalled, 'fallback:clean-converged')

    callback_kq = -2000.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q_bad, v_bad, a_bad, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_bad_out, v_bad_out, a_bad_out, converged, stalled, n_iter, es, em, &
                                 load_proc=adverse_zero_force_load)
    CALL expect_es(es, CD_DYN_OK, 'fallback:bad-tangent-step')
    CALL require(converged .AND. .NOT. stalled, 'fallback:bad-tangent-converged')
    DO i = 1, 9
      CALL expect(q_bad_out(i), q_clean_out(i), 'fallback:q')
      CALL expect(v_bad_out(i), v_clean_out(i), 'fallback:v')
      CALL expect(a_bad_out(i), a_clean_out(i), 'fallback:a')
    END DO
  END SUBROUTINE case_line_search_fallback_handles_bad_tangent

  SUBROUTINE dense_linear_load(q_in, v_in, force, jac_q, jac_v, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    callback_tangent_count = callback_tangent_count + 1
    force = 0.0_wp
    jac_q = 0.0_wp
    jac_v = 0.0_wp
    force(6) = -callback_kq*q_in(6) - callback_cv*v_in(6)
    jac_q(6, 6) = callback_kq
    jac_v(6, 6) = callback_cv
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE dense_linear_load

  SUBROUTINE linear_force_only(q_in, v_in, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    callback_force_count = callback_force_count + 1
    force = 0.0_wp
    force(6) = -callback_kq*q_in(6) - callback_cv*v_in(6)
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE linear_force_only

  SUBROUTINE banded_linear_load(q_in, v_in, free, kl, ku, force, jac_q_band, jac_v_band, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: j, row
    force = 0.0_wp
    jac_q_band = 0.0_wp
    jac_v_band = 0.0_wp
    force(6) = -callback_kq*q_in(6) - callback_cv*v_in(6)
    DO j = 1, SIZE(free)
      IF (free(j) == 6) THEN
        row = kl + ku + 1
        jac_q_band(row, j) = callback_kq
        jac_v_band(row, j) = callback_cv
      END IF
    END DO
    ErrStat = 0
    ErrMsg = ''
  END SUBROUTINE banded_linear_load

  SUBROUTINE adverse_zero_force_load(q_in, v_in, force, jac_q, jac_v, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    force = 0.0_wp
    jac_q = 0.0_wp
    jac_v = 0.0_wp
    jac_q(6, 6) = callback_kq
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (SIZE(q_in) /= SIZE(v_in) .OR. SIZE(force) /= SIZE(callback_force)) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'bad adverse callback shape'
    END IF
  END SUBROUTINE adverse_zero_force_load

  SUBROUTINE constant_load(q_in, v_in, force, jac_q, jac_v, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    force = callback_force
    jac_q = 0.0_wp
    jac_v = 0.0_wp
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (SIZE(q_in) /= SIZE(v_in) .OR. SIZE(force) /= SIZE(callback_force)) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'bad callback shape'
    END IF
  END SUBROUTINE constant_load

  SUBROUTINE constant_force_only(q_in, v_in, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    force = callback_force
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (SIZE(q_in) /= SIZE(v_in) .OR. SIZE(force) /= SIZE(callback_force)) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'bad force-only callback shape'
    END IF
  END SUBROUTINE constant_force_only

  SUBROUTINE case_added_mass_callback_changes_initial_acceleration()
    !! Added mass augments the mass matrix, not the load vector. Give the free
    !! interior z-DOF an added mass equal to its structural free mass, so the
    !! gravity acceleration halves exactly relative to the no-added-mass solve.
    INTEGER  :: conn(2, 2), fixed(6), es
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), load(3, 2), a_ref(9), a_am(9), v(9)
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 2)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL expect_es(es, 0, 'added-mass:fext-ErrStat')
    fixed = [1, 2, 3, 7, 8, 9]
    v = 0.0_wp
    callback_mass = 0.0_wp
    callback_mass(6, 6) = 3.0_wp
    CALL CD_Cable_Initial_Acceleration(q0, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a_ref, es, em)
    CALL expect_es(es, CD_DYN_OK, 'added-mass:a-ref')
    CALL CD_Cable_Initial_Acceleration(q0, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a_am, es, em, &
                                       added_mass_proc=constant_added_mass)
    CALL expect_es(es, CD_DYN_OK, 'added-mass:a-am')
    CALL expect(a_ref(6), -15.0_wp, 'added-mass:a-ref-z')
    CALL expect(a_am(6), -7.5_wp, 'added-mass:a-halved')
  END SUBROUTINE case_added_mass_callback_changes_initial_acceleration

  SUBROUTINE constant_added_mass(q_in, accel, M_add, dMa_a_dq, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q_in(:), accel(:)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    M_add = callback_mass
    dMa_a_dq = 0.0_wp
    ErrStat = CD_DYN_OK
    ErrMsg = ''
    IF (SIZE(q_in) /= SIZE(accel) .OR. SIZE(M_add, 1) /= SIZE(callback_mass, 1)) THEN
      ErrStat = CD_DYN_BADINPUT
      ErrMsg = 'bad added-mass callback shape'
    END IF
  END SUBROUTINE constant_added_mass

  SUBROUTINE case_preassembled_mass_matches_internal_assembly()
    INTEGER  :: conn(2, 2), fixed(6), es, es2, n_iter, n_iter_ref
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), M(9, 9), bad_M(8, 8)
    REAL(wp) :: q(9), v(9), a(9), q_ref(9), v_ref(9), a_ref(9), q_fast(9), v_fast(9), a_fast(9)
    LOGICAL  :: converged, stalled, converged_ref, stalled_ref
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    fixed = [1, 2, 3, 7, 8, 9]
    f_ext = 0.0_wp
    f_ext(5) = -0.25_wp
    q = q0
    q(5) = 0.05_wp
    v = 0.0_wp
    v(5) = -0.02_wp
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a, es, em)
    CALL expect_es(es, CD_DYN_OK, 'premass:init-accel')
    CALL CD_Assemble_Cable_Mass(conn, l0, rho_a, M, es, em)
    CALL expect_es(es, 0, 'premass:assemble')

    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_ref, v_ref, a_ref, converged_ref, stalled_ref, &
                                 n_iter_ref, es, em)
    CALL expect_es(es, CD_DYN_OK, 'premass:reference-step')
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_fast, v_fast, a_fast, converged, stalled, n_iter, es, em, &
                                 structural_mass=M)
    CALL expect_es(es, CD_DYN_OK, 'premass:fast-step')
    CALL require(converged .EQV. converged_ref, 'premass:converged-match')
    CALL require(stalled .EQV. stalled_ref, 'premass:stalled-match')
    CALL require(n_iter == n_iter_ref, 'premass:niter-match')
    CALL require(nan_max_abs(q_fast - q_ref) < 1.0e-13_wp, 'premass:q-match')
    CALL require(nan_max_abs(v_fast - v_ref) < 1.0e-13_wp, 'premass:v-match')
    CALL require(nan_max_abs(a_fast - a_ref) < 1.0e-13_wp, 'premass:a-match')

    bad_M = 0.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_fast, v_fast, a_fast, converged, stalled, n_iter, es2, em, &
                                 structural_mass=bad_M)
    CALL expect_es(es2, CD_DYN_BADINPUT, 'premass:bad-shape-rejected')
  END SUBROUTINE case_preassembled_mass_matches_internal_assembly

  SUBROUTINE case_preassembled_mass_rejects_offband_entries()
    !! A caller-supplied structural_mass is dense by type, but the direct DGBSV
    !! path only represents the element-connectivity free/free band. Nonzero
    !! entries outside that reduced band must fail closed instead of being
    !! silently discarded during packing.
    INTEGER  :: conn(2, 4), fixed(6), es, n_iter, i
    REAL(wp) :: l0(4), ea(4), rho_a(4), q0(15), f_ext(15), M(15, 15)
    REAL(wp) :: q(15), v(15), a(15), q_new(15), v_new(15), a_new(15)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2, 2, 3, 3, 4, 4, 5], [2, 4])
    l0 = 0.9_wp
    ea = 1000.0_wp
    rho_a = 5.0_wp
    q0 = 0.0_wp
    DO i = 1, 5
      q0(3*i - 2) = REAL(i - 1, wp)
    END DO
    fixed = [1, 2, 3, 13, 14, 15]
    f_ext = 0.0_wp
    q = q0
    v = 0.0_wp
    CALL CD_Assemble_Cable_Mass(conn, l0, rho_a, M, es, em)
    CALL expect_es(es, 0, 'premass-offband:assemble')
    M(4, 12) = 1.0e-3_wp
    M(12, 4) = 1.0e-3_wp

    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a, es, em, &
                                       structural_mass=M)
    CALL expect_es(es, CD_DYN_BADINPUT, 'premass-offband:init-reject')

    a = 0.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em, &
                                 structural_mass=M)
    CALL expect_es(es, CD_DYN_BADINPUT, 'premass-offband:step-reject')
  END SUBROUTINE case_preassembled_mass_rejects_offband_entries

  SUBROUTINE case_banded_added_mass_honors_structural_mass()
    !! Regression: with a banded added-mass callback AND a supplied structural_mass
    !! that differs from the element consistent mass, the residual must use the
    !! supplied mass (matching the tangent's M_band), NOT recompute element inertia.
    !! A zero added-mass band proc + structural_mass = 1.5x the element mass must
    !! reproduce the dense structural_mass step. Before the fix the banded residual
    !! used element mass while the Jacobian honored structural_mass, so this diverged.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), M(9, 9)
    REAL(wp) :: q(9), v(9), a0(9), q_ref(9), v_ref(9), a_ref(9)
    REAL(wp) :: q_band(9), v_band(9), a_band(9)
    LOGICAL  :: converged, stalled, converged_ref, stalled_ref
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    fixed = [1, 2, 3, 7, 8, 9]
    f_ext = 0.0_wp
    f_ext(5) = -0.25_wp
    q = q0
    q(5) = 0.05_wp
    v = 0.0_wp
    v(5) = -0.02_wp
    CALL CD_Assemble_Cable_Mass(conn, l0, rho_a, M, es, em)
    CALL expect_es(es, 0, 'bandam:assemble')
    M = 1.5_wp*M   ! band-representable but distinct from the element consistent mass
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a0, es, em)
    CALL expect_es(es, CD_DYN_OK, 'bandam:a0')

    ! reference: dense structural_mass residual (uses MATMUL(M, a))
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_ref, v_ref, a_ref, converged_ref, stalled_ref, n_iter, es, em, &
                                 structural_mass=M)
    CALL expect_es(es, CD_DYN_OK, 'bandam:dense-step')
    CALL require(converged_ref .AND. .NOT. stalled_ref, 'bandam:dense-converged')

    ! banded added-mass path (zero added mass) with the same structural_mass
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_band, v_band, a_band, converged, stalled, n_iter, es, em, &
                                 structural_mass=M, added_mass_band_proc=zero_added_mass_band)
    CALL expect_es(es, CD_DYN_OK, 'bandam:band-step')
    CALL require(converged .AND. .NOT. stalled, 'bandam:band-converged')
    DO i = 1, 9
      CALL expect(q_band(i), q_ref(i), 'bandam:q')
      CALL expect(v_band(i), v_ref(i), 'bandam:v')
      CALL expect(a_band(i), a_ref(i), 'bandam:a')
    END DO
  END SUBROUTINE case_banded_added_mass_honors_structural_mass

  SUBROUTINE zero_added_mass_band(q, accel, free, kl, ku, M_add_a, M_add_band, dMa_a_dq_band, &
                                  ErrStat, ErrMsg, need_tangent)
    !! A banded added-mass callback that contributes zero added mass, so the dynamics
    !! reduce to the supplied structural_mass alone (the regression reference).
    REAL(wp), INTENT(IN) :: q(:), accel(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: M_add_a(:), M_add_band(:, :), dMa_a_dq_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: need_tangent
    M_add_a = 0.0_wp
    M_add_band = 0.0_wp
    dMa_a_dq_band = 0.0_wp
    ErrStat = 0
    ErrMsg = ''
    ! Zero callback: it consumes none of the kinematic/band inputs, so reference the
    ! interface-mandated dummies here to keep the -Wextra unused-dummy gate clean.
    IF (SIZE(q) < 0 .OR. SIZE(accel) < 0 .OR. SIZE(free) < 0 .OR. kl < 0 .OR. ku < 0) ErrStat = 1
    IF (PRESENT(need_tangent)) ErrStat = ErrStat
  END SUBROUTINE zero_added_mass_band

  SUBROUTINE case_banded_dense_callback_mix_rejected()
    !! The dynamic path is dense XOR banded: a banded callback
    !! (load_band_proc/added_mass_band_proc) must not be mixed with a dense one
    !! (load_proc/added_mass_proc). Mixing could leave the banded workspace
    !! unallocated while the banded branch ran (write through unassociated pointers)
    !! or drop a banded load Jacobian from the dense tangent. All mixed
    !! combinations must fail closed with CD_DYN_BADINPUT.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), zero_ext(9)
    REAL(wp) :: q(9), v(9), a0(9), q1(9), v1(9), a1(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    fixed = [1, 2, 3, 7, 8, 9]
    f_ext = 0.0_wp
    zero_ext = 0.0_wp
    q = q0
    v = 0.0_wp
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a0, es, em)
    CALL expect_es(es, CD_DYN_OK, 'mix:a0')

    ! gen-alpha: dense load_proc + banded added_mass_band_proc (was an unassociated-pointer crash)
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q1, v1, a1, converged, stalled, n_iter, es, em, &
                                 load_proc=dense_linear_load, load_force_proc=linear_force_only, &
                                 added_mass_band_proc=zero_added_mass_band)
    CALL expect_es(es, CD_DYN_BADINPUT, 'mix:gen-load+amband-rejected')

    ! gen-alpha: banded load_band_proc + dense added_mass_proc (was a dropped load Jacobian)
    CALL CD_Cable_Gen_Alpha_Step(q, v, a0, conn, l0, ea, rho_a, .FALSE., zero_ext, fixed, &
                                 0.01_wp, cfg, q1, v1, a1, converged, stalled, n_iter, es, em, &
                                 load_force_proc=linear_force_only, load_band_proc=banded_linear_load, &
                                 added_mass_proc=constant_added_mass)
    CALL expect_es(es, CD_DYN_BADINPUT, 'mix:gen-loadband+am-rejected')

    ! init-accel: dense load_proc + banded added_mass_band_proc
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, a0, es, em, &
                                       load_proc=dense_linear_load, added_mass_band_proc=zero_added_mass_band)
    CALL expect_es(es, CD_DYN_BADINPUT, 'mix:init-load+amband-rejected')
  END SUBROUTINE case_banded_dense_callback_mix_rejected

  SUBROUTINE case_junction_tangent_after_allowance_exit()
    !! A step accepted by the near-tolerance allowance at the iteration limit exits right after
    !! a fresh tangent evaluation, which overwrites the factored effective band with the
    !! unfactored tangent. The junction end query must not back-solve with it as if it were
    !! the last LU factorization: its condensed end tangent and end map must agree with those
    !! the same converged iterate gets through an ordinary exit (whose factor is a valid LU).
    INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
    INTEGER :: conn(2, 3), n_iter, k
    REAL(wp) :: l0(3), ea(3), rho_a(3), f_ext(12), q(12), v(12)
    REAL(wp) :: q_b(12), q_r(12), rel_tol, kb(6, 6), kr(6, 6), xb(6, 6), xr(6, 6), err_k, err_x
    LOGICAL :: converged, found, valid

    ! two free nodes between held ends, so the effective tangent couples the free nodes
    conn = RESHAPE([1, 2, 2, 3, 3, 4], [2, 3])
    l0 = 0.9_wp
    ea = 1000.0_wp
    rho_a = 5.0_wp
    q = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, -0.1_wp, 2.0_wp, 0.0_wp, -0.1_wp, 3.0_wp, 0.0_wp, 0.0_wp]
    f_ext = 0.0_wp
    f_ext(6) = -15.0_wp
    v = 0.0_wp
    v(6) = -0.005_wp
    callback_kq = 20.0_wp
    callback_cv = 3.0_wp
    ! a tolerance for which the single allowed Newton iteration ends between rel_tol and the
    ! allowance 2 rel_tol: the step converges at the limit after a second, fresh tangent
    found = .FALSE.
    DO k = 0, 40
      rel_tol = 7.0e-9_wp*10.0_wp**(-0.25_wp*REAL(k, wp))
      CALL junction_query_step(conn, l0, ea, rho_a, f_ext, q, v, rel_tol, q_b, converged, n_iter, kb, xb, valid)
      IF (converged .AND. n_iter == 1 .AND. callback_tangent_count >= 2) THEN
        found = .TRUE.
        EXIT
      END IF
    END DO
    CALL require(found, 'allowance-exit:path-taken')
    IF (.NOT. found) RETURN
    CALL require(valid, 'allowance-exit:end-query-valid')
    ! the same iterate through an ordinary exit: the allowance as the tolerance
    CALL junction_query_step(conn, l0, ea, rho_a, f_ext, q, v, 2.0_wp*rel_tol, q_r, converged, n_iter, kr, xr, valid)
    CALL require(converged .AND. valid .AND. callback_tangent_count == 1, 'allowance-exit:reference-ordinary-exit')
    CALL require(ALL(TRANSFER(q_b, [0_I8]) == TRANSFER(q_r, [0_I8])), 'allowance-exit:same-iterate')
    err_k = nan_max_abs(kb - kr)/nan_max_abs(kr)
    err_x = nan_max_abs(xb - xr)/nan_max_abs(xr)
    IF (.NOT. (err_k <= 1.0e-6_wp .AND. err_x <= 1.0e-6_wp)) &
      WRITE (*, '(A,ES10.3,A,ES10.3)') 'allowance-exit: relative end-tangent error ', err_k, &
      ', end-map error ', err_x
    CALL require(err_k <= 1.0e-6_wp, 'allowance-exit:end-tangent-matches-ordinary-exit')
    CALL require(err_x <= 1.0e-6_wp, 'allowance-exit:end-map-matches-ordinary-exit')
  END SUBROUTINE case_junction_tangent_after_allowance_exit

  SUBROUTINE junction_query_step(conn, l0, ea, rho_a, f_ext, q, v, rel_tol, q_new, converged, n_iter, &
                                 end_k, end_x, valid)
    !! One step of the four-node line (ends held) with the junction end query armed, one Newton
    !! iteration allowed and a counted banded load, through a fresh workspace.
    INTEGER, INTENT(IN) :: conn(2, 3)
    REAL(wp), INTENT(IN) :: l0(3), ea(3), rho_a(3), f_ext(12), q(12), v(12), rel_tol
    REAL(wp), INTENT(OUT) :: q_new(12), end_k(6, 6), end_x(6, 6)
    LOGICAL, INTENT(OUT) :: converged, valid
    INTEGER, INTENT(OUT) :: n_iter
    TYPE(CD_CableGenAlphaWorkspace) :: work
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: a(12), v_new(12), a_new(12)
    INTEGER :: es
    LOGICAL :: stalled
    CHARACTER(120) :: em

    ! a consistent start: the predictor is then close to the step solution
    CALL CD_Cable_Initial_Acceleration(q, v, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 10, 11, 12], a, es, em, &
                                       load_force_proc=linear_force_only)
    CALL expect_es(es, CD_DYN_OK, 'allowance-exit:initial-acceleration')
    cfg%rel_tol = rel_tol
    cfg%abs_tol = TINY(1.0_wp)
    cfg%max_iter = 1
    work%end_request = .TRUE.
    callback_tangent_count = 0
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 10, 11, 12], 1.0e-3_wp, &
                                 cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em, &
                                 load_force_proc=linear_force_only, load_band_proc=counting_banded_load, &
                                 workspace=work)
    CALL expect_es(es, CD_DYN_OK, 'allowance-exit:step')
    end_k = 0.0_wp
    end_x = 0.0_wp
    valid = work%end_valid
    IF (valid) THEN
      end_k = work%end_k
      end_x = work%end_x
    END IF
  END SUBROUTINE junction_query_step

  SUBROUTINE counting_banded_load(q_in, v_in, free, kl, ku, force, jac_q_band, jac_v_band, ErrStat, ErrMsg)
    !! banded_linear_load, counting the tangent evaluations.
    REAL(wp), INTENT(IN) :: q_in(:), v_in(:)
    INTEGER, INTENT(IN) :: free(:), kl, ku
    REAL(wp), INTENT(OUT) :: force(:), jac_q_band(:, :), jac_v_band(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    callback_tangent_count = callback_tangent_count + 1
    CALL banded_linear_load(q_in, v_in, free, kl, ku, force, jac_q_band, jac_v_band, ErrStat, ErrMsg)
  END SUBROUTINE counting_banded_load
  SUBROUTINE case_fixed_dofs_held()
    !! Fixed DOFs are returned bit-exactly at their q0 value with zero velocity and
    !! acceleration, even while the free interior node accelerates under gravity.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, k
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9), load(3, 2)
    REAL(wp) :: q(9), v(9), a(9), q_new(9), v_new(9), a_new(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    INTEGER :: fdof
    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    ! shift node 3 up so the fixed end sits at a non-trivial, non-zero coordinate
    q0(9) = 0.25_wp
    load = SPREAD([0.0_wp, 0.0_wp, -50.0_wp], 2, 2)
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    q = q0; v = 0.0_wp; a = 0.0_wp
    fixed = [1, 2, 3, 7, 8, 9]
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.02_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_OK, 'held:ErrStat')
    DO k = 1, 6
      fdof = fixed(k)
      CALL expect(q_new(fdof), q0(fdof), 'held:q-exact')
      CALL expect(v_new(fdof), 0.0_wp, 'held:v-exact')
      CALL expect(a_new(fdof), 0.0_wp, 'held:a-exact')
    END DO
    ! the free node DID move (test is non-trivial)
    CALL require(ABS(q_new(6) - q0(6)) > 1.0e-6_wp, 'held:free-node-moved')
  END SUBROUTINE case_fixed_dofs_held

  SUBROUTINE case_fail_closed()
    !! Invalid dt, config, and fixed_dofs each fail closed with CD_DYN_BADINPUT.
    INTEGER  :: conn(2, 2), es, n_iter
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9)
    REAL(wp) :: q(9), v(9), a(9), q_new(9), v_new(9), a_new(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg, bad
    CHARACTER(120) :: em
    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    f_ext = 0.0_wp
    q = q0; v = 0.0_wp; a = 0.0_wp
    ! dt = 0
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 7, 8, 9], &
                                 0.0_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:dt-zero')
    ! dt = NaN
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 7, 8, 9], &
                                 IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN), cfg, q_new, v_new, a_new, &
                                 converged, stalled, n_iter, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:dt-nan')
    ! dt < 0
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 7, 8, 9], &
                                 -0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:dt-negative')
    ! rho_inf out of [0,1]
    bad = cfg; bad%rho_inf = 1.5_wp
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 7, 8, 9], &
                                 0.01_wp, bad, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:rho-inf')
    ! max_iter = 0
    bad = cfg; bad%max_iter = 0
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 7, 8, 9], &
                                 0.01_wp, bad, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:max-iter')
    ! armijo_c1 = -1 (non-positive)
    bad = cfg; bad%armijo_c1 = -1.0_wp
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 7, 8, 9], &
                                 0.01_wp, bad, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:armijo-c1')
    ! fixed_dofs out of range
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 99], &
                                 0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:fixed-range')
    ! fixed_dofs duplicate
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 3], &
                                 0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:fixed-duplicate')
    ! force-only load callbacks are legal for initial acceleration, but a step
    ! also needs the full load callback so Newton tangents include load Jacobians.
    callback_force = f_ext
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, [1, 2, 3, 7, 8, 9], &
                                 0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em, &
                                 load_force_proc=constant_force_only)
    CALL expect_es(es, CD_DYN_BADINPUT, 'fail:force-only-without-load-proc')
  END SUBROUTINE case_fail_closed

  SUBROUTINE case_failure_returns_input_state()
    !! Output-state contract: a failure that occurs AFTER input validation must
    !! leave the state at the input (t_n), not zeroed. A negative rho_a passes the
    !! step's own input checks (finite dt/config/fixed_dofs) but fails inside the
    !! consistent-mass assembly -- the output must echo the input q/v/a unchanged.
    INTEGER  :: conn(2, 2), fixed(6), es, n_iter, i
    REAL(wp) :: l0(2), ea(2), rho_a(2), q0(9), f_ext(9)
    REAL(wp) :: q(9), v(9), a(9), q_new(9), v_new(9), a_new(9)
    LOGICAL  :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em
    CALL three_node_chain(conn, l0, ea, rho_a, q0)
    rho_a = [5.0_wp, -1.0_wp]          ! invalid: mass assembly fails closed
    f_ext = 0.0_wp
    ! distinctive, non-zero input state so "echoed input" /= "zeroed output"
    q = q0; q(6) = 0.37_wp
    v = 0.0_wp; v(6) = -0.21_wp
    a = 0.0_wp; a(6) = 1.3_wp
    fixed = [1, 2, 3, 7, 8, 9]
    CALL CD_Cable_Gen_Alpha_Step(q, v, a, conn, l0, ea, rho_a, .FALSE., f_ext, fixed, &
                                 0.01_wp, cfg, q_new, v_new, a_new, converged, stalled, n_iter, es, em)
    CALL expect_es(es, CD_DYN_BADINPUT, 'failstate:ErrStat')
    CALL require(.NOT. converged, 'failstate:not-converged')
    DO i = 1, 9
      CALL expect(q_new(i), q(i), 'failstate:q-echoes-input')
      CALL expect(v_new(i), v(i), 'failstate:v-echoes-input')
      CALL expect(a_new(i), a(i), 'failstate:a-echoes-input')
    END DO
  END SUBROUTINE case_failure_returns_input_state

END PROGRAM test_cable_dynamic
