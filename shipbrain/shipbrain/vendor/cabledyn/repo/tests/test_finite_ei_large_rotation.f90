! File: tests/test_finite_ei_large_rotation.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_finite_ei_large_rotation
  !! Conservation GATES for large-rotation finite-EI dynamics (additive integrator baseline).
  !!
  !! These run on the additive Chung-Hulbert integrator (CD_Cosserat_Gen_Alpha_Step,
  !! multiplicative_rotation = .FALSE.) and establish that the gate has TEETH: the additive
  !! integrator conserves to round-off in the small-rotation regime where it is valid (matching L1-6/L1-8),
  !! and visibly FAILS at large rotation. A free rigid spin (no external load, no
  !! Dirichlet, rho_inf = 1 so gen-alpha adds no numerical dissipation) is the
  !! oracle-free reference: a correct integrator conserves total mechanical energy
  !! and keeps a rigid motion strain-free.
  !!
  !! Asserted split (the documented additive baseline):
  !!   * small-rotation conservation is asserted as a real gate -- it protects the
  !!     regime where the additive integrator is valid.
  !!   * large-rotation NON-conservation is asserted as the teeth (drift / spurious
  !!     strain / the |theta| < pi chart crash). The multiplicative-SO(3) path's
  !!     large-rotation behaviour (chart completion, momentum, rigid-spin energy) is
  !!     checked in test_finite_ei_gyro_dynamics.
  !!
  !! This file covers energy and zero-strain; angular momentum and symmetric-top
  !! precession are in test_finite_ei_precession.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CosseratDynamic, ONLY: CD_Cosserat_Gen_Alpha_Step, &
                                      CD_Cosserat_Initial_Acceleration, CD_Cosserat_Mechanical_Energy
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig, CD_DYN_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 8, NN = NE + 1, NDOF = 6*NN
  REAL(wp), PARAMETER :: L = 1.0_wp, EA = 1.0e4_wp, GAS = 1.0e3_wp, EI = 1.0e1_wp, GJ = 1.0e1_wp
  REAL(wp), PARAMETER :: RHO_A = 1.0_wp, I_RHO_T = 1.0e-2_wp, I_RHO_N = 2.0e-2_wp
  REAL(wp), PARAMETER :: AXIS_C = 0.70710678118654752_wp        ! cos 45 deg: spin axis between
  REAL(wp), PARAMETER :: AXIS_S = 0.70710678118654752_wp        ! the symmetry (x) and a transverse (y) axis
  INTEGER :: nfail
  nfail = 0

  CALL case_energy_conservation()
  CALL case_zero_strain_rigid_rotation()
  CALL case_chart_crash_under_sustained_rotation()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI large-rotation additive baseline (energy + zero-strain teeth)'

