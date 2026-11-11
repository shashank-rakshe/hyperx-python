! File: tests/test_hydro.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hydro
  !! Unit checks for CableDyn_Hydro, the dynamic hydro/wave load set
  !! described in ARCHITECTURE.md and doc/coupling_boundary.md.
  !! The tests pin Morison section laws and Airy-wave kinematics against closed-form
  !! values from the standard references: the classical normal/tangential
  !! Morison convention and Dean & Dalrymple linear wave theory.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE
  USE CableDyn_Hydro, ONLY: CD_HYDRO_OK, CD_HYDRO_BADINPUT, CD_Split_Normal_Tangential, &
                            CD_Morison_Drag_Per_Length, CD_Morison_Drag_Per_Length_Jac, &
                            CD_Morison_Added_Mass_Per_Length, &
                            CD_Froude_Krylov_Per_Length, CD_Solve_Dispersion_Wavenumber, &
                            CD_Current_Profile_Velocity, CD_SeaState_Steady_Current, CD_Airy_Wave_Kinematics, &
                            CD_Airy_Wave_Kinematics_Precomputed, CD_JONSWAP_COMPONENTS, &
                            CD_JONSWAP_Wave_Kinematics, CD_JONSWAP_Wave_Kinematics_Precomputed, &
                            CD_JONSWAP_Wave_Precompute, &
                            CD_Cable_Morison_Drag_Load, CD_Morison_Drag_Element_Load, &
                            CD_Cable_Froude_Krylov_Load, CD_Froude_Krylov_Element_Load, &
                            CD_Cable_Buoyancy_Recovery_Load, &
                            CD_Cable_Morison_Drag_Force, CD_Morison_Drag_Element_Force, &
                            CD_Cable_Froude_Krylov_Force, CD_Froude_Krylov_Element_Force, &
                            CD_Cable_Buoyancy_Recovery_Force, &
                            CD_Buoyancy_Recovery_Element_Load, CD_Buoyancy_Recovery_Element_Force, &
                            CD_Cable_Added_Mass, CD_Cable_Added_Mass_Matrix, &
                            CD_Cable_Added_Mass_Force, CD_Added_Mass_Element, &
                            CD_Added_Mass_Element_Matrix, CD_Added_Mass_Element_Force
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  CALL test_split_and_drag()
  CALL test_cable_drag_load()
  CALL test_drag_element_matches_cable_path()
  CALL test_cable_drag_jacobian_matches_fd()
  CALL test_cable_fk_and_buoyancy_loads()
  CALL test_fk_element_matches_cable_path()
  CALL test_buoyancy_element_matches_cable_path()
  CALL test_cable_wave_buoyancy_jacobians_match_fd()
  CALL test_cable_added_mass()
  CALL test_added_mass_element_matches_cable_path()
  CALL test_added_mass_element_matrix_matches_cable_path()
  CALL test_cable_added_mass_derivative_matches_fd()
  CALL test_element_kernels_validated_path()
  CALL test_added_mass_and_fk()
  CALL test_current_profile()
  CALL test_seastate_steady_current()
  CALL test_airy_wave()
  CALL test_jonswap_wave()
  CALL test_fail_closed()
  PRINT *, 'PASS: hydro'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE test_split_and_drag()
    REAL(wp) :: normal(3), tangential(3), force(3), want(3), pi
    INTEGER :: es
    CHARACTER(160) :: em

    pi = ACOS(-CD_ONE)
    CALL CD_Split_Normal_Tangential([1.0_wp, 2.0_wp, 3.0_wp], [2.0_wp, 0.0_wp, 0.0_wp], &
                                    normal, tangential, es, em)
    CALL require(es == CD_HYDRO_OK, 'split:status')
    CALL check_vec(normal, [0.0_wp, 2.0_wp, 3.0_wp], 1.0e-13_wp, 'split:normal')
    CALL check_vec(tangential, [1.0_wp, 0.0_wp, 0.0_wp], 1.0e-13_wp, 'split:tangential')

    CALL CD_Morison_Drag_Per_Length([0.0_wp, 2.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], &
                                    1000.0_wp, 0.2_wp, 1.2_wp, 0.5_wp, force, es, em)
    CALL require(es == CD_HYDRO_OK, 'normal-drag:status')
    CALL check_vec(force, [0.0_wp, 480.0_wp, 0.0_wp], 1.0e-12_wp, 'normal-drag:value')

    CALL CD_Morison_Drag_Per_Length([3.0_wp, 0.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], &
                                    1000.0_wp, 0.2_wp, 1.2_wp, 0.5_wp, force, es, em)
    CALL require(es == CD_HYDRO_OK, 'tangential-drag:status')
    want = [450.0_wp*pi, 0.0_wp, 0.0_wp]
    CALL check_vec(force, want, 1.0e-10_wp, 'tangential-drag:value')
  END SUBROUTINE test_split_and_drag

  SUBROUTINE test_cable_drag_load()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), v(6), fluid(3, 2), wl(2), l0(1), force(6), force_only(6), jq(6, 6), jv(6, 6)
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]
    q = [0.0_wp, 0.0_wp, -1.0_wp, 1.0_wp, 0.0_wp, -1.0_wp]
    v = 0.0_wp
    fluid(:, 1) = [0.0_wp, 2.0_wp, 0.0_wp]
    fluid(:, 2) = [0.0_wp, 2.0_wp, 0.0_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Morison_Drag_Load(q, v, conn, l0, fluid, wl, 1000.0_wp, 0.2_wp, 1.2_wp, 0.5_wp, &
                                    force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'cable-drag:status')
    CALL check_vec(force(1:3), [0.0_wp, 240.0_wp, 0.0_wp], 1.0e-9_wp, 'cable-drag:node-a')
    CALL check_vec(force(4:6), [0.0_wp, 240.0_wp, 0.0_wp], 1.0e-9_wp, 'cable-drag:node-b')
    ! Fully wet, normal relative velocity: d(force_node_y)/d(v_node_y) = -120,
    ! so residual Jacobian -dF/dv contributes +120 to each node-row / node-column pair.
    CALL require(ABS(jv(2, 2) - 120.0_wp) < 1.0e-6_wp, 'cable-drag:jv-aa')
    CALL require(ABS(jv(2, 5) - 120.0_wp) < 1.0e-6_wp, 'cable-drag:jv-ab')
    CALL require(ABS(jv(5, 2) - 120.0_wp) < 1.0e-6_wp, 'cable-drag:jv-ba')
    CALL require(ABS(jv(5, 5) - 120.0_wp) < 1.0e-6_wp, 'cable-drag:jv-bb')
    CALL require(nan_max_abs(jq) > 0.0_wp, 'cable-drag:jq-present')
    CALL CD_Cable_Morison_Drag_Force(q, v, conn, l0, fluid, wl, 1000.0_wp, 0.2_wp, 1.2_wp, 0.5_wp, &
                                     force_only, es, em)
    CALL require(es == CD_HYDRO_OK, 'cable-drag-force:status')
    CALL check_vec(force_only(1:3), force(1:3), 1.0e-12_wp, 'cable-drag-force:node-a')
    CALL check_vec(force_only(4:6), force(4:6), 1.0e-12_wp, 'cable-drag-force:node-b')
  END SUBROUTINE test_cable_drag_load

  SUBROUTINE test_drag_element_matches_cable_path()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), v(6), fluid(3, 2), wl(2), l0(1), force_ref(6), jq_ref(6, 6), jv_ref(6, 6)
    REAL(wp) :: force_elem(6), jq_elem(6, 6), jv_elem(6, 6), force_only(6)
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.7_wp]
    q = [-0.2_wp, 0.1_wp, -0.8_wp, 1.4_wp, -0.3_wp, 0.2_wp]
    v = [0.14_wp, -0.23_wp, 0.04_wp, -0.07_wp, 0.19_wp, -0.11_wp]
    fluid(:, 1) = [0.8_wp, 0.1_wp, -0.2_wp]
    fluid(:, 2) = [0.3_wp, 0.6_wp, 0.1_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Morison_Drag_Load(q, v, conn, l0, fluid, wl, 1025.0_wp, 0.24_wp, 1.05_wp, 0.32_wp, &
                                    force_ref, jq_ref, jv_ref, es, em)
    CALL require(es == CD_HYDRO_OK, 'drag-element-ref:status')
    CALL CD_Morison_Drag_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), fluid(:, 1), fluid(:, 2), &
                                      wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.05_wp, 0.32_wp, &
                                      force_elem, jq_elem, jv_elem, es, em)
    CALL require(es == CD_HYDRO_OK, 'drag-element-load:status')
    CALL check_vec(force_elem, force_ref, 1.0e-12_wp, 'drag-element:force')
    CALL require(nan_max_abs(jq_elem - jq_ref) <= 1.0e-12_wp, 'drag-element:jq')
    CALL require(nan_max_abs(jv_elem - jv_ref) <= 1.0e-12_wp, 'drag-element:jv')

    CALL CD_Morison_Drag_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), fluid(:, 1), fluid(:, 2), &
                                       wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.05_wp, 0.32_wp, &
                                       force_only, es, em)
    CALL require(es == CD_HYDRO_OK, 'drag-element-force:status')
    CALL check_vec(force_only, force_ref, 1.0e-12_wp, 'drag-element:force-only')
  END SUBROUTINE test_drag_element_matches_cable_path

  SUBROUTINE test_cable_drag_jacobian_matches_fd()
    INTEGER :: conn(2, 1), es, j
    REAL(wp) :: q(6), v(6), fluid(3, 2), wl(2), l0(1), force(6), jq(6, 6), jv(6, 6)
    REAL(wp) :: qp(6), qm(6), vp(6), vm(6), fp(6), fm(6), fd_col(6), h
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.3_wp]
    q = [0.0_wp, 0.0_wp, -0.4_wp, 0.8_wp, 0.3_wp, 0.6_wp]
    v = [0.2_wp, -0.1_wp, 0.05_wp, -0.3_wp, 0.4_wp, -0.2_wp]
    fluid(:, 1) = [0.9_wp, 0.2_wp, -0.1_wp]
    fluid(:, 2) = [0.4_wp, 0.7_wp, 0.3_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Morison_Drag_Load(q, v, conn, l0, fluid, wl, 998.0_wp, 0.18_wp, 1.1_wp, 0.35_wp, &
                                    force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'cable-drag-analytic:status')
    h = 2.0e-6_wp
    DO j = 1, 6
      qp = q
      qm = q
      qp(j) = qp(j) + h
      qm(j) = qm(j) - h
      CALL CD_Cable_Morison_Drag_Force(qp, v, conn, l0, fluid, wl, 998.0_wp, 0.18_wp, 1.1_wp, 0.35_wp, &
                                       fp, es, em)
      CALL require(es == CD_HYDRO_OK, 'cable-drag-jq-fd-plus')
      CALL CD_Cable_Morison_Drag_Force(qm, v, conn, l0, fluid, wl, 998.0_wp, 0.18_wp, 1.1_wp, 0.35_wp, &
                                       fm, es, em)
      CALL require(es == CD_HYDRO_OK, 'cable-drag-jq-fd-minus')
      fd_col = -(fp - fm)/(2.0_wp*h)
      CALL check_vec(jq(:, j), fd_col, 2.0e-5_wp, 'cable-drag:jq-fd')

      vp = v
      vm = v
      vp(j) = vp(j) + h
      vm(j) = vm(j) - h
      CALL CD_Cable_Morison_Drag_Force(q, vp, conn, l0, fluid, wl, 998.0_wp, 0.18_wp, 1.1_wp, 0.35_wp, &
                                       fp, es, em)
      CALL require(es == CD_HYDRO_OK, 'cable-drag-jv-fd-plus')
      CALL CD_Cable_Morison_Drag_Force(q, vm, conn, l0, fluid, wl, 998.0_wp, 0.18_wp, 1.1_wp, 0.35_wp, &
                                       fm, es, em)
      CALL require(es == CD_HYDRO_OK, 'cable-drag-jv-fd-minus')
      fd_col = -(fp - fm)/(2.0_wp*h)
      CALL check_vec(jv(:, j), fd_col, 2.0e-5_wp, 'cable-drag:jv-fd')
    END DO
  END SUBROUTINE test_cable_drag_jacobian_matches_fd

  SUBROUTINE test_cable_fk_and_buoyancy_loads()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), v(6), field(3, 2), wl(2), l0(1), force(6), force_only(6), jq(6, 6), jv(6, 6)
    REAL(wp) :: base, rho, diam, pi, half_buoy
    CHARACTER(160) :: em

    pi = ACOS(-CD_ONE)
    rho = 1025.0_wp
    diam = 0.252_wp
    base = rho*0.25_wp*pi*diam*diam
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]
    q = [0.0_wp, 0.0_wp, -1.0_wp, 1.0_wp, 0.0_wp, -1.0_wp]
    v = 0.0_wp
    field(:, 1) = [1.0_wp, 0.0_wp, 2.0_wp]
    field(:, 2) = [1.0_wp, 0.0_wp, 2.0_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Froude_Krylov_Load(q, v, conn, l0, field, wl, rho, diam, 1.0_wp, 0.0_wp, &
                                     force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'cable-fk:status')
    CALL check_vec(force(1:3), [0.5_wp*base, 0.0_wp, 2.0_wp*base], 1.0e-10_wp, 'cable-fk:node-a')
    CALL check_vec(force(4:6), [0.5_wp*base, 0.0_wp, 2.0_wp*base], 1.0e-10_wp, 'cable-fk:node-b')
    CALL require(nan_max_abs(jv) <= 1.0e-15_wp, 'cable-fk:jv-zero')
    CALL require(nan_max_abs(jq) > 0.0_wp, 'cable-fk:jq-present')
    CALL CD_Cable_Froude_Krylov_Force(q, v, conn, l0, field, wl, rho, diam, 1.0_wp, 0.0_wp, &
                                      force_only, es, em)
    CALL require(es == CD_HYDRO_OK, 'cable-fk-force:status')
    CALL check_vec(force_only(1:3), force(1:3), 1.0e-12_wp, 'cable-fk-force:node-a')
    CALL check_vec(force_only(4:6), force(4:6), 1.0e-12_wp, 'cable-fk-force:node-b')

    CALL CD_Cable_Buoyancy_Recovery_Load(q, v, conn, l0, wl, rho, diam, 9.80665_wp, &
                                         force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoyancy:wet-status')
    CALL require(nan_max_abs(force) <= 1.0e-15_wp, 'buoyancy:wet-zero')
    CALL require(nan_max_abs(jv) <= 1.0e-15_wp, 'buoyancy:jv-zero')

    q(3) = 1.0_wp
    q(6) = 1.0_wp
    half_buoy = 0.5_wp*base*9.80665_wp
    CALL CD_Cable_Buoyancy_Recovery_Load(q, v, conn, l0, wl, rho, diam, 9.80665_wp, &
                                         force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoyancy:dry-status')
    CALL check_vec(force(1:3), [0.0_wp, 0.0_wp, -half_buoy], 1.0e-10_wp, 'buoyancy:dry-a')
    CALL check_vec(force(4:6), [0.0_wp, 0.0_wp, -half_buoy], 1.0e-10_wp, 'buoyancy:dry-b')

    q(3) = -1.0_wp
    q(6) = 1.0_wp
    CALL CD_Cable_Buoyancy_Recovery_Load(q, v, conn, l0, wl, rho, diam, 9.80665_wp, &
                                         force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoyancy:piercing-status')
    CALL require(force(3) < 0.0_wp .AND. force(6) < 0.0_wp, 'buoyancy:piercing-force')
    CALL require(nan_max_abs(jq) > 0.0_wp, 'buoyancy:piercing-jq')
    CALL CD_Cable_Buoyancy_Recovery_Force(q, v, conn, l0, wl, rho, diam, 9.80665_wp, &
                                          force_only, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoyancy-force:piercing-status')
    CALL check_vec(force_only(1:3), force(1:3), 1.0e-12_wp, 'buoyancy-force:node-a')
    CALL check_vec(force_only(4:6), force(4:6), 1.0e-12_wp, 'buoyancy-force:node-b')
  END SUBROUTINE test_cable_fk_and_buoyancy_loads

  SUBROUTINE test_fk_element_matches_cable_path()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), v(6), field(3, 2), wl(2), l0(1), force_ref(6), jq_ref(6, 6), jv_ref(6, 6)
    REAL(wp) :: force_elem(6), jq_elem(6, 6), jv_elem(6, 6), force_only(6)
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.35_wp]
    q = [-0.1_wp, 0.2_wp, -0.5_wp, 1.1_wp, -0.4_wp, 0.35_wp]
    v = [0.2_wp, -0.1_wp, 0.05_wp, -0.2_wp, 0.3_wp, 0.1_wp]
    field(:, 1) = [0.5_wp, -0.2_wp, 0.4_wp]
    field(:, 2) = [-0.1_wp, 0.6_wp, 0.2_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Froude_Krylov_Load(q, v, conn, l0, field, wl, 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, &
                                     force_ref, jq_ref, jv_ref, es, em)
    CALL require(es == CD_HYDRO_OK, 'fk-element-ref:status')
    CALL CD_Froude_Krylov_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), field(:, 1), field(:, 2), &
                                       wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, &
                                       force_elem, jq_elem, jv_elem, es, em)
    CALL require(es == CD_HYDRO_OK, 'fk-element-load:status')
    CALL check_vec(force_elem, force_ref, 1.0e-12_wp, 'fk-element:force')
    CALL require(nan_max_abs(jq_elem - jq_ref) <= 1.0e-12_wp, 'fk-element:jq')
    CALL require(nan_max_abs(jv_elem - jv_ref) <= 1.0e-12_wp, 'fk-element:jv')

    CALL CD_Froude_Krylov_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0(1), field(:, 1), field(:, 2), &
                                        wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, force_only, es, em)
    CALL require(es == CD_HYDRO_OK, 'fk-element-force:status')
    CALL check_vec(force_only, force_ref, 1.0e-12_wp, 'fk-element:force-only')
  END SUBROUTINE test_fk_element_matches_cable_path

  SUBROUTINE test_buoyancy_element_matches_cable_path()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), v(6), wl(2), l0(1), force_ref(6), jq_ref(6, 6), jv_ref(6, 6)
    REAL(wp) :: force_elem(6), jq_elem(6, 6), jv_elem(6, 6), force_only(6)
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.6_wp]
    q = [0.0_wp, 0.0_wp, -0.7_wp, 1.2_wp, 0.2_wp, 0.25_wp]
    v = [0.1_wp, 0.0_wp, -0.2_wp, -0.1_wp, 0.3_wp, 0.2_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Buoyancy_Recovery_Load(q, v, conn, l0, wl, 1025.0_wp, 0.24_wp, 9.80665_wp, &
                                         force_ref, jq_ref, jv_ref, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoy-element-ref:status')
    CALL CD_Buoyancy_Recovery_Element_Load(q(1:3), q(4:6), l0(1), wl(1), wl(2), &
                                           1025.0_wp, 0.24_wp, 9.80665_wp, &
                                           force_elem, jq_elem, jv_elem, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoy-element-load:status')
    CALL check_vec(force_elem, force_ref, 1.0e-12_wp, 'buoy-element:force')
    CALL require(nan_max_abs(jq_elem - jq_ref) <= 1.0e-12_wp, 'buoy-element:jq')
    CALL require(nan_max_abs(jv_elem - jv_ref) <= 1.0e-12_wp, 'buoy-element:jv')

    CALL CD_Buoyancy_Recovery_Element_Force(q(1:3), q(4:6), l0(1), wl(1), wl(2), &
                                            1025.0_wp, 0.24_wp, 9.80665_wp, force_only, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoy-element-force:status')
    CALL check_vec(force_only, force_ref, 1.0e-12_wp, 'buoy-element:force-only')
  END SUBROUTINE test_buoyancy_element_matches_cable_path

  SUBROUTINE test_cable_wave_buoyancy_jacobians_match_fd()
    INTEGER :: conn(2, 1), es, j
    REAL(wp) :: q(6), v(6), field(3, 2), wl(2), l0(1), force(6), jq(6, 6), jv(6, 6)
    REAL(wp) :: qp(6), qm(6), fp(6), fm(6), fd_col(6), h
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.4_wp]
    q = [0.0_wp, -0.2_wp, -0.35_wp, 0.9_wp, 0.4_wp, 0.55_wp]
    v = 0.0_wp
    field(:, 1) = [0.5_wp, -0.2_wp, 1.1_wp]
    field(:, 2) = [0.1_wp, 0.3_wp, 0.7_wp]
    wl = [0.0_wp, 0.0_wp]
    h = 2.0e-6_wp

    CALL CD_Cable_Froude_Krylov_Load(q, v, conn, l0, field, wl, 1025.0_wp, 0.21_wp, 0.8_wp, 0.2_wp, &
                                     force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'fk-analytic:status')
    DO j = 1, 6
      qp = q
      qm = q
      qp(j) = qp(j) + h
      qm(j) = qm(j) - h
      CALL CD_Cable_Froude_Krylov_Force(qp, v, conn, l0, field, wl, 1025.0_wp, 0.21_wp, 0.8_wp, 0.2_wp, &
                                        fp, es, em)
      CALL require(es == CD_HYDRO_OK, 'fk-jq-fd-plus')
      CALL CD_Cable_Froude_Krylov_Force(qm, v, conn, l0, field, wl, 1025.0_wp, 0.21_wp, 0.8_wp, 0.2_wp, &
                                        fm, es, em)
      CALL require(es == CD_HYDRO_OK, 'fk-jq-fd-minus')
      fd_col = -(fp - fm)/(2.0_wp*h)
      CALL check_vec(jq(:, j), fd_col, 2.0e-5_wp, 'fk:jq-fd')
    END DO

    CALL CD_Cable_Buoyancy_Recovery_Load(q, v, conn, l0, wl, 1025.0_wp, 0.21_wp, 9.80665_wp, &
                                         force, jq, jv, es, em)
    CALL require(es == CD_HYDRO_OK, 'buoyancy-analytic:status')
    DO j = 1, 6
      qp = q
      qm = q
      qp(j) = qp(j) + h
      qm(j) = qm(j) - h
      CALL CD_Cable_Buoyancy_Recovery_Force(qp, v, conn, l0, wl, 1025.0_wp, 0.21_wp, 9.80665_wp, &
                                            fp, es, em)
      CALL require(es == CD_HYDRO_OK, 'buoyancy-jq-fd-plus')
      CALL CD_Cable_Buoyancy_Recovery_Force(qm, v, conn, l0, wl, 1025.0_wp, 0.21_wp, 9.80665_wp, &
                                            fm, es, em)
      CALL require(es == CD_HYDRO_OK, 'buoyancy-jq-fd-minus')
      fd_col = -(fp - fm)/(2.0_wp*h)
      CALL check_vec(jq(:, j), fd_col, 2.0e-5_wp, 'buoyancy:jq-fd')
    END DO
  END SUBROUTINE test_cable_wave_buoyancy_jacobians_match_fd

  SUBROUTINE test_cable_added_mass()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), accel(6), wl(2), l0(1), M_add(6, 6), M_only(6, 6), dMa(6, 6)
    REAL(wp) :: base, rho, diam, pi
    CHARACTER(160) :: em

    pi = ACOS(-CD_ONE)
    rho = 1025.0_wp
    diam = 0.252_wp
    base = rho*0.25_wp*pi*diam*diam
    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.0_wp]
    q = [0.0_wp, 0.0_wp, -1.0_wp, 1.0_wp, 0.0_wp, -1.0_wp]
    accel = [0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 2.0_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Added_Mass(q, accel, conn, l0, wl, rho, diam, 1.0_wp, 0.0_wp, M_add, dMa, es, em)
    CALL require(es == CD_HYDRO_OK, 'cable-added-mass:status')
    CALL require(ABS(M_add(2, 2) - base/3.0_wp) < 1.0e-12_wp, 'cable-added-mass:Maa-y')
    CALL require(ABS(M_add(3, 3) - base/3.0_wp) < 1.0e-12_wp, 'cable-added-mass:Maa-z')
    CALL require(ABS(M_add(2, 5) - base/6.0_wp) < 1.0e-12_wp, 'cable-added-mass:Mab-y')
    CALL require(ABS(M_add(6, 6) - base/3.0_wp) < 1.0e-12_wp, 'cable-added-mass:Mbb-z')
    CALL require(nan_max_abs(M_add - TRANSPOSE(M_add)) < 1.0e-13_wp, 'cable-added-mass:symmetric')
    CALL require(nan_max_abs(dMa) > 0.0_wp, 'cable-added-mass:dMa-present')
    CALL CD_Cable_Added_Mass_Matrix(q, conn, l0, wl, rho, diam, 1.0_wp, 0.0_wp, M_only, es, em)
    CALL require(es == CD_HYDRO_OK, 'cable-added-mass-matrix:status')
    CALL require(nan_max_abs(M_only - M_add) < 1.0e-13_wp, 'cable-added-mass-matrix:value')
  END SUBROUTINE test_cable_added_mass

  SUBROUTINE test_added_mass_element_matches_cable_path()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), accel(6), wl(2), l0(1), m_ref(6, 6), dm_ref(6, 6), f_ref(6)
    REAL(wp) :: m_elem(6, 6), dm_elem(6, 6), f_elem(6)
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.4_wp]
    q = [0.1_wp, -0.2_wp, -0.6_wp, 1.2_wp, 0.4_wp, 0.25_wp]
    accel = [0.3_wp, -0.1_wp, 0.2_wp, -0.4_wp, 0.5_wp, -0.2_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Added_Mass(q, accel, conn, l0, wl, 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, &
                             m_ref, dm_ref, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-element-ref:status')
    CALL CD_Added_Mass_Element(q(1:3), q(4:6), accel(1:3), accel(4:6), l0(1), wl(1), wl(2), &
                               1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, m_elem, dm_elem, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-element-load:status')
    CALL require(nan_max_abs(m_elem - m_ref) <= 1.0e-12_wp, 'added-element:matrix')
    CALL require(nan_max_abs(dm_elem - dm_ref) <= 1.0e-12_wp, 'added-element:derivative')

    CALL CD_Cable_Added_Mass_Force(q, accel, conn, l0, wl, 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, &
                                   f_ref, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-element-force-ref:status')
    CALL CD_Added_Mass_Element_Force(q(1:3), q(4:6), accel(1:3), accel(4:6), l0(1), wl(1), wl(2), &
                                     1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, f_elem, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-element-force:status')
    CALL check_vec(f_elem, f_ref, 1.0e-12_wp, 'added-element:force')
  END SUBROUTINE test_added_mass_element_matches_cable_path

  SUBROUTINE test_added_mass_element_matrix_matches_cable_path()
    INTEGER :: conn(2, 1), es
    REAL(wp) :: q(6), wl(2), l0(1), m_ref(6, 6), m_elem(6, 6)
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.9_wp]
    q = [-0.4_wp, 0.2_wp, 0.3_wp, 0.8_wp, -0.1_wp, -0.7_wp]
    wl = [0.0_wp, 0.0_wp]

    CALL CD_Cable_Added_Mass_Matrix(q, conn, l0, wl, 1025.0_wp, 0.31_wp, 1.2_wp, 0.25_wp, &
                                    m_ref, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-element-matrix-ref:status')
    CALL CD_Added_Mass_Element_Matrix(q(1:3), q(4:6), l0(1), wl(1), wl(2), &
                                      1025.0_wp, 0.31_wp, 1.2_wp, 0.25_wp, m_elem, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-element-matrix:status')
    CALL require(nan_max_abs(m_elem - m_ref) <= 1.0e-12_wp, 'added-element-matrix:value')
  END SUBROUTINE test_added_mass_element_matrix_matches_cable_path

  SUBROUTINE test_cable_added_mass_derivative_matches_fd()
    INTEGER :: conn(2, 1), es, j
    REAL(wp) :: q(6), qp(6), qm(6), accel(6), wl(2), l0(1), M_add(6, 6), dMa(6, 6)
    REAL(wp) :: Mp(6, 6), Mm(6, 6), fd_col(6), h
    CHARACTER(160) :: em

    conn = RESHAPE([1, 2], [2, 1])
    l0 = [1.25_wp]
    q = [0.0_wp, -0.1_wp, -0.45_wp, 0.7_wp, 0.35_wp, 0.5_wp]
    accel = [0.3_wp, -0.4_wp, 0.8_wp, -0.2_wp, 0.5_wp, 1.1_wp]
    wl = [0.0_wp, 0.0_wp]
    h = 2.0e-6_wp

    CALL CD_Cable_Added_Mass(q, accel, conn, l0, wl, 1025.0_wp, 0.23_wp, 0.9_wp, 0.15_wp, &
                             M_add, dMa, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-mass-analytic:status')
    DO j = 1, 6
      qp = q
      qm = q
      qp(j) = qp(j) + h
      qm(j) = qm(j) - h
      CALL CD_Cable_Added_Mass_Matrix(qp, conn, l0, wl, 1025.0_wp, 0.23_wp, 0.9_wp, 0.15_wp, Mp, es, em)
      CALL require(es == CD_HYDRO_OK, 'added-mass-dMa-fd-plus')
      CALL CD_Cable_Added_Mass_Matrix(qm, conn, l0, wl, 1025.0_wp, 0.23_wp, 0.9_wp, 0.15_wp, Mm, es, em)
      CALL require(es == CD_HYDRO_OK, 'added-mass-dMa-fd-minus')
      fd_col = MATMUL(Mp - Mm, accel)/(2.0_wp*h)
      CALL check_vec(dMa(:, j), fd_col, 2.0e-5_wp, 'added-mass:dMa-fd')
    END DO
  END SUBROUTINE test_cable_added_mass_derivative_matches_fd

  SUBROUTINE test_added_mass_and_fk()
    REAL(wp) :: M_a(3, 3), force(3), want_m(3, 3), want_f(3), base, rho, diam, pi
    INTEGER :: es
    CHARACTER(160) :: em

    pi = ACOS(-CD_ONE)
    rho = 1025.0_wp
    diam = 0.252_wp
    base = rho*0.25_wp*pi*diam*diam
    CALL CD_Morison_Added_Mass_Per_Length([0.0_wp, 0.0_wp, 2.0_wp], rho, diam, &
                                          1.0_wp, 0.0_wp, M_a, es, em)
    CALL require(es == CD_HYDRO_OK, 'added-mass:status')
    want_m = CD_ZERO
    want_m(1, 1) = base
    want_m(2, 2) = base
    CALL check_mat(M_a, want_m, 1.0e-12_wp, 'added-mass:value')

    CALL CD_Froude_Krylov_Per_Length([1.0_wp, 0.0_wp, 2.0_wp], [0.0_wp, 0.0_wp, 1.0_wp], &
                                     rho, diam, 1.0_wp, 0.0_wp, force, es, em)
    CALL require(es == CD_HYDRO_OK, 'fk:status')
    want_f = [2.0_wp*base, 0.0_wp, 2.0_wp*base]
    CALL check_vec(force, want_f, 1.0e-12_wp, 'fk:value')
  END SUBROUTINE test_added_mass_and_fk

  SUBROUTINE test_current_profile()
    REAL(wp) :: z_profile(2), velocity_profile(3, 2), velocity(3)
    INTEGER :: es
    CHARACTER(160) :: em

    z_profile = [-50.0_wp, 0.0_wp]
    velocity_profile(:, 1) = [0.2_wp, 0.0_wp, 0.0_wp]
    velocity_profile(:, 2) = [1.2_wp, 0.4_wp, 0.0_wp]
    CALL CD_Current_Profile_Velocity(-25.0_wp, z_profile, velocity_profile, velocity, es, em)
    CALL require(es == CD_HYDRO_OK, 'current-profile:status')
    CALL check_vec(velocity, [0.7_wp, 0.2_wp, 0.0_wp], 1.0e-13_wp, 'current-profile:mid')

    CALL CD_Current_Profile_Velocity(-80.0_wp, z_profile, velocity_profile, velocity, es, em)
    CALL require(es == CD_HYDRO_OK, 'current-profile:below-status')
    CALL check_vec(velocity, velocity_profile(:, 1), 1.0e-13_wp, 'current-profile:below-clamp')

    z_profile = [-10.0_wp, -10.0_wp]
    CALL CD_Current_Profile_Velocity(-10.0_wp, z_profile, velocity_profile, velocity, es, em)
    CALL require(es == CD_HYDRO_BADINPUT, 'current-profile:duplicate-depth-fails')

    ! N-LEVEL generalization: piecewise-linear over interior levels with clamping,
    ! exact at nodes and midpoints; unordered levels fail closed.
    BLOCK
      REAL(wp) :: zp4(4), vp4(3, 4), vel4(3)
      zp4 = [-100.0_wp, -50.0_wp, -20.0_wp, 0.0_wp]
      vp4 = 0.0_wp
      vp4(1, :) = [0.1_wp, 0.4_wp, 0.8_wp, 1.2_wp]
      CALL CD_Current_Profile_Velocity(-50.0_wp, zp4, vp4, vel4, es, em)
      CALL require(es == CD_HYDRO_OK .AND. ABS(vel4(1) - 0.4_wp) <= 0.0_wp, 'profile:n-level-node-exact')
      CALL CD_Current_Profile_Velocity(-35.0_wp, zp4, vp4, vel4, es, em)
      CALL require(es == CD_HYDRO_OK .AND. ABS(vel4(1) - 0.6_wp) < 1.0e-14_wp, 'profile:n-level-midpoint')
      CALL CD_Current_Profile_Velocity(-500.0_wp, zp4, vp4, vel4, es, em)
      CALL require(es == CD_HYDRO_OK .AND. ABS(vel4(1) - 0.1_wp) <= 0.0_wp, 'profile:n-level-clamp-low')
      CALL CD_Current_Profile_Velocity(5.0_wp, zp4, vp4, vel4, es, em)
      CALL require(es == CD_HYDRO_OK .AND. ABS(vel4(1) - 1.2_wp) <= 0.0_wp, 'profile:n-level-clamp-high')
      zp4 = [-100.0_wp, -20.0_wp, -50.0_wp, 0.0_wp]
      CALL CD_Current_Profile_Velocity(-35.0_wp, zp4, vp4, vel4, es, em)
      CALL require(es /= CD_HYDRO_OK, 'profile:unordered-levels-fail-closed')
    END BLOCK
  END SUBROUTINE test_current_profile

  SUBROUTINE test_seastate_steady_current()
    REAL(wp) :: velocity(3), want_ss
    INTEGER :: es
    CHARACTER(160) :: em

    CALL CD_SeaState_Steady_Current(-10.0_wp, 100.0_wp, 1, 1.4_wp, 0.0_wp, &
                                    20.0_wp, 0.6_wp, 90.0_wp, 0.2_wp, 180.0_wp, velocity, es, em)
    CALL require(es == CD_HYDRO_OK, 'seastate-current:status')
    want_ss = 1.4_wp*(0.9_wp**(1.0_wp/7.0_wp))
    CALL check_vec(velocity, [want_ss - 0.2_wp, 0.3_wp, 0.0_wp], &
                   2.0e-14_wp, 'seastate-current:stock-formula')
    CALL CD_SeaState_Steady_Current(1.0_wp, 100.0_wp, 1, 1.0_wp, 0.0_wp, &
                                    20.0_wp, 1.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, velocity, es, em)
    CALL require(es == CD_HYDRO_OK .AND. nan_max_abs(velocity) <= TINY(CD_ONE), &
                 'seastate-current:outside-water-zero')
    CALL CD_SeaState_Steady_Current(-10.0_wp, 100.0_wp, 2, 1.0_wp, 0.0_wp, &
                                    20.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, velocity, es, em)
    CALL require(es == CD_HYDRO_BADINPUT, 'seastate-current:user-profile-fails-closed')
  END SUBROUTINE test_seastate_steady_current

  SUBROUTINE test_airy_wave()
    REAL(wp) :: k, eta, eta_cached, velocity(3), velocity_cached(3), acceleration(3), acceleration_cached(3)
    REAL(wp) :: want_v(3), want_a(3)
    REAL(wp) :: height, period, depth, gravity, omega, theta, ratio_c, ratio_s, amp, pi
    INTEGER :: es
    CHARACTER(160) :: em

    pi = ACOS(-CD_ONE)
    height = 3.0_wp
    period = 8.0_wp
    depth = 50.0_wp
    gravity = 9.80665_wp
    omega = 2.0_wp*pi/period
    CALL CD_Solve_Dispersion_Wavenumber(omega, depth, gravity, k, es, em)
    CALL require(es == CD_HYDRO_OK, 'dispersion:status')
    CALL require(ABS(omega*omega - gravity*k*TANH(k*depth)) < 1.0e-13_wp, 'dispersion:residual')

    CALL CD_Airy_Wave_Kinematics(0.0_wp, 0.0_wp, -25.0_wp, 0.0_wp, height, period, depth, gravity, &
                                 180.0_wp, .FALSE., eta, velocity, acceleration, es, em)
    CALL require(es == CD_HYDRO_OK, 'airy:status')
    theta = CD_ZERO
    ratio_c = COSH(k*(-25.0_wp + depth))/SINH(k*depth)
    ratio_s = SINH(k*(-25.0_wp + depth))/SINH(k*depth)
    amp = 0.5_wp*height*omega
    want_v = [-amp*ratio_c*COS(theta), 0.0_wp, amp*ratio_s*SIN(theta)]
    amp = 0.5_wp*height*omega*omega
    want_a = [0.0_wp, 0.0_wp, -amp*ratio_s*COS(theta)]
    CALL require(ABS(eta - 1.5_wp) < 1.0e-13_wp, 'airy:eta')
    CALL check_vec(velocity, want_v, 1.0e-12_wp, 'airy:velocity')
    CALL check_vec(acceleration, want_a, 1.0e-12_wp, 'airy:acceleration')
    CALL CD_Airy_Wave_Kinematics_Precomputed(0.0_wp, 0.0_wp, -25.0_wp, 0.0_wp, height, omega, k, depth, &
                                             180.0_wp, .FALSE., eta_cached, velocity_cached, acceleration_cached, &
                                             es, em)
    CALL require(es == CD_HYDRO_OK, 'airy:cached-status')
    CALL require(ABS(eta_cached - eta) < 1.0e-13_wp, 'airy:cached-eta')
    CALL check_vec(velocity_cached, velocity, 1.0e-12_wp, 'airy:cached-velocity')
    CALL check_vec(acceleration_cached, acceleration, 1.0e-12_wp, 'airy:cached-acceleration')
    ! A zero wavenumber would divide by zero in profile_ratios; the public cached entry
    ! point must reject k <= 0 rather than return NaN/Inf with an OK status.
    CALL CD_Airy_Wave_Kinematics_Precomputed(0.0_wp, 0.0_wp, -25.0_wp, 0.0_wp, height, omega, 0.0_wp, depth, &
                                             180.0_wp, .FALSE., eta_cached, velocity_cached, acceleration_cached, &
                                             es, em)
    CALL require(es == CD_HYDRO_BADINPUT, 'airy:cached-zero-k-fails')

    CALL CD_Airy_Wave_Kinematics(0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, height, period, depth, gravity, &
                                 0.0_wp, .TRUE., eta, velocity, acceleration, es, em)
    CALL require(es == CD_HYDRO_OK, 'airy:dry-status')
    CALL check_vec(velocity, [0.0_wp, 0.0_wp, 0.0_wp], 1.0e-15_wp, 'airy:dry-velocity')
    CALL check_vec(acceleration, [0.0_wp, 0.0_wp, 0.0_wp], 1.0e-15_wp, 'airy:dry-acceleration')
  END SUBROUTINE test_airy_wave

  SUBROUTINE test_jonswap_wave()
    REAL(wp) :: eta0, eta1, eta_ref, velocity0(3), velocity1(3), velocity_ref(3)
    REAL(wp) :: acceleration0(3), acceleration1(3), acceleration_ref(3), hs_recovered, omega_peak_ratio
    REAL(wp) :: eta_cached, velocity_cached(3), acceleration_cached(3)
    REAL(wp) :: omega_comp(CD_JONSWAP_COMPONENTS), k_comp(CD_JONSWAP_COMPONENTS)
    REAL(wp) :: amplitude(CD_JONSWAP_COMPONENTS)
    INTEGER :: es
    CHARACTER(160) :: em

    CALL CD_JONSWAP_Wave_Kinematics(0.0_wp, 0.0_wp, -10.0_wp, 0.0_wp, 4.0_wp, 8.0_wp, &
                                    3.3_wp, 50.0_wp, 9.80665_wp, 0.0_wp, .TRUE., &
                                    eta0, velocity0, acceleration0, es, em)
    CALL require(es == CD_HYDRO_OK, 'jonswap:status')
    CALL reference_jonswap_kinematics(0.0_wp, 0.0_wp, -10.0_wp, 0.0_wp, 4.0_wp, 8.0_wp, &
                                      3.3_wp, 50.0_wp, 9.80665_wp, 0.0_wp, .TRUE., &
                                      eta_ref, velocity_ref, acceleration_ref, hs_recovered, omega_peak_ratio, es, em)
    CALL require(es == CD_HYDRO_OK, 'jonswap:reference-status')
    CALL require(ABS(hs_recovered - 4.0_wp) < 1.0e-12_wp, 'jonswap:hs-recovery')
    CALL require(ABS(omega_peak_ratio - CD_ONE) < 0.5_wp*4.8_wp/199.0_wp, 'jonswap:peak-bin')
    CALL require(ABS(eta0 - eta_ref) < 1.0e-12_wp, 'jonswap:eta-reference')
    CALL check_vec(velocity0, velocity_ref, 1.0e-12_wp, 'jonswap:velocity-reference')
    CALL check_vec(acceleration0, acceleration_ref, 1.0e-12_wp, 'jonswap:acceleration-reference')
    CALL require(ABS(eta0) > 1.0e-8_wp, 'jonswap:eta-nonzero')
    CALL require(nan_max_abs(velocity0) > 1.0e-8_wp, 'jonswap:velocity-nonzero')
    CALL require(nan_max_abs(acceleration0) > 1.0e-8_wp, 'jonswap:acceleration-nonzero')
    CALL CD_JONSWAP_Wave_Precompute(4.0_wp, 8.0_wp, 3.3_wp, 50.0_wp, 9.80665_wp, &
                                    omega_comp, k_comp, amplitude, es, em)
    CALL require(es == CD_HYDRO_OK, 'jonswap:precompute-status')
    CALL CD_JONSWAP_Wave_Kinematics_Precomputed(0.0_wp, 0.0_wp, -10.0_wp, 0.0_wp, 50.0_wp, 0.0_wp, .TRUE., &
                                                omega_comp, k_comp, amplitude, eta_cached, velocity_cached, &
                                                acceleration_cached, es, em)
    CALL require(es == CD_HYDRO_OK, 'jonswap:cached-status')
    CALL require(ABS(eta_cached - eta0) < 1.0e-12_wp, 'jonswap:cached-eta')
    CALL check_vec(velocity_cached, velocity0, 1.0e-12_wp, 'jonswap:cached-velocity')
    CALL check_vec(acceleration_cached, acceleration0, 1.0e-12_wp, 'jonswap:cached-acceleration')
    ! A zero entry in the cached wavenumbers would divide by zero in profile_ratios; the
    ! public cached entry point must reject it rather than return NaN/Inf with an OK status.
    k_comp(1) = 0.0_wp
    CALL CD_JONSWAP_Wave_Kinematics_Precomputed(0.0_wp, 0.0_wp, -10.0_wp, 0.0_wp, 50.0_wp, 0.0_wp, .TRUE., &
                                                omega_comp, k_comp, amplitude, eta_cached, velocity_cached, &
                                                acceleration_cached, es, em)
    CALL require(es == CD_HYDRO_BADINPUT, 'jonswap:cached-zero-k-fails')

    CALL CD_JONSWAP_Wave_Kinematics(0.0_wp, 0.0_wp, -10.0_wp, 1.0_wp, 4.0_wp, 8.0_wp, &
                                    3.3_wp, 50.0_wp, 9.80665_wp, 0.0_wp, .TRUE., &
                                    eta1, velocity1, acceleration1, es, em)
    CALL require(es == CD_HYDRO_OK, 'jonswap:t1-status')
    CALL require(ABS(eta1 - eta0) > 1.0e-8_wp, 'jonswap:evolves-in-time')
    CALL require(nan_max_abs(velocity1 - velocity0) > 1.0e-8_wp, 'jonswap:velocity-evolves')
  END SUBROUTINE test_jonswap_wave

  SUBROUTINE reference_jonswap_kinematics(x, y, z, t, hs, tp, gamma, depth, gravity, direction_deg, &
                                          stretch, eta, velocity, acceleration, hs_recovered, &
                                          omega_peak_ratio, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: x, y, z, t, hs, tp, gamma, depth, gravity, direction_deg
    LOGICAL, INTENT(IN) :: stretch
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3), hs_recovered, omega_peak_ratio
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER, PARAMETER :: ncomp = 200
    INTEGER :: i, imax
    REAL(wp) :: pi, deg2rad, golden, omega_p, omega_min, omega_max, domega, omega, k, sigma, expo
    REAL(wp) :: gamma_norm, shape, m0_raw, m0_scaled, scale, amp, phase, theta
    REAL(wp) :: cb, sb, x_along, z_eval, cosh_ratio, sinh_ratio
    REAL(wp) :: spec(ncomp), amplitude(ncomp), omega_comp(ncomp)

    pi = ACOS(-CD_ONE)
    deg2rad = pi/180.0_wp
    golden = 0.618033988749894848204586834365638118_wp
    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    hs_recovered = CD_ZERO
    omega_peak_ratio = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''

    omega_p = 2.0_wp*pi/tp
    omega_min = 0.2_wp*omega_p
    omega_max = 5.0_wp*omega_p
    domega = (omega_max - omega_min)/REAL(ncomp - 1, wp)
    gamma_norm = CD_ONE - 0.287_wp*LOG(gamma)
    m0_raw = CD_ZERO
    imax = 1
    DO i = 1, ncomp
      omega = omega_min + REAL(i - 1, wp)*domega
      sigma = MERGE(0.07_wp, 0.09_wp, omega <= omega_p)
      expo = EXP(-0.5_wp*((omega/omega_p - CD_ONE)/sigma)**2)
      shape = gamma_norm*gravity*gravity*omega**(-5)*EXP(-1.25_wp*(omega_p/omega)**4)*gamma**expo
      omega_comp(i) = omega
      spec(i) = shape
      IF (spec(i) > spec(imax)) imax = i
      m0_raw = m0_raw + shape*domega
    END DO
    scale = (hs*hs/16.0_wp)/m0_raw
    m0_scaled = CD_ZERO
    DO i = 1, ncomp
      amplitude(i) = SQRT(2.0_wp*spec(i)*scale*domega)
      m0_scaled = m0_scaled + spec(i)*scale*domega
    END DO
    hs_recovered = 4.0_wp*SQRT(m0_scaled)
    omega_peak_ratio = omega_comp(imax)/omega_p

    cb = COS(direction_deg*deg2rad)
    sb = SIN(direction_deg*deg2rad)
    x_along = x*cb + y*sb
    DO i = 1, ncomp
      CALL CD_Solve_Dispersion_Wavenumber(omega_comp(i), depth, gravity, k, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      phase = 2.0_wp*pi*MOD(REAL(i*i + 3*i, wp)*golden, CD_ONE)
      theta = k*x_along - omega_comp(i)*t + phase
      eta = eta + amplitude(i)*COS(theta)
    END DO

    IF (stretch) THEN
      IF (z > eta) RETURN
      z_eval = (z - eta)*depth/(depth + eta)
    ELSE
      z_eval = z
    END IF
    DO i = 1, ncomp
      CALL CD_Solve_Dispersion_Wavenumber(omega_comp(i), depth, gravity, k, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      phase = 2.0_wp*pi*MOD(REAL(i*i + 3*i, wp)*golden, CD_ONE)
      theta = k*x_along - omega_comp(i)*t + phase
      CALL reference_profile_ratios(k, depth, z_eval, cosh_ratio, sinh_ratio)
      amp = amplitude(i)*omega_comp(i)
      velocity(1) = velocity(1) + amp*cosh_ratio*COS(theta)*cb
      velocity(2) = velocity(2) + amp*cosh_ratio*COS(theta)*sb
      velocity(3) = velocity(3) + amp*sinh_ratio*SIN(theta)
      amp = amplitude(i)*omega_comp(i)*omega_comp(i)
      acceleration(1) = acceleration(1) + amp*cosh_ratio*SIN(theta)*cb
      acceleration(2) = acceleration(2) + amp*cosh_ratio*SIN(theta)*sb
      acceleration(3) = acceleration(3) - amp*sinh_ratio*COS(theta)
    END DO
  END SUBROUTINE reference_jonswap_kinematics

  SUBROUTINE reference_profile_ratios(k, depth, z_eval, cosh_ratio, sinh_ratio)
    REAL(wp), INTENT(IN) :: k, depth, z_eval
    REAL(wp), INTENT(OUT) :: cosh_ratio, sinh_ratio

    REAL(wp) :: kd, kz, e_kz, e_neg, denom

    kd = k*depth
    kz = k*z_eval
    e_kz = EXP(kz)
    e_neg = EXP(-(kz + 2.0_wp*kd))
    denom = CD_ONE - EXP(-2.0_wp*kd)
    cosh_ratio = (e_kz + e_neg)/denom
    sinh_ratio = (e_kz - e_neg)/denom
  END SUBROUTINE reference_profile_ratios

  SUBROUTINE test_element_kernels_validated_path()
    !! inputs_validated (the model hot path) skips only the per-element input scan: on valid
    !! inputs every output, status and message of each element kernel is bit-for-bit the
    !! default call's, including the failures that remain possible -- a collapsed element and
    !! finite end nodes whose chord length overflows (the tangent check of the Froude-Krylov
    !! and added-mass per-length forms).
    CHARACTER(*), PARAMETER :: NO_DIRECTION = 'CableDyn_Hydro: tangent must be a non-zero direction'
    INTEGER :: icase, es1, es2
    REAL(wp) :: q(6), v(6), accel(3, 2), fluid(3, 2), acc6(6), wl(2), l0
    REAL(wp) :: f1(6), f2(6), jq1(6, 6), jq2(6, 6), jv1(6, 6), jv2(6, 6)
    CHARACTER(160) :: em1, em2
    CHARACTER(40) :: label

    fluid(:, 1) = [0.8_wp, 0.1_wp, -0.2_wp]
    fluid(:, 2) = [0.3_wp, 0.6_wp, 0.1_wp]
    accel(:, 1) = [0.5_wp, -0.2_wp, 0.4_wp]
    accel(:, 2) = [-0.1_wp, 0.6_wp, 0.2_wp]
    acc6 = [0.3_wp, -0.1_wp, 0.2_wp, -0.4_wp, 0.5_wp, -0.2_wp]
    v = [0.14_wp, -0.23_wp, 0.04_wp, -0.07_wp, 0.19_wp, -0.11_wp]
    wl = [0.05_wp, -0.02_wp]
    l0 = 1.7_wp
    ! case 4 overflows the chord length on purpose: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    DO icase = 1, 4
      SELECT CASE (icase)
      CASE (1)   ! surface-piercing
        q = [-0.2_wp, 0.1_wp, -0.8_wp, 1.4_wp, -0.3_wp, 0.2_wp]
      CASE (2)   ! fully wet
        q = [0.1_wp, -0.2_wp, -2.6_wp, 1.2_wp, 0.4_wp, -1.25_wp]
      CASE (3)   ! collapsed
        q = [0.3_wp, 0.3_wp, -1.0_wp, 0.3_wp, 0.3_wp, -1.0_wp]
      CASE DEFAULT   ! finite ends, overflowing chord length
        q = [-1.0e300_wp, 0.0_wp, -1.0_wp, 1.0e300_wp, 0.0_wp, -1.0_wp]
      END SELECT
      WRITE (label, '(A,I0,A)') 'validated-path case ', icase, ': '

      CALL CD_Morison_Drag_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0, fluid(:, 1), fluid(:, 2), &
                                        wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.05_wp, 0.32_wp, f1, jq1, jv1, es1, em1)
      CALL CD_Morison_Drag_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0, fluid(:, 1), fluid(:, 2), &
                                        wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.05_wp, 0.32_wp, f2, jq2, jv2, es2, em2, &
                                        inputs_validated=.TRUE.)
      CALL require(same_bits(f1, f2) .AND. same_bits(jq1, jq2) .AND. same_bits(jv1, jv2) .AND. &
                   es1 == es2 .AND. em1 == em2, TRIM(label)//'drag load')
      CALL CD_Morison_Drag_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0, fluid(:, 1), fluid(:, 2), &
                                         wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.05_wp, 0.32_wp, f1, es1, em1)
      CALL CD_Morison_Drag_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0, fluid(:, 1), fluid(:, 2), &
                                         wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.05_wp, 0.32_wp, f2, es2, em2, &
                                         inputs_validated=.TRUE.)
      CALL require(same_bits(f1, f2) .AND. es1 == es2 .AND. em1 == em2, TRIM(label)//'drag force')

      CALL CD_Froude_Krylov_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0, accel(:, 1), accel(:, 2), &
                                         wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, f1, jq1, jv1, es1, em1)
      CALL CD_Froude_Krylov_Element_Load(q(1:3), q(4:6), v(1:3), v(4:6), l0, accel(:, 1), accel(:, 2), &
                                         wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, f2, jq2, jv2, es2, em2, &
                                         inputs_validated=.TRUE.)
      CALL require(same_bits(f1, f2) .AND. same_bits(jq1, jq2) .AND. same_bits(jv1, jv2) .AND. &
                   es1 == es2 .AND. em1 == em2, TRIM(label)//'FK load')
      CALL require(nan_max_abs(jv2) <= CD_ZERO, TRIM(label)//'FK load has no velocity Jacobian')
      CALL CD_Froude_Krylov_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0, accel(:, 1), accel(:, 2), &
                                          wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, f1, es1, em1)
      CALL CD_Froude_Krylov_Element_Force(q(1:3), q(4:6), v(1:3), v(4:6), l0, accel(:, 1), accel(:, 2), &
                                          wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, f2, es2, em2, &
                                          inputs_validated=.TRUE.)
      CALL require(same_bits(f1, f2) .AND. es1 == es2 .AND. em1 == em2, TRIM(label)//'FK force')
      IF (icase == 4) CALL require(es2 == CD_HYDRO_BADINPUT .AND. em2 == NO_DIRECTION, &
                                   TRIM(label)//'FK force tangent check')

      CALL CD_Buoyancy_Recovery_Element_Load(q(1:3), q(4:6), l0, wl(1), wl(2), 1025.0_wp, 0.24_wp, 9.80665_wp, &
                                             f1, jq1, jv1, es1, em1)
      CALL CD_Buoyancy_Recovery_Element_Load(q(1:3), q(4:6), l0, wl(1), wl(2), 1025.0_wp, 0.24_wp, 9.80665_wp, &
                                             f2, jq2, jv2, es2, em2, inputs_validated=.TRUE.)
      CALL require(same_bits(f1, f2) .AND. same_bits(jq1, jq2) .AND. same_bits(jv1, jv2) .AND. &
                   es1 == es2 .AND. em1 == em2, TRIM(label)//'buoyancy load')
      CALL require(nan_max_abs(jv2) <= CD_ZERO, TRIM(label)//'buoyancy load has no velocity Jacobian')
      CALL CD_Buoyancy_Recovery_Element_Force(q(1:3), q(4:6), l0, wl(1), wl(2), 1025.0_wp, 0.24_wp, 9.80665_wp, &
                                              f1, es1, em1)
      CALL CD_Buoyancy_Recovery_Element_Force(q(1:3), q(4:6), l0, wl(1), wl(2), 1025.0_wp, 0.24_wp, 9.80665_wp, &
                                              f2, es2, em2, inputs_validated=.TRUE.)
      CALL require(same_bits(f1, f2) .AND. es1 == es2 .AND. em1 == em2, TRIM(label)//'buoyancy force')

      CALL CD_Added_Mass_Element(q(1:3), q(4:6), acc6(1:3), acc6(4:6), l0, wl(1), wl(2), &
                                 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, jq1, jv1, es1, em1)
      CALL CD_Added_Mass_Element(q(1:3), q(4:6), acc6(1:3), acc6(4:6), l0, wl(1), wl(2), &
                                 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, jq2, jv2, es2, em2, inputs_validated=.TRUE.)
      CALL require(same_bits(jq1, jq2) .AND. same_bits(jv1, jv2) .AND. es1 == es2 .AND. em1 == em2, &
                   TRIM(label)//'added mass')
      CALL CD_Added_Mass_Element_Matrix(q(1:3), q(4:6), l0, wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, &
                                        jq1, es1, em1)
      CALL CD_Added_Mass_Element_Matrix(q(1:3), q(4:6), l0, wl(1), wl(2), 1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, &
                                        jq2, es2, em2, inputs_validated=.TRUE.)
      CALL require(same_bits(jq1, jq2) .AND. es1 == es2 .AND. em1 == em2, TRIM(label)//'added-mass matrix')
      IF (icase == 4) CALL require(es2 == CD_HYDRO_BADINPUT .AND. em2 == NO_DIRECTION, &
                                   TRIM(label)//'added-mass matrix tangent check')
      CALL CD_Added_Mass_Element_Force(q(1:3), q(4:6), acc6(1:3), acc6(4:6), l0, wl(1), wl(2), &
                                       1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, f1, es1, em1)
      CALL CD_Added_Mass_Element_Force(q(1:3), q(4:6), acc6(1:3), acc6(4:6), l0, wl(1), wl(2), &
                                       1025.0_wp, 0.24_wp, 1.1_wp, 0.2_wp, f2, es2, em2, inputs_validated=.TRUE.)
      CALL require(same_bits(f1, f2) .AND. es1 == es2 .AND. em1 == em2, TRIM(label)//'added-mass force')
      IF (icase == 4) CALL require(es2 == CD_HYDRO_BADINPUT .AND. em2 == NO_DIRECTION, &
                                   TRIM(label)//'added-mass force tangent check')
    END DO
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
  END SUBROUTINE test_element_kernels_validated_path

  PURE LOGICAL FUNCTION same_bits(a, b) RESULT(same)
    !! a and b hold the same binary64 values bit for bit (signed zeros and NaNs included).
    REAL(wp), INTENT(IN) :: a(..), b(..)
    INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
    same = .FALSE.
    SELECT RANK (a)
    RANK (1)
      SELECT RANK (b)
      RANK (1)
        same = SIZE(a) == SIZE(b)
        IF (same) same = ALL(TRANSFER(a, [0_I8]) == TRANSFER(b, [0_I8]))
      END SELECT
    RANK (2)
      SELECT RANK (b)
      RANK (2)
        same = SIZE(a) == SIZE(b)
        IF (same) same = ALL(TRANSFER(a, [0_I8]) == TRANSFER(b, [0_I8]))
      END SELECT
    END SELECT
  END FUNCTION same_bits

  SUBROUTINE test_fail_closed()
    REAL(wp) :: force(3), jac_rel(3, 3), jac_tan(3, 3)
    INTEGER :: es
    CHARACTER(160) :: em

    CALL CD_Morison_Drag_Per_Length([1.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], &
                                    1000.0_wp, 0.2_wp, 1.0_wp, 1.0_wp, force, es, em)
    CALL require(es == CD_HYDRO_BADINPUT, 'bad:tangent')
    CALL CD_Morison_Drag_Per_Length([1.0_wp, 0.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], &
                                    -1.0_wp, 0.2_wp, 1.0_wp, 1.0_wp, force, es, em)
    CALL require(es == CD_HYDRO_BADINPUT, 'bad:rho')
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Morison_Drag_Per_Length([0.0_wp, 1.0e154_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], &
                                    1000.0_wp, 0.2_wp, 1.0_wp, 1.0_wp, force, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es == CD_HYDRO_BADINPUT .AND. nan_max_abs(force) <= CD_ZERO, 'bad:drag-overflow-fails-closed')
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Morison_Drag_Per_Length_Jac([0.0_wp, 1.0e154_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], &
                                        1000.0_wp, 0.2_wp, 1.0_wp, 1.0_wp, force, jac_rel, jac_tan, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es == CD_HYDRO_BADINPUT .AND. nan_max_abs(force) <= CD_ZERO .AND. &
                 nan_max_abs(jac_rel) <= CD_ZERO .AND. nan_max_abs(jac_tan) <= CD_ZERO, &
                 'bad:drag-jacobian-overflow-fails-closed')
  END SUBROUTINE test_fail_closed

  SUBROUTINE check_vec(got, want, tol, label)
    REAL(wp), INTENT(IN) :: got(3), want(3), tol
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: err
    err = nan_max_abs(got - want)
    IF (.NOT. (err <= tol)) THEN
      PRINT *, 'FAIL:', TRIM(label), 'err=', err, 'tol=', tol
      PRINT *, 'got =', got
      PRINT *, 'want=', want
      STOP 1
    END IF
  END SUBROUTINE check_vec

  SUBROUTINE check_mat(got, want, tol, label)
    REAL(wp), INTENT(IN) :: got(3, 3), want(3, 3), tol
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: err
    err = nan_max_abs(got - want)
    IF (.NOT. (err <= tol)) THEN
      PRINT *, 'FAIL:', TRIM(label), 'err=', err, 'tol=', tol
      STOP 1
    END IF
  END SUBROUTINE check_mat

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      PRINT *, 'FAIL:', TRIM(label)
      STOP 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hydro