CONTAINS

  SUBROUTINE run_free_spin(omega_rate, dt, nstep, e0, energy_drift, max_strain, crashed, n_done)
    !! Integrate a free rigid spin of a centred straight rod at angular rate
    !! omega_rate about the 45-deg axis, conservatively (rho_inf = 1), with no load
    !! and no fixed DOFs. Returns the relative total-energy drift and the peak strain
    !! energy over the completed steps, and whether the integrator failed (e.g. the
    !! |theta| < pi chart crash) before nstep.
    REAL(wp), INTENT(IN) :: omega_rate, dt
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: e0, energy_drift, max_strain
    LOGICAL, INTENT(OUT) :: crashed
    INTEGER, INTENT(OUT) :: n_done
    INTEGER :: conn(2, NE), i, es, n_iter, step
    REAL(wp) :: nodes_ref(3, NN), ea_a(NE), gas_a(NE), ei_a(NE), gj_a(NE), ra(NE), it(NE), in_(NE)
    REAL(wp) :: q(NDOF), vel(NDOF), acc(NDOF), q_new(NDOF), v_new(NDOF), a_new(NDOF), f_ext(NDOF)
    REAL(wp) :: w0(3), ri(3), strain_e, kinetic_e, en
    LOGICAL :: converged, stalled
    TYPE(GenAlphaConfig) :: cfg
    CHARACTER(120) :: em

    w0 = omega_rate*[AXIS_C, AXIS_S, 0.0_wp]
    DO i = 1, NE
      conn(:, i) = [i, i + 1]
      ea_a(i) = EA; gas_a(i) = GAS; ei_a(i) = EI; gj_a(i) = GJ
      ra(i) = RHO_A; it(i) = I_RHO_T; in_(i) = I_RHO_N
    END DO
    q = 0.0_wp; vel = 0.0_wp; f_ext = 0.0_wp
    DO i = 1, NN
      ri = [-0.5_wp*L + REAL(i - 1, wp)*L/REAL(NE, wp), 0.0_wp, 0.0_wp]   ! centred rod on x
      nodes_ref(:, i) = ri
      q(6*i - 5:6*i - 3) = ri                                            ! start at the reference (theta = 0)
      vel(6*i - 5:6*i - 3) = cross(w0, ri)                               ! rigid translational velocity
      vel(6*i - 2:6*i) = w0                                  ! spatial angular velocity (theta_dot at theta = 0)
    END DO
    cfg%rho_inf = 1.0_wp                          ! conservative: no algorithmic dissipation
    cfg%abs_tol = 1.0e-10_wp
    cfg%rel_tol = 1.0e-9_wp

    crashed = .FALSE.; n_done = 0
    CALL CD_Cosserat_Initial_Acceleration(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, &
                                          .TRUE., q, f_ext, [INTEGER ::], acc, es, em)
    CALL CD_Cosserat_Mechanical_Energy(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                       q, vel, strain_e, kinetic_e, es, em)
    e0 = strain_e + kinetic_e
    max_strain = strain_e
    energy_drift = 0.0_wp
    DO step = 1, nstep
      CALL CD_Cosserat_Gen_Alpha_Step(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                      q, vel, acc, f_ext, [INTEGER ::], dt, cfg, q_new, v_new, a_new, &
                                      converged, stalled, n_iter, es, em)
      IF (es /= CD_DYN_OK .OR. .NOT. converged) THEN
        crashed = .TRUE.
        RETURN
      END IF
      q = q_new; vel = v_new; acc = a_new
      n_done = step
      CALL CD_Cosserat_Mechanical_Energy(nodes_ref, conn, ea_a, gas_a, ei_a, gj_a, ra, it, in_, .TRUE., &
                                         q, vel, strain_e, kinetic_e, es, em)
      en = strain_e + kinetic_e
      energy_drift = MAX(energy_drift, ABS(en - e0)/e0)
      max_strain = MAX(max_strain, strain_e)
    END DO
  END SUBROUTINE run_free_spin

  SUBROUTINE case_energy_conservation()
    !! ENERGY. A free rigid spin under the conservative (rho_inf = 1) integrator must
    !! conserve total mechanical energy. The additive integrator does so to round-off
    !! at small rotation rate, and visibly drifts at large rate (the teeth).
    REAL(wp) :: e0, drift_small, drift_large, smax, e0l
    LOGICAL :: crashed
    INTEGER :: n_done

    CALL run_free_spin(0.02_wp, 0.02_wp, 300, e0, drift_small, smax, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 300, 'energy:small-rotation-completes')
    CALL require(drift_small < 1.0e-6_wp, 'energy:small-rotation-conserved')

    ! large rotation: 60 steps is safely before the chart crash (~step 82), so the
    ! drift is measured cleanly. A correct integrator would keep this < ~1e-6 too;
    ! the additive integrator is expected to drift O(1e-3) here, and that drift is asserted.
    CALL run_free_spin(2.0_wp, 0.02_wp, 60, e0l, drift_large, smax, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 60, 'energy:large-rotation-window-pre-crash')
    CALL require(drift_large > 1.0e-4_wp, 'energy:teeth-additive-drifts-at-large-rotation')

    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [energy] small-rot drift = ', drift_small, &
      '   large-rot drift = ', drift_large
  END SUBROUTINE case_energy_conservation

  SUBROUTINE case_zero_strain_rigid_rotation()
    !! ZERO STRAIN (the sharpest). A rigid-body rotation produces NO strain. A correct
    !! integrator keeps a free rigid spin strain-free; the additive integrator
    !! spuriously strains it at large rotation rate.
    REAL(wp) :: e0, drift, strain_small, strain_large
    LOGICAL :: crashed
    INTEGER :: n_done

    CALL run_free_spin(0.02_wp, 0.02_wp, 300, e0, drift, strain_small, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 300, 'zero-strain:small-rotation-completes')
    CALL require(strain_small < 1.0e-9_wp, 'zero-strain:small-rotation-stays-rigid')

    CALL run_free_spin(2.0_wp, 0.02_wp, 60, e0, drift, strain_large, crashed, n_done)
    CALL require(.NOT. crashed .AND. n_done == 60, 'zero-strain:large-rotation-window-pre-crash')
    CALL require(strain_large > 1.0e-6_wp, 'zero-strain:teeth-additive-strains-rigid-body')

    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [zero-strain] small-rot strain = ', strain_small, &
      '   large-rot strain = ', strain_large
  END SUBROUTINE case_zero_strain_rigid_rotation

  SUBROUTINE case_chart_crash_under_sustained_rotation()
    !! The deepest teeth: additive theta grows unbounded, so a sustained large-rotation
    !! free spin drives a nodal rotation vector out of the |theta| < pi chart and the
    !! integrator fails. A multiplicative-SO(3) update wraps Lambda and never leaves the
    !! chart; that completion is asserted in test_finite_ei_gyro_dynamics.
    REAL(wp) :: e0, drift, smax
    LOGICAL :: crashed
    INTEGER :: n_done

    CALL run_free_spin(2.0_wp, 0.02_wp, 400, e0, drift, smax, crashed, n_done)
    CALL require(crashed .AND. n_done < 400, 'chart-crash:additive-cannot-sustain-rotation')
    WRITE (*, '(A,I0,A)') '  [chart] additive integrator left the |theta|<pi chart after ', n_done, ' steps'
  END SUBROUTINE case_chart_crash_under_sustained_rotation

  PURE FUNCTION cross(a, b) RESULT(c3)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c3(3)
    c3 = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_finite_ei_large_rotation
