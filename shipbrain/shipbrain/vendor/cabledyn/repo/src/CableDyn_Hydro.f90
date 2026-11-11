! File: src/CableDyn_Hydro.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Hydro
  !! Morison hydrodynamic section primitives and regular Airy-wave kinematics for
  !! the Fortran production core. It provides the dynamic load set described in
  !! ARCHITECTURE.md and doc/coupling_boundary.md: the Morison and
  !! wave-kinematics primitives consumed by CableDyn_Dynamic.
  !!
  !! References:
  !! * Classical line convention for normal/tangential Morison decomposition:
  !!   transverse drag uses projected width d, tangential drag uses wetted
  !!   perimeter pi d, added mass uses rho A (Can (I - qq^T) + Cat qq^T).
  !! * Dean & Dalrymple (1991), linear Airy wave theory.
  !! * Wheeler (1970), vertical stretching through the splash zone.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_WaveMath, ONLY: CD_Wave_SinCos, CD_Wave_Exp, CD_Wave_Sum_Lanes, NLANE => CD_WAVE_LANES
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_HYDRO_OK, CD_HYDRO_BADINPUT
  PUBLIC :: CD_Split_Normal_Tangential
  PUBLIC :: CD_Morison_Drag_Per_Length
  PUBLIC :: CD_Morison_Drag_Per_Length_Jac
  PUBLIC :: CD_Morison_Added_Mass_Per_Length
  PUBLIC :: CD_Froude_Krylov_Per_Length
  PUBLIC :: CD_Solve_Dispersion_Wavenumber
  PUBLIC :: CD_Current_Profile_Velocity
  PUBLIC :: CD_CurrentGridType, CD_Current_Grid_Resample, CD_Current_Grid_Velocity
  PUBLIC :: CD_Current_Grid_Gradient, CD_Current_Profile_Gradient
  PUBLIC :: CD_SeaState_Steady_Current
  PUBLIC :: CD_Airy_Wave_Kinematics
  PUBLIC :: CD_Airy_Wave_Kinematics_Precomputed
  PUBLIC :: CD_JONSWAP_Wave_Kinematics
  PUBLIC :: CD_JONSWAP_Wave_Precompute
  PUBLIC :: CD_JONSWAP_Wave_Kinematics_Precomputed
  PUBLIC :: CD_JONSWAP_Random_Components
  PUBLIC :: CD_JONSWAP_COMPONENTS
  PUBLIC :: CD_Component_Wave_Kinematics
  PUBLIC :: CD_Cable_Morison_Drag_Load
  PUBLIC :: CD_Cable_Morison_Drag_Force
  PUBLIC :: CD_Morison_Drag_Element_Load
  PUBLIC :: CD_Morison_Drag_Element_Force
  PUBLIC :: CD_Cable_Froude_Krylov_Load
  PUBLIC :: CD_Cable_Froude_Krylov_Force
  PUBLIC :: CD_Froude_Krylov_Element_Load
  PUBLIC :: CD_Froude_Krylov_Element_Force
  PUBLIC :: CD_Cable_Buoyancy_Recovery_Load
  PUBLIC :: CD_Cable_Buoyancy_Recovery_Force
  PUBLIC :: CD_Buoyancy_Recovery_Element_Load
  PUBLIC :: CD_Buoyancy_Recovery_Element_Force
  PUBLIC :: CD_Cable_Added_Mass
  PUBLIC :: CD_Cable_Added_Mass_Matrix
  PUBLIC :: CD_Cable_Added_Mass_Force
  PUBLIC :: CD_Added_Mass_Element
  PUBLIC :: CD_Added_Mass_Element_Matrix
  PUBLIC :: CD_Added_Mass_Element_Force
  PUBLIC :: CD_Submerged_Fraction

  INTEGER, PARAMETER :: CD_HYDRO_OK = 0
  INTEGER, PARAMETER :: CD_HYDRO_BADINPUT = 1
  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  REAL(wp), PARAMETER :: DEG2RAD = PI/180.0_wp
  REAL(wp), PARAMETER :: MIN_TANGENT_NORM = 1.0e-12_wp
  INTEGER, PARAMETER :: CD_JONSWAP_COMPONENTS = 200
  ! largest resampled current grid (nx ny nz nt samples of three velocity components, 48 MB):
  ! every static current object (each line's static solve) holds its own copy of the grid
  INTEGER(INT64), PARAMETER :: MAX_CURRENT_GRID_SAMPLES = 2000000_INT64

  ! A current tabulated on a rectilinear grid in space and time, as MoorDyn-C (v2.7.1) holds its
  ! time-varying currents (moordyn::waves::CurrentGrid of source/Waves.hpp): coordinates x, y, z
  ! (each strictly increasing; a single coordinate makes the current uniform along that axis) and
  ! velocity(:, i, j, k, n) at (x(i), y(j), z(k)) and time (n - 1) dt, n = 1..nt. The MoorDyn-C
  ! tables are resampled onto this uniform time base by CD_Current_Grid_Resample and evaluated by
  ! CD_Current_Grid_Velocity, which mirror constructDynamicCurrentGrid / construct4DCurrentGrid
  ! (source/Waves/WaveGrid.cpp) and CurrentGrid::getCurrentKin (source/Waves.cpp). The fluid
  ! acceleration of such a current is zero, as MoorDyn-C sets it.
  TYPE :: CD_CurrentGridType
    REAL(wp), ALLOCATABLE :: x(:), y(:), z(:)
    REAL(wp) :: dt = 1.0_wp
    INTEGER :: nt = 1
    REAL(wp), ALLOCATABLE :: velocity(:, :, :, :, :)
  END TYPE CD_CurrentGridType

CONTAINS

  SUBROUTINE CD_SeaState_Steady_Current(z, depth, currmod, curr_ss_v0, curr_ss_dir, &
                                        curr_ns_ref, curr_ns_v0, curr_ns_dir, &
                                        curr_di_v, curr_di_dir, velocity, ErrStat, ErrMsg)
    !! Reproduce SeaState's built-in steady-current contribution so a coupled
    !! WaterKin request can separate host waves from host currents. CurrMod=2 is
    !! intentionally rejected: its private UserCurrent callback is not
    !! observable through WaveField and therefore cannot be decomposed safely.
    REAL(wp), INTENT(IN) :: z, depth, curr_ss_v0, curr_ss_dir
    REAL(wp), INTENT(IN) :: curr_ns_ref, curr_ns_v0, curr_ns_dir, curr_di_v, curr_di_dir
    INTEGER, INTENT(IN) :: currmod
    REAL(wp), INTENT(OUT) :: velocity(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: curr_ss_v, curr_ns_v

    velocity = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. ALL(CD_Is_Finite([z, depth, curr_ss_v0, curr_ss_dir, curr_ns_ref, &
                                curr_ns_v0, curr_ns_dir, curr_di_v, curr_di_dir]))) THEN
      CALL fail(ErrStat, ErrMsg, 'SeaState steady-current inputs must be finite')
      RETURN
    END IF
    IF (depth <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'SeaState steady-current depth must be positive')
      RETURN
    END IF
    SELECT CASE (currmod)
    CASE (0)
      RETURN
    CASE (1)
      IF (curr_ns_ref <= CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'SeaState near-surface current reference depth must be positive')
        RETURN
      END IF
      IF (z < -depth .OR. z > CD_ZERO) RETURN
      curr_ss_v = curr_ss_v0*((z + depth)/depth)**(CD_ONE/7.0_wp)
      curr_ns_v = MAX(curr_ns_v0*((z + curr_ns_ref)/curr_ns_ref), CD_ZERO)
      velocity(1) = curr_di_v*COS(curr_di_dir*DEG2RAD) + &
                    curr_ss_v*COS(curr_ss_dir*DEG2RAD) + curr_ns_v*COS(curr_ns_dir*DEG2RAD)
      velocity(2) = curr_di_v*SIN(curr_di_dir*DEG2RAD) + &
                    curr_ss_v*SIN(curr_ss_dir*DEG2RAD) + curr_ns_v*SIN(curr_ns_dir*DEG2RAD)
    CASE DEFAULT
      CALL fail(ErrStat, ErrMsg, 'SeaState CurrMod 2 user current cannot be separated from host waves')
    END SELECT
  END SUBROUTINE CD_SeaState_Steady_Current

  SUBROUTINE CD_Cable_Morison_Drag_Load(q, v, elem_conn, l0, fluid_velocity, waterline_z, &
                                        rho, diameter, cdn, cdt, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Assemble dynamic Morison drag over an EI=0 cable mesh.
    !!
    !! The returned `force` is the external load to subtract from the residual.
    !! `jac_q` and `jac_v` are residual-Jacobian contributions, i.e.
    !! `-d(force)/dq` and `-d(force)/dv`, matching CD_Cable_Dynamic_Load_Proc.
    !! The Jacobians are assembled from the closed-form section drag tangent,
    !! including wet-fraction, wet-end interpolation, tangent-direction, and
    !! relative-velocity derivatives.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), fluid_velocity(:, :), waterline_z(:)
    REAL(wp), INTENT(IN) :: rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof, n_nodes, n_elem, e, a, b, ia, ib, k, col_a, col_b
    REAL(wp) :: nodes(3, SIZE(q)/3), vel(3, SIZE(q)/3)
    REAL(wp) :: frac, dfrac_da, dfrac_db, chord(3), length, tangent(3), rel(3), f_per_len(3), Jrel(3, 3)
    REAL(wp) :: za, zb, wa, wb, dwa_da, dwa_db, dwb_da, dwb_db, scale, dscale, drel(3), dt(3), df(3)
    REAL(wp) :: eye(3, 3), proj(3, 3), ga(3), gb(3)

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(v) /= n_dof .OR. &
        SIZE(force) /= n_dof .OR. SIZE(jac_q, 1) /= n_dof .OR. SIZE(jac_q, 2) /= n_dof .OR. &
        SIZE(jac_v, 1) /= n_dof .OR. SIZE(jac_v, 2) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/v/force/Jacobian shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(fluid_velocity, 1) /= 3 .OR. &
        SIZE(fluid_velocity, 2) /= n_nodes .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad mesh/load-field shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(fluid_velocity) .OR. .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, l0, fluid_velocity, and waterline_z must be finite')
      RETURN
    END IF
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(cdn) .AND. CD_Is_Finite(cdt) .AND. cdn >= CD_ZERO .AND. cdt >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'drag coefficients must be finite and non-negative')
      RETURN
    END IF

    CALL assemble_drag_force_only(q, v, elem_conn, l0, fluid_velocity, waterline_z, &
                                  rho, diameter, cdn, cdt, force, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN

    nodes = RESHAPE(q, [3, n_nodes])
    vel = RESHAPE(v, [3, n_nodes])
    eye = identity3()
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > n_nodes .OR. b < 1 .OR. b > n_nodes .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_with_derivatives(za, zb, frac, dfrac_da, dfrac_db)
      IF (frac <= CD_ZERO) CYCLE
      chord = nodes(:, b) - nodes(:, a)
      length = SQRT(DOT_PRODUCT(chord, chord))
      IF (length <= MIN_TANGENT_NORM) THEN
        CALL fail(ErrStat, ErrMsg, 'drag element collapsed to zero length')
        RETURN
      END IF
      tangent = chord/length
      CALL wet_endpoint_weights(za, zb, frac, dfrac_da, dfrac_db, wa, wb, dwa_da, dwa_db, dwb_da, dwb_db)
      ga = fluid_velocity(:, a) - vel(:, a)
      gb = fluid_velocity(:, b) - vel(:, b)
      rel = wa*ga + wb*gb
      CALL drag_per_length_with_jacobian(rel, tangent, rho, diameter, cdn, cdt, f_per_len, Jrel, .TRUE.)
      scale = 0.5_wp*l0(e)*frac
      ia = 3*a - 2
      ib = 3*b - 2
      proj = (eye - outer3(tangent, tangent))/length

      DO k = 1, 3
        col_a = ia + k - 1
        col_b = ib + k - 1
        dt = -proj(:, k)
        drel = CD_ZERO
        dscale = CD_ZERO
        IF (k == 3) THEN
          drel = dwa_da*ga + dwb_da*gb
          dscale = 0.5_wp*l0(e)*dfrac_da
        END IF
        CALL drag_tangent_directional(rel, tangent, rho, diameter, cdn, cdt, dt, df)
        df = dscale*f_per_len + scale*(MATMUL(Jrel, drel) + df)
        jac_q(ia:ia + 2, col_a) = jac_q(ia:ia + 2, col_a) - df
        jac_q(ib:ib + 2, col_a) = jac_q(ib:ib + 2, col_a) - df

        dt = proj(:, k)
        drel = CD_ZERO
        dscale = CD_ZERO
        IF (k == 3) THEN
          drel = dwa_db*ga + dwb_db*gb
          dscale = 0.5_wp*l0(e)*dfrac_db
        END IF
        CALL drag_tangent_directional(rel, tangent, rho, diameter, cdn, cdt, dt, df)
        df = dscale*f_per_len + scale*(MATMUL(Jrel, drel) + df)
        jac_q(ia:ia + 2, col_b) = jac_q(ia:ia + 2, col_b) - df
        jac_q(ib:ib + 2, col_b) = jac_q(ib:ib + 2, col_b) - df

        drel = -wa*eye(:, k)
        df = scale*MATMUL(Jrel, drel)
        jac_v(ia:ia + 2, col_a) = jac_v(ia:ia + 2, col_a) - df
        jac_v(ib:ib + 2, col_a) = jac_v(ib:ib + 2, col_a) - df
        drel = -wb*eye(:, k)
        df = scale*MATMUL(Jrel, drel)
        jac_v(ia:ia + 2, col_b) = jac_v(ia:ia + 2, col_b) - df
        jac_v(ib:ib + 2, col_b) = jac_v(ib:ib + 2, col_b) - df
      END DO
    END DO
  END SUBROUTINE CD_Cable_Morison_Drag_Load

  SUBROUTINE CD_Cable_Morison_Drag_Force(q, v, elem_conn, l0, fluid_velocity, waterline_z, &
                                         rho, diameter, cdn, cdt, force, ErrStat, ErrMsg)
    !! Assemble only the dynamic Morison drag force over an EI=0 cable mesh.
    !! This is the residual-only path for Armijo / convergence checks; it skips
    !! the Jacobian assembly performed by CD_Cable_Morison_Drag_Load.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), fluid_velocity(:, :), waterline_z(:)
    REAL(wp), INTENT(IN) :: rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof

    CALL validate_cable_force_shapes(q, v, elem_conn, l0, fluid_velocity, waterline_z, &
                                     force, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(cdn) .AND. CD_Is_Finite(cdt) .AND. cdn >= CD_ZERO .AND. cdt >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'drag coefficients must be finite and non-negative')
      RETURN
    END IF
    CALL assemble_drag_force_only(q, v, elem_conn, l0, fluid_velocity, waterline_z, &
                                  rho, diameter, cdn, cdt, force, ErrStat, ErrMsg)
  END SUBROUTINE CD_Cable_Morison_Drag_Force

  SUBROUTINE CD_Morison_Drag_Element_Load(qa, qb, va, vb, l0, fluid_a, fluid_b, wl_a, wl_b, &
                                          rho, diameter, cdn, cdt, force, jac_q, jac_v, ErrStat, ErrMsg, &
                                          inputs_validated)
    !! Two-node Morison drag element kernel for performance-critical model assembly.
    !!
    !! This routine is formula-identical to the one-element path of
    !! CD_Cable_Morison_Drag_Load, but avoids cable-wide shape validation and
    !! reshape/scatter work inside Newton iterations.
    !! `inputs_validated` is an internal hot-path contract (as in CD_Component_Wave_Kinematics),
    !! shared by the element kernels below: a caller that already guarantees finite state,
    !! fields and waterlines, a positive l0 and valid section scalars skips the per-element
    !! input scan. The default remains full validation for public/direct calls.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3), l0, fluid_a(3), fluid_b(3), wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(6), jac_q(6, 6), jac_v(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated
    INTEGER :: k
    REAL(wp) :: za, zb, frac, dfrac_da, dfrac_db, chord(3), length, tangent(3)
    REAL(wp) :: wa, wb, dwa_da, dwa_db, dwb_da, dwb_db, rel(3), f_per_len(3), Jrel(3, 3)
    REAL(wp) :: ga(3), gb(3), scale, dscale, drel(3), df(3), proj(3, 3)

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_drag_element_inputs(qa, qb, va, vb, l0, fluid_a, fluid_b, wl_a, wl_b, &
                                        rho, diameter, cdn, cdt, ErrStat, ErrMsg)
    END IF
    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN

    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_with_derivatives(za, zb, frac, dfrac_da, dfrac_db)
    IF (frac <= CD_ZERO) RETURN
    chord = qb - qa
    length = SQRT(DOT_PRODUCT(chord, chord))
    IF (length <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'drag element collapsed to zero length')
      RETURN
    END IF
    tangent = chord/length
    CALL wet_endpoint_weights(za, zb, frac, dfrac_da, dfrac_db, wa, wb, dwa_da, dwa_db, dwb_da, dwb_db)
    ga = fluid_a - va
    gb = fluid_b - vb
    rel = wa*ga + wb*gb
    CALL drag_per_length_with_jacobian(rel, tangent, rho, diameter, cdn, cdt, f_per_len, Jrel, .TRUE.)
    scale = 0.5_wp*l0*frac
    force(1:3) = scale*f_per_len
    force(4:6) = scale*f_per_len

    ! Closed-form tangent Jacobian Jt = d f_per_len / d t (drag_tangent_directional applied
    ! to the three unit directions at once), chained through dt/dqa = -P and dt/dqb = +P
    ! with P = (I - t t^T)/length. jac = -d(load)/dq, identical rows for both end nodes.
    BLOCK
      REAL(wp) :: cn, ct, alpha, nvec(3), nmag, nt, Jt(3, 3), JtP(3, 3), aa
      INTEGER :: i, j
      cn = 0.5_wp*rho*diameter*cdn
      ct = 0.5_wp*rho*PI*diameter*cdt
      alpha = DOT_PRODUCT(rel, tangent)
      nvec = rel - alpha*tangent
      nmag = SQRT(DOT_PRODUCT(nvec, nvec))
      nt = DOT_PRODUCT(nvec, tangent)
      aa = ABS(alpha)
      Jt = CD_ZERO
      IF (nmag > MIN_TANGENT_NORM) THEN
        DO j = 1, 3
          DO i = 1, 3
            Jt(i, j) = -cn*(nmag*tangent(i)*rel(j) + (rel(j)*nt + alpha*nvec(j))*nvec(i)/nmag)
          END DO
          Jt(j, j) = Jt(j, j) - cn*nmag*alpha
        END DO
      END IF
      IF (aa > MIN_TANGENT_NORM) THEN
        DO j = 1, 3
          DO i = 1, 3
            Jt(i, j) = Jt(i, j) + ct*2.0_wp*aa*tangent(i)*rel(j)
          END DO
          Jt(j, j) = Jt(j, j) + ct*aa*alpha
        END DO
      END IF
      DO j = 1, 3
        DO i = 1, 3
          proj(i, j) = -tangent(i)*tangent(j)/length
        END DO
        proj(j, j) = proj(j, j) + CD_ONE/length
      END DO
      DO j = 1, 3
        DO i = 1, 3
          JtP(i, j) = scale*(Jt(i, 1)*proj(1, j) + Jt(i, 2)*proj(2, j) + Jt(i, 3)*proj(3, j))
        END DO
      END DO
      DO k = 1, 3
        jac_q(1:3, k) = JtP(:, k)
        jac_q(1:3, 3 + k) = -JtP(:, k)
        jac_v(1:3, k) = (scale*wa)*Jrel(:, k)
        jac_v(1:3, 3 + k) = (scale*wb)*Jrel(:, k)
      END DO
      ! wetted-fraction terms act through the end-node z coordinates only
      IF (ABS(dfrac_da) > CD_ZERO .OR. ABS(dfrac_db) > CD_ZERO) THEN
        drel = dwa_da*ga + dwb_da*gb
        dscale = 0.5_wp*l0*dfrac_da
        df = dscale*f_per_len + scale*MATMUL(Jrel, drel)
        jac_q(1:3, 3) = jac_q(1:3, 3) - df
        drel = dwa_db*ga + dwb_db*gb
        dscale = 0.5_wp*l0*dfrac_db
        df = dscale*f_per_len + scale*MATMUL(Jrel, drel)
        jac_q(1:3, 6) = jac_q(1:3, 6) - df
      END IF
      jac_q(4:6, :) = jac_q(1:3, :)
      jac_v(4:6, :) = jac_v(1:3, :)
    END BLOCK
  END SUBROUTINE CD_Morison_Drag_Element_Load

  SUBROUTINE CD_Morison_Drag_Element_Force(qa, qb, va, vb, l0, fluid_a, fluid_b, wl_a, wl_b, &
                                           rho, diameter, cdn, cdt, force, ErrStat, ErrMsg, inputs_validated)
    !! Two-node Morison drag force kernel for residual-only trial evaluations.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3), l0, fluid_a(3), fluid_b(3), wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load
    REAL(wp) :: za, zb, frac, chord(3), length, tangent(3), wa, wb, lower, higher
    REAL(wp) :: fluid_e(3), rel(3), f_per_len(3)

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_drag_element_inputs(qa, qb, va, vb, l0, fluid_a, fluid_b, wl_a, wl_b, &
                                        rho, diameter, cdn, cdt, ErrStat, ErrMsg)
    END IF
    force = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN

    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_only(za, zb, frac)
    IF (frac <= CD_ZERO) RETURN
    chord = qb - qa
    length = SQRT(DOT_PRODUCT(chord, chord))
    IF (length <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'drag element collapsed to zero length')
      RETURN
    END IF
    tangent = chord/length
    higher = 0.5_wp*frac
    lower = CD_ONE - higher
    IF (za <= zb) THEN
      wa = lower
      wb = higher
    ELSE
      wa = higher
      wb = lower
    END IF
    fluid_e = wa*fluid_a + wb*fluid_b
    rel = fluid_e - (wa*va + wb*vb)
    ! inputs validated above: the unguarded per-length primitive the Jacobian kernel uses
    CALL drag_per_length_with_jacobian(rel, tangent, rho, diameter, cdn, cdt, f_per_len, want_jac=.FALSE.)
    IF (.NOT. CD_All_Finite(f_per_len)) THEN
      CALL fail(ErrStat, ErrMsg, 'Morison drag result overflowed')
      RETURN
    END IF
    force(1:3) = 0.5_wp*l0*frac*f_per_len
    force(4:6) = force(1:3)
  END SUBROUTINE CD_Morison_Drag_Element_Force

  SUBROUTINE CD_Cable_Froude_Krylov_Load(q, v, elem_conn, l0, fluid_acceleration, waterline_z, &
                                         rho, diameter, can, cat, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Assemble Froude-Krylov + fluid-inertia wave load over an EI=0 cable mesh.
    !! Per element the per-node force densities are distributed with the
    !! consistent wet-subsegment shape-function integrals. The load is
    !! velocity-independent, so jac_v is zero.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), fluid_acceleration(:, :), waterline_z(:)
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof, n_nodes, n_elem, e, a, b, lo, hi, ilo, ihi, k, col_a, col_b
    REAL(wp) :: nodes(3, SIZE(q)/3)
    REAL(wp) :: frac, df_da, df_db, za, zb, chord(3), length, tangent(3), proj(3, 3), dt(3), zero_dt(3)
    REAL(wp) :: f_lo(3), f_hi(3), df_lo(3), df_hi(3), df_node_lo(3), df_node_hi(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, dc_lolo, dc_lohi, dc_hihi, df_frac
    REAL(wp) :: eye(3, 3)

    CALL validate_cable_load_shapes(q, v, elem_conn, l0, fluid_acceleration, waterline_z, &
                                    force, jac_q, jac_v, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'FK coefficients must be finite and non-negative')
      RETURN
    END IF
    jac_v = CD_ZERO
    CALL assemble_fk_force_only(q, elem_conn, l0, fluid_acceleration, waterline_z, &
                                rho, diameter, can, cat, force, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    nodes = RESHAPE(q, [3, n_nodes])
    eye = identity3()
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > n_nodes .OR. b < 1 .OR. b > n_nodes .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_with_derivatives(za, zb, frac, df_da, df_db)
      IF (frac <= CD_ZERO) CYCLE
      chord = nodes(:, b) - nodes(:, a)
      length = SQRT(DOT_PRODUCT(chord, chord))
      IF (length <= MIN_TANGENT_NORM) THEN
        CALL fail(ErrStat, ErrMsg, 'FK element collapsed to zero length')
        RETURN
      END IF
      tangent = chord/length
      proj = (eye - outer3(tangent, tangent))/length
      IF (za <= zb) THEN
        lo = a
        hi = b
      ELSE
        lo = b
        hi = a
      END IF
      zero_dt = CD_ZERO
      CALL fk_per_length_with_tangent_derivative(fluid_acceleration(:, lo), tangent, rho, diameter, can, cat, &
                                                 zero_dt, f_lo, df_lo)
      CALL fk_per_length_with_tangent_derivative(fluid_acceleration(:, hi), tangent, rho, diameter, can, cat, &
                                                 zero_dt, f_hi, df_hi)
      CALL wet_consistent_coefficients(l0(e), frac, c_lolo, c_lohi, c_hihi)
      ilo = 3*lo - 2
      ihi = 3*hi - 2
      DO k = 1, 3
        col_a = 3*a + k - 3
        col_b = 3*b + k - 3
        dt = -proj(:, k)
        df_frac = CD_ZERO
        IF (k == 3) df_frac = df_da
        CALL wet_consistent_coefficient_derivatives(l0(e), frac, df_frac, dc_lolo, dc_lohi, dc_hihi)
        CALL fk_per_length_with_tangent_derivative(fluid_acceleration(:, lo), tangent, rho, diameter, can, cat, &
                                                   dt, f_lo, df_lo)
        CALL fk_per_length_with_tangent_derivative(fluid_acceleration(:, hi), tangent, rho, diameter, can, cat, &
                                                   dt, f_hi, df_hi)
        df_node_lo = dc_lolo*f_lo + c_lolo*df_lo + dc_lohi*f_hi + c_lohi*df_hi
        df_node_hi = dc_lohi*f_lo + c_lohi*df_lo + dc_hihi*f_hi + c_hihi*df_hi
        jac_q(ilo:ilo + 2, col_a) = jac_q(ilo:ilo + 2, col_a) - df_node_lo
        jac_q(ihi:ihi + 2, col_a) = jac_q(ihi:ihi + 2, col_a) - df_node_hi

        dt = proj(:, k)
        df_frac = CD_ZERO
        IF (k == 3) df_frac = df_db
        CALL wet_consistent_coefficient_derivatives(l0(e), frac, df_frac, dc_lolo, dc_lohi, dc_hihi)
        CALL fk_per_length_with_tangent_derivative(fluid_acceleration(:, lo), tangent, rho, diameter, can, cat, &
                                                   dt, f_lo, df_lo)
        CALL fk_per_length_with_tangent_derivative(fluid_acceleration(:, hi), tangent, rho, diameter, can, cat, &
                                                   dt, f_hi, df_hi)
        df_node_lo = dc_lolo*f_lo + c_lolo*df_lo + dc_lohi*f_hi + c_lohi*df_hi
        df_node_hi = dc_lohi*f_lo + c_lohi*df_lo + dc_hihi*f_hi + c_hihi*df_hi
        jac_q(ilo:ilo + 2, col_b) = jac_q(ilo:ilo + 2, col_b) - df_node_lo
        jac_q(ihi:ihi + 2, col_b) = jac_q(ihi:ihi + 2, col_b) - df_node_hi
      END DO
    END DO
  END SUBROUTINE CD_Cable_Froude_Krylov_Load

  SUBROUTINE CD_Cable_Froude_Krylov_Force(q, v, elem_conn, l0, fluid_acceleration, waterline_z, &
                                          rho, diameter, can, cat, force, ErrStat, ErrMsg)
    !! Assemble only the Froude-Krylov + fluid-inertia force over an EI=0 cable mesh.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), fluid_acceleration(:, :), waterline_z(:)
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof

    CALL validate_cable_force_shapes(q, v, elem_conn, l0, fluid_acceleration, waterline_z, &
                                     force, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'FK coefficients must be finite and non-negative')
      RETURN
    END IF
    CALL assemble_fk_force_only(q, elem_conn, l0, fluid_acceleration, waterline_z, &
                                rho, diameter, can, cat, force, ErrStat, ErrMsg)
  END SUBROUTINE CD_Cable_Froude_Krylov_Force

  SUBROUTINE CD_Froude_Krylov_Element_Load(qa, qb, va, vb, l0, accel_a, accel_b, wl_a, wl_b, &
                                           rho, diameter, can, cat, force, jac_q, jac_v, ErrStat, ErrMsg, &
                                           inputs_validated)
    !! Two-node Froude-Krylov/fluid-inertia load and residual Jacobian.
    !! The load is velocity-independent: jac_v is identically zero.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3), l0, accel_a(3), accel_b(3), wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(6), jac_q(6, 6), jac_v(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load
    INTEGER :: k, lo0, hi0, col_a, col_b
    REAL(wp) :: za, zb, frac, df_da, df_db, chord(3), length, tangent(3), proj(3, 3), dt(3), zero_dt(3)
    REAL(wp) :: f_lo(3), f_hi(3), df_lo(3), df_hi(3), df_node_lo(3), df_node_hi(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, dc_lolo, dc_lohi, dc_hihi, df_frac, eye(3, 3)
    REAL(wp) :: acc_lo(3), acc_hi(3)

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_fk_element_inputs(qa, qb, va, vb, l0, accel_a, accel_b, wl_a, wl_b, &
                                      rho, diameter, can, cat, ErrStat, ErrMsg)
    END IF
    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_with_derivatives(za, zb, frac, df_da, df_db)
    IF (frac <= CD_ZERO) RETURN
    chord = qb - qa
    length = SQRT(DOT_PRODUCT(chord, chord))
    IF (length <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'FK element collapsed to zero length')
      RETURN
    END IF
    tangent = chord/length
    eye = identity3()
    proj = (eye - outer3(tangent, tangent))/length
    IF (za <= zb) THEN
      lo0 = 1
      hi0 = 4
      acc_lo = accel_a
      acc_hi = accel_b
    ELSE
      lo0 = 4
      hi0 = 1
      acc_lo = accel_b
      acc_hi = accel_a
    END IF

    zero_dt = CD_ZERO
    CALL fk_per_length_with_tangent_derivative(acc_lo, tangent, rho, diameter, can, cat, zero_dt, f_lo, df_lo)
    CALL fk_per_length_with_tangent_derivative(acc_hi, tangent, rho, diameter, can, cat, zero_dt, f_hi, df_hi)
    CALL wet_consistent_coefficients(l0, frac, c_lolo, c_lohi, c_hihi)
    force(lo0:lo0 + 2) = c_lolo*f_lo + c_lohi*f_hi
    force(hi0:hi0 + 2) = c_lohi*f_lo + c_hihi*f_hi

    DO k = 1, 3
      col_a = k
      col_b = 3 + k
      dt = -proj(:, k)
      df_frac = CD_ZERO
      IF (k == 3) df_frac = df_da
      CALL wet_consistent_coefficient_derivatives(l0, frac, df_frac, dc_lolo, dc_lohi, dc_hihi)
      CALL fk_per_length_with_tangent_derivative(acc_lo, tangent, rho, diameter, can, cat, dt, f_lo, df_lo)
      CALL fk_per_length_with_tangent_derivative(acc_hi, tangent, rho, diameter, can, cat, dt, f_hi, df_hi)
      df_node_lo = dc_lolo*f_lo + c_lolo*df_lo + dc_lohi*f_hi + c_lohi*df_hi
      df_node_hi = dc_lohi*f_lo + c_lohi*df_lo + dc_hihi*f_hi + c_hihi*df_hi
      jac_q(lo0:lo0 + 2, col_a) = jac_q(lo0:lo0 + 2, col_a) - df_node_lo
      jac_q(hi0:hi0 + 2, col_a) = jac_q(hi0:hi0 + 2, col_a) - df_node_hi

      dt = proj(:, k)
      df_frac = CD_ZERO
      IF (k == 3) df_frac = df_db
      CALL wet_consistent_coefficient_derivatives(l0, frac, df_frac, dc_lolo, dc_lohi, dc_hihi)
      CALL fk_per_length_with_tangent_derivative(acc_lo, tangent, rho, diameter, can, cat, dt, f_lo, df_lo)
      CALL fk_per_length_with_tangent_derivative(acc_hi, tangent, rho, diameter, can, cat, dt, f_hi, df_hi)
      df_node_lo = dc_lolo*f_lo + c_lolo*df_lo + dc_lohi*f_hi + c_lohi*df_hi
      df_node_hi = dc_lohi*f_lo + c_lohi*df_lo + dc_hihi*f_hi + c_hihi*df_hi
      jac_q(lo0:lo0 + 2, col_b) = jac_q(lo0:lo0 + 2, col_b) - df_node_lo
      jac_q(hi0:hi0 + 2, col_b) = jac_q(hi0:hi0 + 2, col_b) - df_node_hi
    END DO
  END SUBROUTINE CD_Froude_Krylov_Element_Load

  SUBROUTINE CD_Froude_Krylov_Element_Force(qa, qb, va, vb, l0, accel_a, accel_b, wl_a, wl_b, &
                                            rho, diameter, can, cat, force, ErrStat, ErrMsg, inputs_validated)
    !! Two-node Froude-Krylov/fluid-inertia force. The per-length force is
    !! CD_Froude_Krylov_Per_Length evaluated with its shared statements: the section scalars
    !! and accelerations are validated once (or by the caller) and only the tangent checks of
    !! unit_tangent can still fail, so the unit tangent is formed once for both end nodes.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3), l0, accel_a(3), accel_b(3), wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load
    INTEGER :: lo0, hi0
    REAL(wp) :: za, zb, frac, chord(3), length, tangent(3), acc_lo(3), acc_hi(3), f_lo(3), f_hi(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, f, unit(3), normal(3), tangential(3)

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_fk_element_inputs(qa, qb, va, vb, l0, accel_a, accel_b, wl_a, wl_b, &
                                      rho, diameter, can, cat, ErrStat, ErrMsg)
    END IF
    force = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_only(za, zb, frac)
    IF (frac <= CD_ZERO) RETURN
    chord = qb - qa
    length = SQRT(DOT_PRODUCT(chord, chord))
    IF (length <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'FK element collapsed to zero length')
      RETURN
    END IF
    tangent = chord/length
    IF (za <= zb) THEN
      lo0 = 1
      hi0 = 4
      acc_lo = accel_a
      acc_hi = accel_b
    ELSE
      lo0 = 4
      hi0 = 1
      acc_lo = accel_b
      acc_hi = accel_a
    END IF
    CALL unit_tangent(tangent, unit, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL split_about_unit(acc_lo, unit, normal, tangential)
    CALL fk_force_from_split(normal, tangential, rho, diameter, can, cat, f_lo)
    CALL split_about_unit(acc_hi, unit, normal, tangential)
    CALL fk_force_from_split(normal, tangential, rho, diameter, can, cat, f_hi)
    f = frac
    c_lolo = l0*(f - f*f + f**3/3.0_wp)
    c_lohi = l0*(0.5_wp*f*f - f**3/3.0_wp)
    c_hihi = l0*f**3/3.0_wp
    force(lo0:lo0 + 2) = c_lolo*f_lo + c_lohi*f_hi
    force(hi0:hi0 + 2) = c_lohi*f_lo + c_hihi*f_hi
  END SUBROUTINE CD_Froude_Krylov_Element_Force

  SUBROUTINE CD_Cable_Buoyancy_Recovery_Load(q, v, elem_conn, l0, waterline_z, &
                                             rho, diameter, gravity, force, jac_q, jac_v, ErrStat, ErrMsg)
    !! Assemble the wetting-dependent buoyancy recovery load. The constant
    !! submerged-weight vector applies full buoyancy everywhere; this load removes
    !! the over-applied buoyancy on dry portions of surface-piercing elements.
    !! It is velocity-independent, so jac_v is zero.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), waterline_z(:), rho, diameter, gravity
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof, n_nodes, n_elem, e, a, b, iza, izb
    REAL(wp) :: nodes(3, SIZE(q)/3)
    REAL(wp) :: frac, df_da, df_db, za, zb, half_g, buoyancy, drec_da, drec_db

    CALL validate_waterline_load_shapes(q, v, elem_conn, l0, waterline_z, force, jac_q, jac_v, &
                                        n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    n_nodes = n_dof/3
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive')
      RETURN
    END IF
    jac_v = CD_ZERO
    CALL assemble_buoyancy_recovery_force_only(q, elem_conn, l0, waterline_z, &
                                               rho, diameter, gravity, force, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    nodes = RESHAPE(q, [3, n_nodes])
    n_elem = SIZE(elem_conn, 2)
    buoyancy = rho*0.25_wp*PI*diameter*diameter*gravity
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > n_nodes .OR. b < 1 .OR. b > n_nodes .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_with_derivatives(za, zb, frac, df_da, df_db)
      half_g = 0.5_wp*buoyancy*l0(e)
      drec_da = half_g*df_da
      drec_db = half_g*df_db
      iza = 3*a
      izb = 3*b
      jac_q(iza, iza) = jac_q(iza, iza) - drec_da
      jac_q(izb, iza) = jac_q(izb, iza) - drec_da
      jac_q(iza, izb) = jac_q(iza, izb) - drec_db
      jac_q(izb, izb) = jac_q(izb, izb) - drec_db
    END DO
  END SUBROUTINE CD_Cable_Buoyancy_Recovery_Load

  SUBROUTINE CD_Cable_Buoyancy_Recovery_Force(q, v, elem_conn, l0, waterline_z, &
                                              rho, diameter, gravity, force, ErrStat, ErrMsg)
    !! Assemble only the wetting-dependent buoyancy recovery force.
    REAL(wp), INTENT(IN) :: q(:), v(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: l0(:), waterline_z(:), rho, diameter, gravity
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof

    CALL validate_waterline_force_shapes(q, v, elem_conn, l0, waterline_z, force, n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive')
      RETURN
    END IF
    CALL assemble_buoyancy_recovery_force_only(q, elem_conn, l0, waterline_z, &
                                               rho, diameter, gravity, force, ErrStat, ErrMsg)
  END SUBROUTINE CD_Cable_Buoyancy_Recovery_Force

  SUBROUTINE CD_Buoyancy_Recovery_Element_Load(qa, qb, l0, wl_a, wl_b, rho, diameter, gravity, &
                                               force, jac_q, jac_v, ErrStat, ErrMsg, inputs_validated)
    !! Two-node wetting-dependent buoyancy recovery force and residual Jacobian.
    !! The load is velocity-independent: jac_v is identically zero.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), l0, wl_a, wl_b, rho, diameter, gravity
    REAL(wp), INTENT(OUT) :: force(6), jac_q(6, 6), jac_v(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load
    REAL(wp) :: za, zb, frac, df_da, df_db, half_g, recovery, buoyancy, drec_da, drec_db

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_buoyancy_element_inputs(qa, qb, l0, wl_a, wl_b, rho, diameter, gravity, ErrStat, ErrMsg)
    END IF
    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_with_derivatives(za, zb, frac, df_da, df_db)
    buoyancy = rho*0.25_wp*PI*diameter*diameter*gravity
    half_g = 0.5_wp*buoyancy*l0
    recovery = -(CD_ONE - frac)*half_g
    force(3) = recovery
    force(6) = recovery
    drec_da = half_g*df_da
    drec_db = half_g*df_db
    jac_q(3, 3) = jac_q(3, 3) - drec_da
    jac_q(6, 3) = jac_q(6, 3) - drec_da
    jac_q(3, 6) = jac_q(3, 6) - drec_db
    jac_q(6, 6) = jac_q(6, 6) - drec_db
  END SUBROUTINE CD_Buoyancy_Recovery_Element_Load

  SUBROUTINE CD_Buoyancy_Recovery_Element_Force(qa, qb, l0, wl_a, wl_b, rho, diameter, gravity, &
                                                force, ErrStat, ErrMsg, inputs_validated)
    !! Two-node wetting-dependent buoyancy recovery force.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), l0, wl_a, wl_b, rho, diameter, gravity
    REAL(wp), INTENT(OUT) :: force(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load
    REAL(wp) :: za, zb, frac, half_g, recovery, buoyancy

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_buoyancy_element_inputs(qa, qb, l0, wl_a, wl_b, rho, diameter, gravity, ErrStat, ErrMsg)
    END IF
    force = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_only(za, zb, frac)
    buoyancy = rho*0.25_wp*PI*diameter*diameter*gravity
    half_g = 0.5_wp*buoyancy*l0
    recovery = -(CD_ONE - frac)*half_g
    force(3) = recovery
    force(6) = recovery
  END SUBROUTINE CD_Buoyancy_Recovery_Element_Force

  SUBROUTINE CD_Cable_Added_Mass(q, accel, elem_conn, l0, waterline_z, rho, diameter, can, cat, &
                                 M_add, dMa_a_dq, ErrStat, ErrMsg)
    !! Assemble the configuration-dependent Morison added-mass matrix for an
    !! EI=0 cable mesh and the directional derivative d(M_add(q) * accel)/dq.
    !! The matrix uses the same wet-subsegment consistent shape-function
    !! integrals as the consistent load assembly. The derivative is assembled in closed
    !! form from wet-fraction, tangent-direction, and consistent-coefficient
    !! sensitivities.
    REAL(wp), INTENT(IN) :: q(:), accel(:), l0(:), waterline_z(:), rho, diameter, can, cat
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof, n_nodes, n_elem, e, a, b, lo, hi, ilo, ihi, k, col_a, col_b
    REAL(wp) :: nodes(3, SIZE(q)/3)
    REAL(wp) :: frac, df_da, df_db, za, zb, chord(3), length, tangent(3), proj(3, 3), dt(3), zero_dt(3)
    REAL(wp) :: Me(3, 3), dMe(3, 3), acc_lo(3), acc_hi(3), df_lo(3), df_hi(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, dc_lolo, dc_lohi, dc_hihi, df_frac
    REAL(wp) :: eye(3, 3)

    CALL validate_added_mass_shapes(q, accel, elem_conn, l0, waterline_z, M_add, dMa_a_dq, &
                                    n_dof, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass coefficients must be finite and non-negative')
      RETURN
    END IF
    CALL assemble_added_mass_matrix_only(q, elem_conn, l0, waterline_z, rho, diameter, can, cat, &
                                         M_add, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    nodes = RESHAPE(q, [3, n_nodes])
    eye = identity3()
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > n_nodes .OR. b < 1 .OR. b > n_nodes .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_with_derivatives(za, zb, frac, df_da, df_db)
      IF (frac <= CD_ZERO) CYCLE
      chord = nodes(:, b) - nodes(:, a)
      length = SQRT(DOT_PRODUCT(chord, chord))
      IF (length <= MIN_TANGENT_NORM) THEN
        CALL fail(ErrStat, ErrMsg, 'added-mass element collapsed to zero length')
        RETURN
      END IF
      tangent = chord/length
      proj = (eye - outer3(tangent, tangent))/length
      IF (za <= zb) THEN
        lo = a
        hi = b
      ELSE
        lo = b
        hi = a
      END IF
      ilo = 3*lo - 2
      ihi = 3*hi - 2
      acc_lo = accel(ilo:ilo + 2)
      acc_hi = accel(ihi:ihi + 2)
      zero_dt = CD_ZERO
      CALL added_mass_with_tangent_derivative(tangent, rho, diameter, can, cat, zero_dt, Me, dMe)
      CALL wet_consistent_coefficients(l0(e), frac, c_lolo, c_lohi, c_hihi)
      DO k = 1, 3
        col_a = 3*a + k - 3
        col_b = 3*b + k - 3
        dt = -proj(:, k)
        df_frac = CD_ZERO
        IF (k == 3) df_frac = df_da
        CALL wet_consistent_coefficient_derivatives(l0(e), frac, df_frac, dc_lolo, dc_lohi, dc_hihi)
        CALL added_mass_with_tangent_derivative(tangent, rho, diameter, can, cat, dt, Me, dMe)
        df_lo = MATMUL(dc_lolo*Me + c_lolo*dMe, acc_lo) + MATMUL(dc_lohi*Me + c_lohi*dMe, acc_hi)
        df_hi = MATMUL(dc_lohi*Me + c_lohi*dMe, acc_lo) + MATMUL(dc_hihi*Me + c_hihi*dMe, acc_hi)
        dMa_a_dq(ilo:ilo + 2, col_a) = dMa_a_dq(ilo:ilo + 2, col_a) + df_lo
        dMa_a_dq(ihi:ihi + 2, col_a) = dMa_a_dq(ihi:ihi + 2, col_a) + df_hi

        dt = proj(:, k)
        df_frac = CD_ZERO
        IF (k == 3) df_frac = df_db
        CALL wet_consistent_coefficient_derivatives(l0(e), frac, df_frac, dc_lolo, dc_lohi, dc_hihi)
        CALL added_mass_with_tangent_derivative(tangent, rho, diameter, can, cat, dt, Me, dMe)
        df_lo = MATMUL(dc_lolo*Me + c_lolo*dMe, acc_lo) + MATMUL(dc_lohi*Me + c_lohi*dMe, acc_hi)
        df_hi = MATMUL(dc_lohi*Me + c_lohi*dMe, acc_lo) + MATMUL(dc_hihi*Me + c_hihi*dMe, acc_hi)
        dMa_a_dq(ilo:ilo + 2, col_b) = dMa_a_dq(ilo:ilo + 2, col_b) + df_lo
        dMa_a_dq(ihi:ihi + 2, col_b) = dMa_a_dq(ihi:ihi + 2, col_b) + df_hi
      END DO
    END DO
  END SUBROUTINE CD_Cable_Added_Mass

  SUBROUTINE CD_Cable_Added_Mass_Matrix(q, elem_conn, l0, waterline_z, rho, diameter, can, cat, &
                                        M_add, ErrStat, ErrMsg)
    !! Assemble only the configuration-dependent Morison added-mass matrix.
    !! This is useful for quasi-Newton / validation gates that keep the exact
    !! residual and inertia but intentionally omit d(M_add*a)/dq from the tangent.
    REAL(wp), INTENT(IN) :: q(:), l0(:), waterline_z(:), rho, diameter, can, cat
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: M_add(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof, n_nodes, n_elem

    M_add = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(M_add, 1) /= n_dof .OR. SIZE(M_add, 2) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/M_add shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad mesh/waterline shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) &
        .OR. .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, l0, and waterline_z must be finite')
      RETURN
    END IF
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass coefficients must be finite and non-negative')
      RETURN
    END IF
    CALL assemble_added_mass_matrix_only(q, elem_conn, l0, waterline_z, rho, diameter, can, cat, &
                                         M_add, ErrStat, ErrMsg)
  END SUBROUTINE CD_Cable_Added_Mass_Matrix

  SUBROUTINE CD_Cable_Added_Mass_Force(q, accel, elem_conn, l0, waterline_z, rho, diameter, can, cat, &
                                       force, ErrStat, ErrMsg)
    !! Assemble only the product M_add(q)*accel for residual-only evaluations.
    REAL(wp), INTENT(IN) :: q(:), accel(:), l0(:), waterline_z(:), rho, diameter, can, cat
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_dof, n_nodes, n_elem, e, a, b, lo, hi, ilo, ihi
    REAL(wp) :: nodes(3, SIZE(q)/3)
    REAL(wp) :: frac, za, zb, chord(3), length, tangent(3), Me(3, 3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, f, acc_lo(3), acc_hi(3)

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(accel) /= n_dof .OR. SIZE(force) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/accel/force shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad added-mass mesh/waterline shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(accel) .OR. &
        .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, accel, l0, and waterline_z must be finite')
      RETURN
    END IF
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass coefficients must be finite and non-negative')
      RETURN
    END IF

    nodes = RESHAPE(q, [3, n_nodes])
    DO e = 1, n_elem
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > n_nodes .OR. b < 1 .OR. b > n_nodes .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_only(za, zb, frac)
      IF (frac <= CD_ZERO) CYCLE
      chord = nodes(:, b) - nodes(:, a)
      length = SQRT(DOT_PRODUCT(chord, chord))
      IF (length <= MIN_TANGENT_NORM) THEN
        CALL fail(ErrStat, ErrMsg, 'added-mass element collapsed to zero length')
        RETURN
      END IF
      tangent = chord/length
      IF (za <= zb) THEN
        lo = a
        hi = b
      ELSE
        lo = b
        hi = a
      END IF
      ilo = 3*lo - 2
      ihi = 3*hi - 2
      acc_lo = accel(ilo:ilo + 2)
      acc_hi = accel(ihi:ihi + 2)
      CALL CD_Morison_Added_Mass_Per_Length(tangent, rho, diameter, can, cat, Me, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      f = frac
      c_lolo = l0(e)*(f - f*f + f**3/3.0_wp)
      c_lohi = l0(e)*(0.5_wp*f*f - f**3/3.0_wp)
      c_hihi = l0(e)*f**3/3.0_wp
      force(ilo:ilo + 2) = force(ilo:ilo + 2) + c_lolo*MATMUL(Me, acc_lo) + c_lohi*MATMUL(Me, acc_hi)
      force(ihi:ihi + 2) = force(ihi:ihi + 2) + c_lohi*MATMUL(Me, acc_lo) + c_hihi*MATMUL(Me, acc_hi)
    END DO
  END SUBROUTINE CD_Cable_Added_Mass_Force

  SUBROUTINE CD_Added_Mass_Element(qa, qb, accel_a, accel_b, l0, wl_a, wl_b, rho, diameter, can, cat, &
                                   M_add, dMa_a_dq, ErrStat, ErrMsg, inputs_validated)
    !! Two-node added-mass matrix and directional derivative kernel.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), accel_a(3), accel_b(3), l0, wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: M_add(6, 6), dMa_a_dq(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load
    INTEGER :: lo0, hi0
    REAL(wp) :: za, zb, frac, df_da, df_db, chord(3), length, tangent(3), proj(3, 3), zero_dt(3)
    REAL(wp) :: Me(3, 3), dMe(3, 3), acc_lo(3), acc_hi(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, dc_lolo, dc_lohi, dc_hihi, eye(3, 3)

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_added_mass_element_inputs(qa, qb, accel_a, accel_b, l0, wl_a, wl_b, &
                                              rho, diameter, can, cat, ErrStat, ErrMsg)
    END IF
    M_add = CD_ZERO
    dMa_a_dq = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN

    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_with_derivatives(za, zb, frac, df_da, df_db)
    IF (frac <= CD_ZERO) RETURN
    chord = qb - qa
    length = SQRT(DOT_PRODUCT(chord, chord))
    IF (length <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass element collapsed to zero length')
      RETURN
    END IF
    tangent = chord/length
    eye = identity3()
    proj = (eye - outer3(tangent, tangent))/length
    IF (za <= zb) THEN
      lo0 = 1
      hi0 = 4
      acc_lo = accel_a
      acc_hi = accel_b
    ELSE
      lo0 = 4
      hi0 = 1
      acc_lo = accel_b
      acc_hi = accel_a
    END IF

    zero_dt = CD_ZERO
    CALL added_mass_with_tangent_derivative(tangent, rho, diameter, can, cat, zero_dt, Me, dMe)
    CALL wet_consistent_coefficients(l0, frac, c_lolo, c_lohi, c_hihi)
    M_add(lo0:lo0 + 2, lo0:lo0 + 2) = M_add(lo0:lo0 + 2, lo0:lo0 + 2) + c_lolo*Me
    M_add(lo0:lo0 + 2, hi0:hi0 + 2) = M_add(lo0:lo0 + 2, hi0:hi0 + 2) + c_lohi*Me
    M_add(hi0:hi0 + 2, lo0:lo0 + 2) = M_add(hi0:hi0 + 2, lo0:lo0 + 2) + c_lohi*Me
    M_add(hi0:hi0 + 2, hi0:hi0 + 2) = M_add(hi0:hi0 + 2, hi0:hi0 + 2) + c_hihi*Me

    ! Closed form of the directional added-mass derivative: with dMe(dt) x =
    ! c_d (dt (t.x) + t (dt.x)), c_d = rho A (Cat - Can), and dt = -/+ P(:, k), the six
    ! position columns are -/+ [c (t.x) P + c t (P x)^T] for x = acc_lo / acc_hi; the
    ! wetted-fraction derivative adds dc * Me x in the z columns only.
    BLOCK
      REAL(wp) :: cdel, tlo, thi, plo(3), phi(3), Dlo(3, 3), Dhi(3, 3), Blo(3, 3), Bhi(3, 3)
      REAL(wp) :: mlo(3), mhi(3)
      INTEGER :: i, j
      cdel = rho*0.25_wp*PI*diameter*diameter*(cat - can)
      tlo = DOT_PRODUCT(tangent, acc_lo)
      thi = DOT_PRODUCT(tangent, acc_hi)
      plo = MATMUL(proj, acc_lo)
      phi = MATMUL(proj, acc_hi)
      DO j = 1, 3
        DO i = 1, 3
          Dlo(i, j) = cdel*(tlo*proj(i, j) + tangent(i)*plo(j))
          Dhi(i, j) = cdel*(thi*proj(i, j) + tangent(i)*phi(j))
        END DO
      END DO
      Blo = c_lolo*Dlo + c_lohi*Dhi
      Bhi = c_lohi*Dlo + c_hihi*Dhi
      dMa_a_dq(lo0:lo0 + 2, 1:3) = -Blo
      dMa_a_dq(hi0:hi0 + 2, 1:3) = -Bhi
      dMa_a_dq(lo0:lo0 + 2, 4:6) = Blo
      dMa_a_dq(hi0:hi0 + 2, 4:6) = Bhi
      IF (ABS(df_da) > CD_ZERO .OR. ABS(df_db) > CD_ZERO) THEN
        mlo = MATMUL(Me, acc_lo)
        mhi = MATMUL(Me, acc_hi)
        CALL wet_consistent_coefficient_derivatives(l0, frac, df_da, dc_lolo, dc_lohi, dc_hihi)
        dMa_a_dq(lo0:lo0 + 2, 3) = dMa_a_dq(lo0:lo0 + 2, 3) + dc_lolo*mlo + dc_lohi*mhi
        dMa_a_dq(hi0:hi0 + 2, 3) = dMa_a_dq(hi0:hi0 + 2, 3) + dc_lohi*mlo + dc_hihi*mhi
        CALL wet_consistent_coefficient_derivatives(l0, frac, df_db, dc_lolo, dc_lohi, dc_hihi)
        dMa_a_dq(lo0:lo0 + 2, 6) = dMa_a_dq(lo0:lo0 + 2, 6) + dc_lolo*mlo + dc_lohi*mhi
        dMa_a_dq(hi0:hi0 + 2, 6) = dMa_a_dq(hi0:hi0 + 2, 6) + dc_lohi*mlo + dc_hihi*mhi
      END IF
    END BLOCK
  END SUBROUTINE CD_Added_Mass_Element

  SUBROUTINE CD_Added_Mass_Element_Matrix(qa, qb, l0, wl_a, wl_b, rho, diameter, can, cat, M_add, ErrStat, ErrMsg, &
                                          inputs_validated)
    !! Two-node configuration-dependent Morison added-mass matrix without
    !! d(M*a)/dq work. Used by initial-acceleration solves where the supplied
    !! acceleration is exactly zero but the mass matrix is still needed. The per-length
    !! matrix is CD_Morison_Added_Mass_Per_Length evaluated with its shared statements once
    !! the section scalars are validated (only the tangent checks of unit_tangent remain).
    REAL(wp), INTENT(IN) :: qa(3), qb(3), l0, wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: M_add(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load

    INTEGER :: lo0, hi0
    REAL(wp) :: za, zb, frac, chord(3), length, tangent(3), Me(3, 3), unit(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi

    M_add = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. trusted(inputs_validated)) THEN
      IF (.NOT. (CD_All_Finite(qa) .AND. CD_All_Finite(qb) .AND. &
                 CD_Is_Finite(l0) .AND. l0 > CD_ZERO .AND. CD_Is_Finite(wl_a) .AND. &
                 CD_Is_Finite(wl_b))) THEN
        CALL fail(ErrStat, ErrMsg, 'added-mass element matrix geometry must be finite')
        RETURN
      END IF
      CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'added-mass coefficients must be finite and non-negative')
        RETURN
      END IF
    END IF

    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_only(za, zb, frac)
    IF (frac <= CD_ZERO) RETURN
    chord = qb - qa
    length = SQRT(DOT_PRODUCT(chord, chord))
    IF (length <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass element collapsed to zero length')
      RETURN
    END IF
    tangent = chord/length
    IF (za <= zb) THEN
      lo0 = 1
      hi0 = 4
    ELSE
      lo0 = 4
      hi0 = 1
    END IF
    CALL unit_tangent(tangent, unit, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL added_mass_about_unit(unit, rho, diameter, can, cat, Me)
    CALL wet_consistent_coefficients(l0, frac, c_lolo, c_lohi, c_hihi)
    M_add(lo0:lo0 + 2, lo0:lo0 + 2) = M_add(lo0:lo0 + 2, lo0:lo0 + 2) + c_lolo*Me
    M_add(lo0:lo0 + 2, hi0:hi0 + 2) = M_add(lo0:lo0 + 2, hi0:hi0 + 2) + c_lohi*Me
    M_add(hi0:hi0 + 2, lo0:lo0 + 2) = M_add(hi0:hi0 + 2, lo0:lo0 + 2) + c_lohi*Me
    M_add(hi0:hi0 + 2, hi0:hi0 + 2) = M_add(hi0:hi0 + 2, hi0:hi0 + 2) + c_hihi*Me
  END SUBROUTINE CD_Added_Mass_Element_Matrix

  SUBROUTINE CD_Added_Mass_Element_Force(qa, qb, accel_a, accel_b, l0, wl_a, wl_b, rho, diameter, can, cat, &
                                         force, ErrStat, ErrMsg, inputs_validated)
    !! Two-node added-mass product M_add(q)*accel for residual-only evaluations. The
    !! per-length matrix is formed as in CD_Added_Mass_Element_Matrix.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), accel_a(3), accel_b(3), l0, wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated   !! see CD_Morison_Drag_Element_Load
    INTEGER :: lo0, hi0
    REAL(wp) :: za, zb, frac, chord(3), length, tangent(3), Me(3, 3), unit(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, acc_lo(3), acc_hi(3)

    IF (trusted(inputs_validated)) THEN
      ErrStat = CD_HYDRO_OK
      ErrMsg = ''
    ELSE
      CALL validate_added_mass_element_inputs(qa, qb, accel_a, accel_b, l0, wl_a, wl_b, &
                                              rho, diameter, can, cat, ErrStat, ErrMsg)
    END IF
    force = CD_ZERO
    IF (ErrStat /= CD_HYDRO_OK) RETURN

    za = qa(3) - wl_a
    zb = qb(3) - wl_b
    CALL submerged_fraction_only(za, zb, frac)
    IF (frac <= CD_ZERO) RETURN
    chord = qb - qa
    length = SQRT(DOT_PRODUCT(chord, chord))
    IF (length <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass element collapsed to zero length')
      RETURN
    END IF
    tangent = chord/length
    IF (za <= zb) THEN
      lo0 = 1
      hi0 = 4
      acc_lo = accel_a
      acc_hi = accel_b
    ELSE
      lo0 = 4
      hi0 = 1
      acc_lo = accel_b
      acc_hi = accel_a
    END IF
    CALL unit_tangent(tangent, unit, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL added_mass_about_unit(unit, rho, diameter, can, cat, Me)
    CALL wet_consistent_coefficients(l0, frac, c_lolo, c_lohi, c_hihi)
    force(lo0:lo0 + 2) = c_lolo*MATMUL(Me, acc_lo) + c_lohi*MATMUL(Me, acc_hi)
    force(hi0:hi0 + 2) = c_lohi*MATMUL(Me, acc_lo) + c_hihi*MATMUL(Me, acc_hi)
  END SUBROUTINE CD_Added_Mass_Element_Force

  SUBROUTINE CD_Split_Normal_Tangential(vector, tangent, normal, tangential, ErrStat, ErrMsg)
    !! Split a 3-vector into normal and tangential components about a non-zero
    !! tangent direction. The tangent is normalised defensively.
    REAL(wp), INTENT(IN) :: vector(3), tangent(3)
    REAL(wp), INTENT(OUT) :: normal(3), tangential(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: unit(3)

    normal = CD_ZERO
    tangential = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    CALL unit_tangent(tangent, unit, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. CD_All_Finite(vector)) THEN
      CALL fail(ErrStat, ErrMsg, 'vector must be finite')
      RETURN
    END IF
    CALL split_about_unit(vector, unit, normal, tangential)
  END SUBROUTINE CD_Split_Normal_Tangential

  SUBROUTINE CD_Morison_Drag_Per_Length(rel_velocity, tangent, rho, diameter, cdn, cdt, &
                                        force, ErrStat, ErrMsg)
    !! Morison drag per unit length [N/m] for one line section:
    !!   f = 1/2 rho d Cdn |v_n| v_n + 1/2 rho pi d Cdt |v_t| v_t.
    REAL(wp), INTENT(IN) :: rel_velocity(3), tangent(3), rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: normal(3), tangential(3), cn, ct, nmag, tmag

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(cdn) .AND. CD_Is_Finite(cdt) .AND. cdn >= CD_ZERO .AND. cdt >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'drag coefficients must be finite and non-negative')
      RETURN
    END IF
    CALL CD_Split_Normal_Tangential(rel_velocity, tangent, normal, tangential, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    cn = 0.5_wp*rho*diameter*cdn
    ct = 0.5_wp*rho*PI*diameter*cdt
    nmag = SQRT(DOT_PRODUCT(normal, normal))
    tmag = SQRT(DOT_PRODUCT(tangential, tangential))
    force = cn*nmag*normal + ct*tmag*tangential
    IF (.NOT. CD_All_Finite(force)) THEN
      force = CD_ZERO
      CALL fail(ErrStat, ErrMsg, 'Morison drag result overflowed')
    END IF
  END SUBROUTINE CD_Morison_Drag_Per_Length

  SUBROUTINE CD_Morison_Drag_Per_Length_Jac(rel_velocity, tangent, rho, diameter, cdn, cdt, &
                                            force, jac_rel, jac_tan, ErrStat, ErrMsg, scalars_validated)
    !! Morison drag per unit length [N/m] and its analytical Jacobians with respect to the relative
    !! velocity (jac_rel = d force / d rel_velocity) and the (possibly non-unit) tangent VECTOR
    !! (jac_tan = d force / d tangent), for consistent distributed-load assembly over an element's
    !! shape functions. The tangent vector is normalised internally -- matching CD_Morison_Drag_Per_Length,
    !! so a caller may pass a chord / dr-by-dxi vector -- and jac_tan carries the normalisation
    !! derivative, i.e. d force / d(the input vector). Both Jacobians degrade smoothly to zero as the
    !! relative velocity vanishes (still water at rest), so a consistent drag load leaves an at-rest
    !! equilibrium a fixed point.
    !!
    !! jac_rel/jac_tan are OPTIONAL as a pair: a residual-only caller omits both and pays for
    !! the force alone -- computed by the IDENTICAL statements either way, so the force is
    !! bit-for-bit the same with or without the Jacobians.
    !!
    !! scalars_validated (optional, default .FALSE.): .TRUE. when the caller has already
    !! established finite rho > 0, diameter > 0, cdn >= 0 and cdt >= 0 (an element kernel
    !! that checks them once per element, before its quadrature loop), which skips the same
    !! checks at every quadrature point. The vector inputs and the results are always checked.
    REAL(wp), INTENT(IN) :: rel_velocity(3), tangent(3), rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(3)
    REAL(wp), INTENT(OUT), OPTIONAL :: jac_rel(3, 3), jac_tan(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: scalars_validated
    REAL(wp) :: ek(3), col(3), tnorm, tu(3), munit(3, 3), proj(3, 3)
    INTEGER :: k
    LOGICAL :: want_jac, check_scalars

    want_jac = PRESENT(jac_rel)
    IF (want_jac .NEQV. PRESENT(jac_tan)) THEN
      CALL fail(ErrStat, ErrMsg, 'jac_rel and jac_tan must be supplied together (or neither)')
      force = CD_ZERO
      RETURN
    END IF
    force = CD_ZERO
    IF (want_jac) THEN
      jac_rel = CD_ZERO; jac_tan = CD_ZERO
    END IF
    ErrStat = CD_HYDRO_OK; ErrMsg = ''
    check_scalars = .TRUE.
    IF (PRESENT(scalars_validated)) check_scalars = .NOT. scalars_validated
    IF (check_scalars) THEN
      CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      IF (.NOT. (CD_Is_Finite(cdn) .AND. CD_Is_Finite(cdt) .AND. cdn >= CD_ZERO .AND. cdt >= CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'drag coefficients must be finite and non-negative')
        RETURN
      END IF
    END IF
    IF (.NOT. CD_All_Finite(rel_velocity) .OR. .NOT. CD_All_Finite(tangent)) THEN
      CALL fail(ErrStat, ErrMsg, 'relative velocity and tangent must be finite')
      RETURN
    END IF
    tnorm = SQRT(DOT_PRODUCT(tangent, tangent))
    IF (.NOT. (tnorm > MIN_TANGENT_NORM)) THEN
      CALL fail(ErrStat, ErrMsg, 'tangent vector must be non-zero')
      RETURN
    END IF
    tu = tangent/tnorm
    IF (want_jac) THEN
      CALL drag_per_length_with_jacobian(rel_velocity, tu, rho, diameter, cdn, cdt, force, jac_rel, .TRUE.)
      ! munit(:,k) = d force / d tu_k (unit-tangent directional derivatives).
      DO k = 1, 3
        ek = CD_ZERO; ek(k) = CD_ONE
        CALL drag_tangent_directional(rel_velocity, tu, rho, diameter, cdn, cdt, ek, col)
        munit(:, k) = col
      END DO
      ! d(unit tangent)/d(input vector) = (I - tu tu^T)/|tangent|; chain to jac_tan = munit . proj.
      proj = (identity3() - outer3(tu, tu))/tnorm
      jac_tan = MATMUL(munit, proj)
    ELSE
      CALL drag_per_length_with_jacobian(rel_velocity, tu, rho, diameter, cdn, cdt, force, want_jac=.FALSE.)
    END IF
    IF (.NOT. CD_All_Finite(force)) THEN
      force = CD_ZERO
      IF (want_jac) THEN
        jac_rel = CD_ZERO
        jac_tan = CD_ZERO
      END IF
      CALL fail(ErrStat, ErrMsg, 'Morison drag result or Jacobian overflowed')
      RETURN
    END IF
    ! Fortran does not require short-circuit evaluation, so inspect the optional
    ! Jacobians only inside the PRESENT-gated branch.
    IF (want_jac) THEN
      IF (.NOT. CD_All_Finite(jac_rel) .OR. .NOT. CD_All_Finite(jac_tan)) THEN
        force = CD_ZERO
        jac_rel = CD_ZERO
        jac_tan = CD_ZERO
        CALL fail(ErrStat, ErrMsg, 'Morison drag result or Jacobian overflowed')
      END IF
    END IF
  END SUBROUTINE CD_Morison_Drag_Per_Length_Jac

  SUBROUTINE CD_Morison_Added_Mass_Per_Length(tangent, rho, diameter, can, cat, M_a, ErrStat, ErrMsg)
    !! Morison added-mass matrix per unit length [kg/m]:
    !! M_a = rho A (Can (I - qq^T) + Cat qq^T), A = pi d^2 / 4.
    REAL(wp), INTENT(IN) :: tangent(3), rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: M_a(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: unit(3)

    M_a = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass coefficients must be finite and non-negative')
      RETURN
    END IF
    CALL unit_tangent(tangent, unit, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL added_mass_about_unit(unit, rho, diameter, can, cat, M_a)
  END SUBROUTINE CD_Morison_Added_Mass_Per_Length

  SUBROUTINE CD_Froude_Krylov_Per_Length(fluid_acceleration, tangent, rho, diameter, can, cat, &
                                         force, ErrStat, ErrMsg)
    !! Froude-Krylov plus fluid-inertia force per unit length [N/m]:
    !! f = rho A ((1 + Can) a_n + (1 + Cat) a_t).
    REAL(wp), INTENT(IN) :: fluid_acceleration(3), tangent(3), rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: normal(3), tangential(3)

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'FK coefficients must be finite and non-negative')
      RETURN
    END IF
    CALL CD_Split_Normal_Tangential(fluid_acceleration, tangent, normal, tangential, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL fk_force_from_split(normal, tangential, rho, diameter, can, cat, force)
  END SUBROUTINE CD_Froude_Krylov_Per_Length

  SUBROUTINE CD_Solve_Dispersion_Wavenumber(omega, depth, gravity, k, ErrStat, ErrMsg)
    !! Solve the linear dispersion relation omega^2 = g k tanh(k d) by monotone
    !! bisection in x = k d. omega = 0 returns k = 0.
    REAL(wp), INTENT(IN) :: omega, depth, gravity
    REAL(wp), INTENT(OUT) :: k
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: y, lo, hi, mid
    INTEGER :: it

    k = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(omega) .AND. omega >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'omega must be finite and non-negative')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(depth) .AND. depth > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'depth must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive')
      RETURN
    END IF
    IF (omega <= CD_ZERO) RETURN

    y = omega*omega*depth/gravity
    lo = CD_ZERO
    hi = MAX(CD_ONE, y) + CD_ONE
    DO WHILE (hi*TANH(hi) - y < CD_ZERO)
      hi = 2.0_wp*hi
    END DO
    DO it = 1, 200
      mid = 0.5_wp*(lo + hi)
      IF (mid*TANH(mid) - y > CD_ZERO) THEN
        hi = mid
      ELSE
        lo = mid
      END IF
      IF (hi - lo <= 1.0e-15_wp*MAX(CD_ONE, hi)) EXIT
    END DO
    k = 0.5_wp*(lo + hi)/depth
  END SUBROUTINE CD_Solve_Dispersion_Wavenumber

  SUBROUTINE CD_Airy_Wave_Kinematics(x, y, z, t, height, period, depth, gravity, direction_deg, &
                                     stretch, eta, velocity, acceleration, ErrStat, ErrMsg)
    !! Evaluate regular Airy-wave surface elevation, velocity, and local
    !! acceleration at one point and time. With stretch=.TRUE., Wheeler stretching
    !! maps points below the instantaneous surface into [-depth, 0] and returns
    !! zero kinematics for points above the surface.
    REAL(wp), INTENT(IN) :: x, y, z, t, height, period, depth, gravity, direction_deg
    LOGICAL, INTENT(IN) :: stretch
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: omega, k

    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(height) .AND. height > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'height must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(period) .AND. period > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'period must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(x) .AND. CD_Is_Finite(y) .AND. CD_Is_Finite(z) .AND. CD_Is_Finite(t) &
               .AND. CD_Is_Finite(direction_deg))) THEN
      CALL fail(ErrStat, ErrMsg, 'point, time, and direction must be finite')
      RETURN
    END IF
    omega = 2.0_wp*PI/period
    CALL CD_Solve_Dispersion_Wavenumber(omega, depth, gravity, k, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL CD_Airy_Wave_Kinematics_Precomputed(x, y, z, t, height, omega, k, depth, direction_deg, stretch, &
                                             eta, velocity, acceleration, ErrStat, ErrMsg)
  END SUBROUTINE CD_Airy_Wave_Kinematics

  SUBROUTINE CD_Airy_Wave_Kinematics_Precomputed(x, y, z, t, height, omega, k, depth, direction_deg, &
                                                 stretch, eta, velocity, acceleration, ErrStat, ErrMsg, pdyn)
    !! Evaluate Airy-wave kinematics with precomputed angular frequency and
    !! wavenumber. This is the deck hot path: k is constant for a run.
    !! pdyn (optional): the linear dynamic pressure per unit density,
    !! g a cosh(k(z+h))/cosh(kh) cos(theta) = (omega^2/k) a cosh(k(z+h))/sinh(kh) cos(theta) [m^2/s^2],
    !! at the same (stretched) evaluation depth as the velocity; zero above the surface.
    REAL(wp), INTENT(IN) :: x, y, z, t, height, omega, k, depth, direction_deg
    LOGICAL, INTENT(IN) :: stretch
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: pdyn
    REAL(wp) :: theta, cb, sb, x_along, z_eval, cosh_ratio, sinh_ratio, amp

    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    IF (PRESENT(pdyn)) pdyn = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(height) .AND. height > CD_ZERO .AND. &
               CD_Is_Finite(omega) .AND. omega > CD_ZERO .AND. CD_Is_Finite(k) .AND. k > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'precomputed Airy height, omega, and k must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(depth) .AND. depth > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'depth must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(x) .AND. CD_Is_Finite(y) .AND. CD_Is_Finite(z) .AND. CD_Is_Finite(t) &
               .AND. CD_Is_Finite(direction_deg))) THEN
      CALL fail(ErrStat, ErrMsg, 'point, time, and direction must be finite')
      RETURN
    END IF
    cb = COS(direction_deg*DEG2RAD)
    sb = SIN(direction_deg*DEG2RAD)
    x_along = x*cb + y*sb
    theta = k*x_along - omega*t
    eta = 0.5_wp*height*COS(theta)

    IF (stretch) THEN
      IF (z > eta) RETURN
      ! Wheeler stretching maps [-depth, eta] onto [-depth, 0]; it is undefined once the
      ! trough reaches the seabed (depth + eta <= 0), so that wave state fails closed.
      IF (.NOT. (depth + eta > EPSILON(depth)*depth)) THEN
        CALL fail(ErrStat, ErrMsg, 'Wheeler stretching is undefined: the wave trough reaches the seabed '// &
                  '(depth + eta <= 0); reduce the wave height or increase the water depth')
        RETURN
      END IF
      z_eval = (z - eta)*depth/(depth + eta)
    ELSE
      z_eval = z
    END IF
    CALL profile_ratios(k, depth, z_eval, cosh_ratio, sinh_ratio)
    amp = 0.5_wp*height*omega
    velocity(1) = amp*cosh_ratio*COS(theta)*cb
    velocity(2) = amp*cosh_ratio*COS(theta)*sb
    velocity(3) = amp*sinh_ratio*SIN(theta)
    amp = 0.5_wp*height*omega*omega
    acceleration(1) = amp*cosh_ratio*SIN(theta)*cb
    acceleration(2) = amp*cosh_ratio*SIN(theta)*sb
    acceleration(3) = -amp*sinh_ratio*COS(theta)
    IF (PRESENT(pdyn)) pdyn = (amp/k)*cosh_ratio*COS(theta)
  END SUBROUTINE CD_Airy_Wave_Kinematics_Precomputed

  SUBROUTINE CD_Current_Profile_Velocity(z, z_profile, velocity_profile, velocity, ErrStat, ErrMsg)
    !! Interpolate an N-level vertical current profile at elevation z: piecewise
    !! linear between levels, clamped outside the supplied range. Levels must be
    !! strictly increasing in z. The two-level case reproduces the original
    !! two-point primitive bit-for-bit (same alpha blend on the same pair). This
    !! is the core hydro primitive used by deck profile-current runs, the MoorDyn
    !! WaterKin current file, and coupling shells that receive profile data.
    REAL(wp), INTENT(IN) :: z, z_profile(:), velocity_profile(:, :)
    REAL(wp), INTENT(OUT) :: velocity(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: alpha, denom
    INTEGER :: n, k, seg

    velocity = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n = SIZE(z_profile)
    IF (n < 2 .OR. SIZE(velocity_profile, 1) /= 3 .OR. SIZE(velocity_profile, 2) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'current profile needs matching z(n>=2) and velocity(3,n) levels')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(z) .AND. CD_All_Finite(z_profile) .AND. &
               CD_All_Finite(velocity_profile))) THEN
      CALL fail(ErrStat, ErrMsg, 'current profile depth and velocity inputs must be finite')
      RETURN
    END IF
    DO k = 1, n - 1
      IF (z_profile(k + 1) - z_profile(k) <= 100.0_wp*EPSILON(CD_ONE)) THEN
        CALL fail(ErrStat, ErrMsg, 'current profile depths must be strictly increasing')
        RETURN
      END IF
    END DO
    seg = 1
    DO k = 2, n - 1
      IF (z >= z_profile(k)) seg = k
    END DO
    denom = z_profile(seg + 1) - z_profile(seg)
    alpha = MAX(CD_ZERO, MIN(CD_ONE, (z - z_profile(seg))/denom))
    velocity = (CD_ONE - alpha)*velocity_profile(:, seg) + alpha*velocity_profile(:, seg + 1)
  END SUBROUTINE CD_Current_Profile_Velocity

  SUBROUTINE CD_Current_Grid_Resample(x, y, z, t_in, v_in, grid, ErrStat, ErrMsg)
    !! Build a current grid from velocities v_in(3, nx, ny, nz, m) tabulated at the times t_in(m),
    !! as MoorDyn-C v2.7.1 does (constructDynamicCurrentGrid, construct4DCurrentGrid): the time
    !! step is the smallest interval of t_in, dt = min(t_in(n+1) - t_in(n)), the grid holds
    !! nt = floor(t_in(m)/dt) + 1 samples at the times (n - 1) dt from t = 0, and each sample is
    !! the table interpolated linearly in time, a (1 - f) + b f, held at the end rows (the value
    !! of the first row before t_in(1)). x, y, z and t_in must be strictly increasing, with at
    !! least two times (MoorDyn-C reads before its table with one).
    REAL(wp), INTENT(IN) :: x(:), y(:), z(:), t_in(:), v_in(:, :, :, :, :)
    TYPE(CD_CurrentGridType), INTENT(OUT) :: grid
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: dt, ts, f
    INTEGER(INT64) :: nt64
    INTEGER :: m, n, iu

    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    m = SIZE(t_in)
    IF (SIZE(x) < 1 .OR. SIZE(y) < 1 .OR. SIZE(z) < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid needs at least one x, y and z coordinate'); RETURN
    END IF
    IF (m < 2) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid needs at least two times'); RETURN
    END IF
    IF (SIZE(v_in, 1) /= 3 .OR. SIZE(v_in, 2) /= SIZE(x) .OR. SIZE(v_in, 3) /= SIZE(y) .OR. &
        SIZE(v_in, 4) /= SIZE(z) .OR. SIZE(v_in, 5) /= m) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid velocities must be shaped (3, nx, ny, nz, nt)'); RETURN
    END IF
    IF (.NOT. (CD_All_Finite(x) .AND. CD_All_Finite(y) .AND. CD_All_Finite(z) .AND. CD_All_Finite(t_in))) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid coordinates and times must be finite'); RETURN
    END IF
    IF (.NOT. (increasing(x) .AND. increasing(y) .AND. increasing(z))) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid x, y and z coordinates must be strictly increasing'); RETURN
    END IF
    IF (.NOT. increasing(t_in)) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid times must be strictly increasing'); RETURN
    END IF
    dt = HUGE(dt)
    DO n = 2, m
      IF (t_in(n) - t_in(n - 1) < dt) dt = t_in(n) - t_in(n - 1)
    END DO
    IF (t_in(m) < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid: the last time must not be negative (MoorDyn-C samples from t = 0)')
      RETURN
    END IF
    ! range first, without dividing by dt (a tiny dt would overflow)
    IF (.NOT. (t_in(m)/REAL(MAX_CURRENT_GRID_SAMPLES, wp) < dt)) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid: the last time over the smallest time interval exceeds the '// &
                'sample limit'); RETURN
    END IF
    nt64 = FLOOR(t_in(m)/dt, KIND=INT64) + 1_INT64
    IF (nt64*INT(SIZE(x), INT64)*INT(SIZE(y), INT64)*INT(SIZE(z), INT64) > MAX_CURRENT_GRID_SAMPLES) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid: more than 2e6 resampled space-time samples; coarsen the grid or '// &
                'its smallest time interval'); RETURN
    END IF
    IF (.NOT. CD_All_Finite(RESHAPE(v_in, [SIZE(v_in)]))) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid velocities must be finite'); RETURN
    END IF
    grid%x = x
    grid%y = y
    grid%z = z
    grid%dt = dt
    grid%nt = INT(nt64)
    ALLOCATE (grid%velocity(3, SIZE(x), SIZE(y), SIZE(z), grid%nt))
    DO n = 1, grid%nt
      ts = REAL(n - 1, wp)*dt
      CALL grid_factor(t_in, ts, iu, f)
      grid%velocity(:, :, :, :, n) = v_in(:, :, :, :, iu - 1)*(CD_ONE - f) + v_in(:, :, :, :, iu)*f
    END DO

  CONTAINS

    LOGICAL FUNCTION increasing(c)
      REAL(wp), INTENT(IN) :: c(:)
      INTEGER :: k
      increasing = .TRUE.
      DO k = 2, SIZE(c)
        IF (.NOT. c(k) > c(k - 1)) increasing = .FALSE.
      END DO
    END FUNCTION increasing
  END SUBROUTINE CD_Current_Grid_Resample

  SUBROUTINE CD_Current_Grid_Velocity(grid, pos, time, velocity, ErrStat, ErrMsg)
    !! The current of a grid at pos and time, as MoorDyn-C v2.7.1 evaluates it
    !! (CurrentGrid::getCurrentKin with interp_factor and interp4Vec, source/Util/Interp.hpp):
    !!  - in x, y and z, linear between the bracketing coordinates and held beyond the end ones,
    !!    the node elevation taken as it is (no stretching);
    !!  - in time, with q = time/dt, n = floor(q) and f = q - n, the samples n and n + 1
    !!    (0-based) blended a (1 - f) + b f, the upper index taken modulo nt: past the last sample
    !!    the grid repeats with period nt dt, and over [(nt - 1) dt, nt dt) of each period it holds
    !!    the first sample (both indices are 0 there);
    !!  - blended in time at the 8 corners first, then in x, y and z, in MoorDyn-C's order.
    !! A time before 0 takes the t = 0 sample (MoorDyn-C's runs start at t = 0).
    TYPE(CD_CurrentGridType), INTENT(IN) :: grid
    REAL(wp), INTENT(IN) :: pos(3), time
    REAL(wp), INTENT(OUT) :: velocity(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: fx, fy, fz, ft, q
    REAL(wp) :: c000(3), c001(3), c010(3), c011(3), c100(3), c101(3), c110(3), c111(3)
    REAL(wp) :: c00(3), c01(3), c10(3), c11(3), c0(3), c1(3)
    INTEGER :: ix, iy, iz, ix0, iy0, iz0, it, it0
    INTEGER(INT64) :: n

    velocity = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(pos) .AND. CD_Is_Finite(time))) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid: position and time must be finite'); RETURN
    END IF
    IF (.NOT. ALLOCATED(grid%velocity)) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid is not set'); RETURN
    END IF
    CALL grid_factor(grid%x, pos(1), ix, fx)
    CALL grid_factor(grid%y, pos(2), iy, fy)
    CALL grid_factor(grid%z, pos(3), iz, fz)
    ! 1-based upper (it) and lower (it0) time samples
    it = 1
    ft = CD_ZERO
    IF (grid%nt > 1) THEN
      ! range first, without dividing by dt
      IF (.NOT. MAX(time, CD_ZERO)/1.0e18_wp < grid%dt) THEN
        CALL fail(ErrStat, ErrMsg, 'current grid: time beyond 1e18 grid time steps'); RETURN
      END IF
      q = MAX(time, CD_ZERO)/grid%dt
      n = FLOOR(q, KIND=INT64)
      ft = q - REAL(n, wp)
      it = INT(MOD(n + 1_INT64, INT(grid%nt, INT64))) + 1
    END IF
    it0 = MAX(it - 1, 1)
    ix0 = MAX(ix - 1, 1)
    iy0 = MAX(iy - 1, 1)
    iz0 = MAX(iz - 1, 1)
    c000 = grid%velocity(:, ix0, iy0, iz0, it0)*(CD_ONE - ft) + grid%velocity(:, ix0, iy0, iz0, it)*ft
    c001 = grid%velocity(:, ix0, iy0, iz, it0)*(CD_ONE - ft) + grid%velocity(:, ix0, iy0, iz, it)*ft
    c010 = grid%velocity(:, ix0, iy, iz0, it0)*(CD_ONE - ft) + grid%velocity(:, ix0, iy, iz0, it)*ft
    c011 = grid%velocity(:, ix0, iy, iz, it0)*(CD_ONE - ft) + grid%velocity(:, ix0, iy, iz, it)*ft
    c100 = grid%velocity(:, ix, iy0, iz0, it0)*(CD_ONE - ft) + grid%velocity(:, ix, iy0, iz0, it)*ft
    c101 = grid%velocity(:, ix, iy0, iz, it0)*(CD_ONE - ft) + grid%velocity(:, ix, iy0, iz, it)*ft
    c110 = grid%velocity(:, ix, iy, iz0, it0)*(CD_ONE - ft) + grid%velocity(:, ix, iy, iz0, it)*ft
    c111 = grid%velocity(:, ix, iy, iz, it0)*(CD_ONE - ft) + grid%velocity(:, ix, iy, iz, it)*ft
    c00 = c000*(CD_ONE - fx) + c100*fx
    c01 = c001*(CD_ONE - fx) + c101*fx
    c10 = c010*(CD_ONE - fx) + c110*fx
    c11 = c011*(CD_ONE - fx) + c111*fx
    c0 = c00*(CD_ONE - fy) + c10*fy
    c1 = c01*(CD_ONE - fy) + c11*fy
    velocity = c0*(CD_ONE - fz) + c1*fz
  END SUBROUTINE CD_Current_Grid_Velocity

  SUBROUTINE CD_Current_Profile_Gradient(z, z_profile, velocity_profile, gradient)
    !! The gradient d(velocity)/d(position) (3 x 3, column j the derivative along x_j) of the
    !! depth profile of CD_Current_Profile_Velocity at elevation z: (u_(k+1) - u_k)/(z_(k+1) - z_k)
    !! in the z column inside a segment, zero where the profile is held beyond its end levels.
    !! For a Newton tangent: the caller has validated the profile.
    REAL(wp), INTENT(IN) :: z, z_profile(:), velocity_profile(:, :)
    REAL(wp), INTENT(OUT) :: gradient(3, 3)
    INTEGER :: n, k, seg
    REAL(wp) :: denom, alpha
    gradient = CD_ZERO
    n = SIZE(z_profile)
    IF (n < 2) RETURN
    seg = 1
    DO k = 2, n - 1
      IF (z >= z_profile(k)) seg = k
    END DO
    denom = z_profile(seg + 1) - z_profile(seg)
    alpha = (z - z_profile(seg))/denom
    IF (alpha > CD_ZERO .AND. alpha < CD_ONE) &
      gradient(:, 3) = (velocity_profile(:, seg + 1) - velocity_profile(:, seg))/denom
  END SUBROUTINE CD_Current_Profile_Gradient

  SUBROUTINE CD_Current_Grid_Gradient(grid, pos, time, gradient, ErrStat, ErrMsg)
    !! The gradient d(velocity)/d(position) (3 x 3, column j the derivative along x_j) of the
    !! current of CD_Current_Grid_Velocity at pos and time: the derivative of its trilinear
    !! blend, zero along an axis where the grid is held beyond its end coordinates (or has a
    !! single coordinate). For a Newton tangent.
    TYPE(CD_CurrentGridType), INTENT(IN) :: grid
    REAL(wp), INTENT(IN) :: pos(3), time
    REAL(wp), INTENT(OUT) :: gradient(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: f(3), g(3), ft, q, c(3, 0:1, 0:1, 0:1), w(0:1, 3), dw(0:1, 3)
    INTEGER :: iu(3), il(3), it, it0, i, j, k, a
    INTEGER(INT64) :: n

    gradient = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(pos) .AND. CD_Is_Finite(time))) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid: position and time must be finite'); RETURN
    END IF
    IF (.NOT. ALLOCATED(grid%velocity)) THEN
      CALL fail(ErrStat, ErrMsg, 'current grid is not set'); RETURN
    END IF
    CALL axis(grid%x, pos(1), 1)
    CALL axis(grid%y, pos(2), 2)
    CALL axis(grid%z, pos(3), 3)
    it = 1
    ft = CD_ZERO
    IF (grid%nt > 1) THEN
      IF (.NOT. MAX(time, CD_ZERO)/1.0e18_wp < grid%dt) THEN
        CALL fail(ErrStat, ErrMsg, 'current grid: time beyond 1e18 grid time steps'); RETURN
      END IF
      q = MAX(time, CD_ZERO)/grid%dt
      n = FLOOR(q, KIND=INT64)
      ft = q - REAL(n, wp)
      it = INT(MOD(n + 1_INT64, INT(grid%nt, INT64))) + 1
    END IF
    it0 = MAX(it - 1, 1)
    DO k = 0, 1
      DO j = 0, 1
        DO i = 0, 1
          c(:, i, j, k) = grid%velocity(:, MERGE(iu(1), il(1), i == 1), MERGE(iu(2), il(2), j == 1), &
                                        MERGE(iu(3), il(3), k == 1), it0)*(CD_ONE - ft) + &
                          grid%velocity(:, MERGE(iu(1), il(1), i == 1), MERGE(iu(2), il(2), j == 1), &
                                        MERGE(iu(3), il(3), k == 1), it)*ft
        END DO
      END DO
    END DO
    DO a = 1, 3
      w(0, a) = CD_ONE - f(a)
      w(1, a) = f(a)
      dw(0, a) = -g(a)
      dw(1, a) = g(a)
    END DO
    DO k = 0, 1
      DO j = 0, 1
        DO i = 0, 1
          gradient(:, 1) = gradient(:, 1) + dw(i, 1)*w(j, 2)*w(k, 3)*c(:, i, j, k)
          gradient(:, 2) = gradient(:, 2) + w(i, 1)*dw(j, 2)*w(k, 3)*c(:, i, j, k)
          gradient(:, 3) = gradient(:, 3) + w(i, 1)*w(j, 2)*dw(k, 3)*c(:, i, j, k)
        END DO
      END DO
    END DO

  CONTAINS

    SUBROUTINE axis(xp, x, a_)
      !! Bracket, factor and d(factor)/dx along axis a_ (zero where the grid is held).
      REAL(wp), INTENT(IN) :: xp(:), x
      INTEGER, INTENT(IN) :: a_
      CALL grid_factor(xp, x, iu(a_), f(a_))
      il(a_) = MAX(iu(a_) - 1, 1)
      g(a_) = CD_ZERO
      IF (SIZE(xp) > 1) THEN
        IF (x > xp(1) .AND. x < xp(SIZE(xp))) g(a_) = CD_ONE/(xp(iu(a_)) - xp(il(a_)))
      END IF
    END SUBROUTINE axis
  END SUBROUTINE CD_Current_Grid_Gradient

  PURE SUBROUTINE grid_factor(xp, x, iu, f)
    !! MoorDyn-C's interp_factor (source/Util/Interp.hpp) on 1-based coordinates xp: the upper
    !! bracketing index iu and the factor f of the blend a (1 - f) + b f between xp(iu - 1) and
    !! xp(iu): iu = 1, f = 0 for a single coordinate; iu = 2, f = 0 at or below xp(1); iu = n,
    !! f = 1 at or above xp(n); else the first iu with x <= xp(iu).
    REAL(wp), INTENT(IN) :: xp(:), x
    INTEGER, INTENT(OUT) :: iu
    REAL(wp), INTENT(OUT) :: f
    INTEGER :: n, i
    n = SIZE(xp)
    iu = 1
    f = CD_ZERO
    IF (n == 1) RETURN
    iu = 2
    IF (x <= xp(1)) RETURN
    iu = n
    f = CD_ONE
    IF (x >= xp(n)) RETURN
    DO i = 2, n
      IF (x <= xp(i)) THEN
        iu = i
        f = (x - xp(i - 1))/(xp(i) - xp(i - 1))
        RETURN
      END IF
    END DO
  END SUBROUTINE grid_factor

  SUBROUTINE CD_JONSWAP_Wave_Kinematics(x, y, z, t, hs, tp, gamma, depth, gravity, direction_deg, &
                                        stretch, eta, velocity, acceleration, ErrStat, ErrMsg)
    !! Evaluate deterministic irregular-wave kinematics from a discretized
    !! JONSWAP spectrum. The component amplitudes are scaled so the discrete
    !! zeroth moment gives Hs = 4*sqrt(m0). Component phases are deterministic
    !! for regression reproducibility; CD_JONSWAP_Random_Components gives the random-phase
    !! synthesis.
    REAL(wp), INTENT(IN) :: x, y, z, t, hs, tp, gamma, depth, gravity, direction_deg
    LOGICAL, INTENT(IN) :: stretch
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: amplitude(CD_JONSWAP_COMPONENTS), omega_comp(CD_JONSWAP_COMPONENTS)
    REAL(wp) :: k_comp(CD_JONSWAP_COMPONENTS)

    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(hs) .AND. hs > CD_ZERO .AND. CD_Is_Finite(tp) .AND. tp > CD_ZERO .AND. &
               CD_Is_Finite(gamma) .AND. gamma >= CD_ONE)) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP needs finite Hs, Tp, gamma with Hs, Tp > 0 and gamma >= 1')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(x) .AND. CD_Is_Finite(y) .AND. CD_Is_Finite(z) .AND. CD_Is_Finite(t) &
               .AND. CD_Is_Finite(direction_deg))) THEN
      CALL fail(ErrStat, ErrMsg, 'point, time, and direction must be finite')
      RETURN
    END IF

    CALL CD_JONSWAP_Wave_Precompute(hs, tp, gamma, depth, gravity, omega_comp, k_comp, amplitude, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    CALL CD_JONSWAP_Wave_Kinematics_Precomputed(x, y, z, t, depth, direction_deg, stretch, &
                                                omega_comp, k_comp, amplitude, eta, velocity, acceleration, &
                                                ErrStat, ErrMsg)
  END SUBROUTINE CD_JONSWAP_Wave_Kinematics

  SUBROUTINE CD_JONSWAP_Wave_Precompute(hs, tp, gamma, depth, gravity, omega_comp, k_comp, amplitude, ErrStat, ErrMsg)
    !! Precompute deterministic JONSWAP component amplitudes and wavenumbers.
    REAL(wp), INTENT(IN) :: hs, tp, gamma, depth, gravity
    REAL(wp), INTENT(OUT) :: omega_comp(:), k_comp(:), amplitude(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i
    REAL(wp) :: omega_p, omega_min, omega_max, domega, omega, sigma, expo, shape, m0_raw, scale
    REAL(wp) :: gamma_norm
    REAL(wp) :: spec(CD_JONSWAP_COMPONENTS)

    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    omega_comp = CD_ZERO
    k_comp = CD_ZERO
    amplitude = CD_ZERO
    IF (SIZE(omega_comp) /= CD_JONSWAP_COMPONENTS .OR. SIZE(k_comp) /= CD_JONSWAP_COMPONENTS .OR. &
        SIZE(amplitude) /= CD_JONSWAP_COMPONENTS) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP precompute arrays must have CD_JONSWAP_COMPONENTS entries')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(hs) .AND. hs > CD_ZERO .AND. CD_Is_Finite(tp) .AND. tp > CD_ZERO .AND. &
               CD_Is_Finite(gamma) .AND. gamma >= CD_ONE)) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP needs finite Hs, Tp, gamma with Hs, Tp > 0 and gamma >= 1')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(depth) .AND. depth > CD_ZERO .AND. CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP precompute needs finite positive depth and gravity')
      RETURN
    END IF
    omega_p = 2.0_wp*PI/tp
    omega_min = 0.2_wp*omega_p
    omega_max = 5.0_wp*omega_p
    domega = (omega_max - omega_min)/REAL(CD_JONSWAP_COMPONENTS - 1, wp)
    gamma_norm = CD_ONE - 0.287_wp*LOG(gamma)
    m0_raw = CD_ZERO
    DO i = 1, CD_JONSWAP_COMPONENTS
      omega = omega_min + REAL(i - 1, wp)*domega
      sigma = MERGE(0.07_wp, 0.09_wp, omega <= omega_p)
      expo = EXP(-0.5_wp*((omega/omega_p - CD_ONE)/sigma)**2)
      shape = gamma_norm*gravity*gravity*omega**(-5)*EXP(-1.25_wp*(omega_p/omega)**4)*gamma**expo
      omega_comp(i) = omega
      spec(i) = shape
      m0_raw = m0_raw + shape*domega
      CALL CD_Solve_Dispersion_Wavenumber(omega, depth, gravity, k_comp(i), ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
    END DO
    IF (m0_raw <= CD_ZERO .OR. .NOT. CD_Is_Finite(m0_raw)) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP spectrum has zero or non-finite energy')
      RETURN
    END IF
    scale = (hs*hs/16.0_wp)/m0_raw
    DO i = 1, CD_JONSWAP_COMPONENTS
      amplitude(i) = SQRT(2.0_wp*spec(i)*scale*domega)
    END DO
  END SUBROUTINE CD_JONSWAP_Wave_Precompute

  SUBROUTINE CD_JONSWAP_Random_Components(hs, tp, gamma, depth, gravity, seed, omega_comp, k_comp, amplitude, &
                                          phase, ErrStat, ErrMsg)
    !! Seeded random-phase JONSWAP discretisation for time-domain seas. The band
    !! [0.2, 5]*omega_p is split into n = SIZE(omega_comp) equal bins of width d_omega;
    !! each component sits at a uniformly random frequency INSIDE its bin and carries a
    !! uniformly random phase in [0, 2*pi). The bin jitter makes the component
    !! frequencies incommensurate, so the synthesised record does not repeat with the
    !! period 2*pi/d_omega of an equally spaced comb. Amplitudes are
    !! sqrt(2*S(omega_i)*d_omega), scaled so the discrete zeroth moment gives exactly
    !! Hs = 4*sqrt(m0). The same seed always gives the same sea on every platform: the
    !! random stream is the Park-Miller MINSTD generator (multiplier 48271, modulus
    !! 2^31 - 1, exact in 64-bit integers), whose starting state is the seed scrambled by
    !! three rounds of a 31-bit xorshift followed by one MINSTD step; the draws are then
    !! consumed in component order, frequency offset first, then phase.
    REAL(wp), INTENT(IN) :: hs, tp, gamma, depth, gravity
    INTEGER, INTENT(IN) :: seed
    REAL(wp), INTENT(OUT) :: omega_comp(:), k_comp(:), amplitude(:), phase(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER(INT64), PARAMETER :: MINSTD_M = 2147483647_INT64, MINSTD_A = 48271_INT64
    INTEGER(INT64), PARAMETER :: MASK31 = 2147483647_INT64
    INTEGER(INT64) :: state
    INTEGER :: i, n, r
    REAL(wp) :: omega_p, omega_min, omega_max, domega, omega, sigma, expo, m0_raw, scale, gamma_norm

    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    omega_comp = CD_ZERO
    k_comp = CD_ZERO
    amplitude = CD_ZERO
    phase = CD_ZERO
    n = SIZE(omega_comp)
    IF (n < 2 .OR. SIZE(k_comp) /= n .OR. SIZE(amplitude) /= n .OR. SIZE(phase) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'random JONSWAP arrays must share one length >= 2')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(hs) .AND. hs > CD_ZERO .AND. CD_Is_Finite(tp) .AND. tp > CD_ZERO .AND. &
               CD_Is_Finite(gamma) .AND. gamma >= CD_ONE)) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP needs finite Hs, Tp, gamma with Hs, Tp > 0 and gamma >= 1')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(depth) .AND. depth > CD_ZERO .AND. CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP synthesis needs finite positive depth and gravity')
      RETURN
    END IF
    IF (seed < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP wave seed must be a positive integer')
      RETURN
    END IF
    state = IAND(INT(seed, INT64), MASK31)
    DO r = 1, 3
      state = IEOR(state, IAND(ISHFT(state, 13), MASK31))
      state = IEOR(state, ISHFT(state, -17))
      state = IEOR(state, IAND(ISHFT(state, 5), MASK31))
    END DO
    state = MOD(state, MINSTD_M)
    IF (state == 0_INT64) state = 1_INT64
    state = MOD(MINSTD_A*state, MINSTD_M)

    omega_p = 2.0_wp*PI/tp
    omega_min = 0.2_wp*omega_p
    omega_max = 5.0_wp*omega_p
    domega = (omega_max - omega_min)/REAL(n, wp)
    gamma_norm = CD_ONE - 0.287_wp*LOG(gamma)
    m0_raw = CD_ZERO
    DO i = 1, n
      omega = omega_min + (REAL(i - 1, wp) + next_uniform())*domega
      phase(i) = 2.0_wp*PI*next_uniform()
      sigma = MERGE(0.07_wp, 0.09_wp, omega <= omega_p)
      expo = EXP(-0.5_wp*((omega/omega_p - CD_ONE)/sigma)**2)
      amplitude(i) = gamma_norm*gravity*gravity*omega**(-5)*EXP(-1.25_wp*(omega_p/omega)**4)*gamma**expo
      omega_comp(i) = omega
      m0_raw = m0_raw + amplitude(i)*domega
      CALL CD_Solve_Dispersion_Wavenumber(omega, depth, gravity, k_comp(i), ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
    END DO
    IF (m0_raw <= CD_ZERO .OR. .NOT. CD_Is_Finite(m0_raw)) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP spectrum has zero or non-finite energy')
      RETURN
    END IF
    scale = (hs*hs/16.0_wp)/m0_raw
    DO i = 1, n
      amplitude(i) = SQRT(2.0_wp*amplitude(i)*scale*domega)
    END DO

  CONTAINS

    REAL(wp) FUNCTION next_uniform() RESULT(u)
      !! Advance the MINSTD stream; the state never reaches 0, so u lies in (0, 1).
      state = MOD(MINSTD_A*state, MINSTD_M)
      u = REAL(state, wp)/REAL(MINSTD_M, wp)
    END FUNCTION next_uniform
  END SUBROUTINE CD_JONSWAP_Random_Components

  SUBROUTINE CD_JONSWAP_Wave_Kinematics_Precomputed(x, y, z, t, depth, direction_deg, stretch, &
                                                    omega_comp, k_comp, amplitude, eta, velocity, acceleration, &
                                                    ErrStat, ErrMsg)
    !! Evaluate deterministic JONSWAP kinematics from precomputed component data.
    REAL(wp), INTENT(IN) :: x, y, z, t, depth, direction_deg
    LOGICAL, INTENT(IN) :: stretch
    REAL(wp), INTENT(IN) :: omega_comp(:), k_comp(:), amplitude(:)
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: i
    REAL(wp) :: omega, k, amp
    REAL(wp) :: cb, sb, x_along, theta, phase, z_eval, cosh_ratio, sinh_ratio

    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (SIZE(omega_comp) /= CD_JONSWAP_COMPONENTS .OR. SIZE(k_comp) /= CD_JONSWAP_COMPONENTS .OR. &
        SIZE(amplitude) /= CD_JONSWAP_COMPONENTS) THEN
      CALL fail(ErrStat, ErrMsg, 'precomputed JONSWAP arrays must have CD_JONSWAP_COMPONENTS entries')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(omega_comp) .AND. ALL(omega_comp > CD_ZERO) .AND. &
               CD_All_Finite(k_comp) .AND. ALL(k_comp > CD_ZERO) .AND. &
               CD_All_Finite(amplitude) .AND. ALL(amplitude >= CD_ZERO))) THEN
      CALL fail(ErrStat, ErrMsg, 'precomputed JONSWAP component data must have finite positive omega/k '// &
                'and non-negative amplitude')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(depth) .AND. depth > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'depth must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(x) .AND. CD_Is_Finite(y) .AND. CD_Is_Finite(z) .AND. CD_Is_Finite(t) &
               .AND. CD_Is_Finite(direction_deg))) THEN
      CALL fail(ErrStat, ErrMsg, 'point, time, and direction must be finite')
      RETURN
    END IF
    cb = COS(direction_deg*DEG2RAD)
    sb = SIN(direction_deg*DEG2RAD)
    x_along = x*cb + y*sb
    DO i = 1, CD_JONSWAP_COMPONENTS
      omega = omega_comp(i)
      k = k_comp(i)
      phase = deterministic_phase(i)
      theta = k*x_along - omega*t + phase
      eta = eta + amplitude(i)*COS(theta)
    END DO

    IF (stretch) THEN
      IF (z > eta) RETURN
      ! Wheeler stretching maps [-depth, eta] onto [-depth, 0]; it is undefined once the
      ! trough reaches the seabed (depth + eta <= 0), so that wave state fails closed.
      IF (.NOT. (depth + eta > EPSILON(depth)*depth)) THEN
        CALL fail(ErrStat, ErrMsg, 'Wheeler stretching is undefined: the wave trough reaches the seabed '// &
                  '(depth + eta <= 0); reduce the wave height or increase the water depth')
        RETURN
      END IF
      z_eval = (z - eta)*depth/(depth + eta)
    ELSE
      z_eval = z
    END IF
    DO i = 1, CD_JONSWAP_COMPONENTS
      omega = omega_comp(i)
      k = k_comp(i)
      phase = deterministic_phase(i)
      theta = k*x_along - omega*t + phase
      CALL profile_ratios(k, depth, z_eval, cosh_ratio, sinh_ratio)
      amp = amplitude(i)*omega
      velocity(1) = velocity(1) + amp*cosh_ratio*COS(theta)*cb
      velocity(2) = velocity(2) + amp*cosh_ratio*COS(theta)*sb
      velocity(3) = velocity(3) + amp*sinh_ratio*SIN(theta)
      amp = amplitude(i)*omega*omega
      acceleration(1) = acceleration(1) + amp*cosh_ratio*SIN(theta)*cb
      acceleration(2) = acceleration(2) + amp*cosh_ratio*SIN(theta)*sb
      acceleration(3) = acceleration(3) - amp*sinh_ratio*COS(theta)
    END DO
  END SUBROUTINE CD_JONSWAP_Wave_Kinematics_Precomputed

  SUBROUTINE CD_Component_Wave_Kinematics(x, y, z, t, depth, direction_deg, stretch, &
                                          omega_comp, k_comp, amplitude, phase, &
                                          eta, velocity, acceleration, ErrStat, ErrMsg, inputs_validated, &
                                          amplitude_scale, pdyn, exp_m2kd, tail_sums, comp_cos, comp_sin, &
                                          eta_offset)
    !! Evaluate linear irregular-wave kinematics from a CALLER-SUPPLIED component table:
    !! the general (arbitrary length, explicit per-component phase) form of the fixed-size
    !! deterministic-phase JONSWAP evaluator above, sharing its conventions exactly --
    !! long-crested components along direction_deg, total surface elevation summed FIRST,
    !! then ONE Wheeler mapping of the evaluation depth against that total eta (the
    !! OrcaFlex irregular-wave stretching convention), then per-component velocity and
    !! local (Eulerian) acceleration sums. A single component with phase 0 reproduces
    !! CD_Airy_Wave_Kinematics_Precomputed (amplitude = height/2) exactly.
    !!
    !! This is the deterministic component-matched comparison path: an external tool
    !! synthesizes ONE spectrum discretization (e.g. JONSWAP) and feeds the SAME
    !! amplitude/frequency/phase table to CableDyn and to the reference solver, so an
    !! irregular-sea parity case has no stochastic seed ambiguity.
    !! `inputs_validated` is an internal hot-path contract: callers that already validated and
    !! own an immutable component table may skip repeating its O(n) metadata scan. The default
    !! remains full validation for public/direct calls. `amplitude_scale` multiplies every
    !! amplitude (a start-up ramp) without the caller forming a scaled copy of the table; the
    !! result equals passing amplitude_scale*amplitude to round-off.
    !! Each component's phase sine and cosine (one argument reduction for both) and its depth
    !! exponential come from the block kernels of CableDyn_WaveMath. The phase factors of the
    !! first NBUF components are kept for the velocity sums; components beyond that length are
    !! evaluated block by block with the same expressions. The sums run in the interleaved lanes
    !! of CableDyn_WaveMath, in an order fixed by the source, so the result does not depend on
    !! the vector width or the number of threads. The direction cosines and the amplitude scale
    !! multiply the finished sums.
    !! exp_m2kd is the caller's table of EXP(-2 k_comp(i) depth) for this depth (constant for a
    !! fixed table): it replaces the per-call exponential with the same value, so the result is
    !! bit-identical.
    !! tail_sums(:, i) holds the sums over components j >= i of a_j omega_j, a_j omega_j^2 and
    !! a_j omega_j^2/k_j, for a table whose k_comp does not decrease. On -depth <= z_eval <= 0
    !! both depth ratios fall as k grows, so the cosh ratio of the last summed component times
    !! tail_sums bounds the rest of the velocity, acceleration and pressure sums. The sums stop
    !! once that bound is below half an ulp of the magnitude already summed: a deep point drops
    !! the short components that have decayed to nothing there, and the result changes at
    !! round-off only. The elevation always sums every component.
    !! comp_cos and comp_sin, given together, hold the cosine and sine of each component's own
    !! direction, in place of the one direction_deg of a long-crested table: a short-crested
    !! table. The bound of tail_sums holds for any direction, since it bounds the magnitude.
    !! eta_offset is a steady level added to the surface elevation the stretching maps and eta
    !! returns, the components' wave numbers staying those of depth: the zero-frequency row of a
    !! MoorDyn-C kinematics file, which MoorDyn-C adds to the elevation alone. It is not scaled
    !! by amplitude_scale.
    REAL(wp), INTENT(IN) :: x, y, z, t, depth, direction_deg
    LOGICAL, INTENT(IN) :: stretch
    REAL(wp), INTENT(IN) :: omega_comp(:), k_comp(:), amplitude(:), phase(:)
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated
    REAL(wp), INTENT(IN), OPTIONAL :: amplitude_scale
    ! the linear dynamic pressure per unit density (sum over the components of
    ! (omega^2/k) a cosh(k(z+h))/sinh(kh) cos(theta)), as in CD_Airy_Wave_Kinematics_Precomputed
    REAL(wp), INTENT(OUT), OPTIONAL :: pdyn
    REAL(wp), INTENT(IN), OPTIONAL :: exp_m2kd(:), tail_sums(:, :), comp_cos(:), comp_sin(:)
    REAL(wp), INTENT(IN), OPTIONAL :: eta_offset
    INTEGER :: n
    REAL(wp) :: cb, sb, scl, offset
    LOGICAL :: trust_inputs

    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    IF (PRESENT(pdyn)) pdyn = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    trust_inputs = .FALSE.
    IF (PRESENT(inputs_validated)) trust_inputs = inputs_validated
    n = SIZE(omega_comp)
    IF (n < 1 .OR. SIZE(k_comp) /= n .OR. SIZE(amplitude) /= n .OR. SIZE(phase) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'component-wave arrays must share one length >= 1')
      RETURN
    END IF
    IF (PRESENT(exp_m2kd)) THEN
      IF (SIZE(exp_m2kd) /= n) THEN
        CALL fail(ErrStat, ErrMsg, 'exp_m2kd must match the component-wave arrays')
        RETURN
      END IF
    END IF
    IF (PRESENT(tail_sums)) THEN
      IF (SIZE(tail_sums, 1) /= 3 .OR. SIZE(tail_sums, 2) /= n) THEN
        CALL fail(ErrStat, ErrMsg, 'tail_sums must be shaped (3, n) for the component-wave arrays')
        RETURN
      END IF
    END IF
    IF (PRESENT(comp_cos) .NEQV. PRESENT(comp_sin)) THEN
      CALL fail(ErrStat, ErrMsg, 'comp_cos and comp_sin must be given together')
      RETURN
    END IF
    IF (PRESENT(comp_cos)) THEN
      IF (SIZE(comp_cos) /= n .OR. SIZE(comp_sin) /= n) THEN
        CALL fail(ErrStat, ErrMsg, 'comp_cos and comp_sin must match the component-wave arrays')
        RETURN
      END IF
      IF (.NOT. trust_inputs) THEN
        IF (.NOT. (CD_All_Finite(comp_cos) .AND. CD_All_Finite(comp_sin))) THEN
          CALL fail(ErrStat, ErrMsg, 'comp_cos and comp_sin must be finite')
          RETURN
        END IF
      END IF
    END IF
    ! Fortran does not require short-circuit evaluation: keep the O(n) scans inside a
    ! separate branch so the setup-validated hot path portably skips them at -O0 too.
    IF (.NOT. trust_inputs) THEN
      IF (.NOT. (CD_All_Finite(omega_comp) .AND. ALL(omega_comp > CD_ZERO) .AND. &
                 CD_All_Finite(k_comp) .AND. ALL(k_comp > CD_ZERO) .AND. &
                 CD_All_Finite(amplitude) .AND. ALL(amplitude >= CD_ZERO) .AND. &
                 CD_All_Finite(phase))) THEN
        CALL fail(ErrStat, ErrMsg, 'component-wave data must have finite positive omega/k, '// &
                  'non-negative amplitude, and finite phase')
        RETURN
      END IF
    END IF
    IF (.NOT. (CD_Is_Finite(depth) .AND. depth > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'depth must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(x) .AND. CD_Is_Finite(y) .AND. CD_Is_Finite(z) .AND. CD_Is_Finite(t) &
               .AND. CD_Is_Finite(direction_deg))) THEN
      CALL fail(ErrStat, ErrMsg, 'point, time, and direction must be finite')
      RETURN
    END IF
    offset = CD_ZERO
    IF (PRESENT(eta_offset)) offset = eta_offset
    IF (.NOT. CD_Is_Finite(offset)) THEN
      CALL fail(ErrStat, ErrMsg, 'eta_offset must be finite')
      RETURN
    END IF
    ! Preserve the regular-wave reduction as an executable identity, independent of
    ! compiler reassociation choices in the general summation loop. Besides making the
    ! documented one-component contract portable, this avoids loop setup in a common
    ! component-file case. A zero-amplitude component remains on the general path because
    ! the regular Airy primitive intentionally requires a positive height.
    ! a unit scale is exact, so the unscaled table is reproduced bit for bit
    scl = CD_ONE
    IF (PRESENT(amplitude_scale)) scl = amplitude_scale
    IF (n == 1 .AND. ABS(phase(1)) <= CD_ZERO .AND. scl*amplitude(1) > CD_ZERO .AND. .NOT. PRESENT(comp_cos) &
        .AND. ABS(offset) <= CD_ZERO) THEN
      CALL CD_Airy_Wave_Kinematics_Precomputed(x, y, z, t, 2.0_wp*(scl*amplitude(1)), omega_comp(1), k_comp(1), &
                                               depth, direction_deg, stretch, eta, velocity, acceleration, &
                                               ErrStat, ErrMsg, pdyn)
      RETURN
    END IF
    cb = COS(direction_deg*DEG2RAD)
    sb = SIN(direction_deg*DEG2RAD)
    CALL component_sums(n, x, y, z, t, depth, stretch, scl, offset, cb, sb, omega_comp, k_comp, amplitude, phase, &
                        eta, velocity, acceleration, ErrStat, ErrMsg, pdyn, exp_m2kd, tail_sums, comp_cos, comp_sin)
  END SUBROUTINE CD_Component_Wave_Kinematics

  SUBROUTINE component_sums(n, x, y, z, t, depth, stretch, scl, offset, cb, sb, omega_comp, k_comp, amplitude, phase, &
                            eta, velocity, acceleration, ErrStat, ErrMsg, pdyn, exp_m2kd, tail_sums, comp_cos, comp_sin)
    !! The sums of CD_Component_Wave_Kinematics, on explicit-shape tables: their blocks pass to
    !! the block kernels without a copy, and the loops run at unit stride. A long-crested table
    !! forms each phase from the one distance along its direction and sums the horizontal
    !! velocity and acceleration once, for cb and sb to multiply; a short-crested one (comp_cos,
    !! comp_sin) forms each phase from the component's own direction and sums x and y apart.
    !! offset (eta_offset) is added to the summed elevation before the stretching.
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: x, y, z, t, depth, scl, offset, cb, sb
    LOGICAL, INTENT(IN) :: stretch
    REAL(wp), INTENT(IN) :: omega_comp(n), k_comp(n), amplitude(n), phase(n)
    REAL(wp), INTENT(INOUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(INOUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    REAL(wp), INTENT(INOUT), OPTIONAL :: pdyn
    REAL(wp), INTENT(IN), OPTIONAL :: exp_m2kd(n), tail_sums(3, n), comp_cos(n), comp_sin(n)
    INTEGER :: nb, n_small, i0, i1, j, nk, m, lanes
    REAL(wp) :: z_eval, x_along
    ! the velocity sums run in blocks of NLANE and the elevation in chunks of NCHUNK (NBUF a
    ! multiple of NCHUNK and NCHUNK of NLANE, so a block lies wholly inside or past the buffer)
    INTEGER, PARAMETER :: NBUF = 4096, NCHUNK = 512
    REAL(wp), PARAMETER :: HALF_ULP = 0.5_wp*EPSILON(CD_ONE)
    REAL(wp) :: denom, e2, first_ratio
    REAL(wp) :: cth(NBUF), sth(NBUF), th(NCHUNK), bc(NCHUNK), bs(NCHUNK), ch(NLANE), sh(NLANE), e_bed(NLANE)
    REAL(wp) :: lane_eta(NLANE), lane_vc(NLANE), lane_vs(NLANE), lane_as(NLANE), lane_ac(NLANE)
    REAL(wp) :: lane_p(NLANE), lane_m(NLANE, 3), lane_vy(NLANE), lane_ay(NLANE), sum_vc, sum_vs, sum_as, sum_ac
    REAL(wp) :: mag(3), rest(3)
    LOGICAL :: at_bed, use_tail, want_p, spread

    spread = PRESENT(comp_cos)
    x_along = x*cb + y*sb
    nb = MIN(n, NBUF)
    lanes = MIN(n, NLANE)
    ! the elevation sums every component (Wheeler stretching needs the total eta); the phase
    ! sines of the first NBUF components are kept for the velocity sums
    lane_eta(1:lanes) = CD_ZERO
    DO i0 = 1, n, NCHUNK
      nk = MIN(n - i0 + 1, NCHUNK)
      i1 = i0 + nk - 1
      IF (spread) THEN
        DO j = i0, i1
          th(j - i0 + 1) = k_comp(j)*(x*comp_cos(j) + y*comp_sin(j)) - omega_comp(j)*t + phase(j)
        END DO
      ELSE
        DO j = 1, nk
          th(j) = k_comp(i0 + j - 1)*x_along - omega_comp(i0 + j - 1)*t + phase(i0 + j - 1)
        END DO
      END IF
      IF (i0 <= nb) THEN
        CALL CD_Wave_SinCos(nk, th, sth(i0), cth(i0))
        CALL add_elevation_lanes(nk, amplitude(i0:i1), cth(i0), lane_eta)
      ELSE
        CALL CD_Wave_SinCos(nk, th, bs, bc)
        CALL add_elevation_lanes(nk, amplitude(i0:i1), bc, lane_eta)
      END IF
    END DO
    eta = scl*CD_Wave_Sum_Lanes(lane_eta, lanes) + offset

    IF (stretch) THEN
      IF (z > eta) RETURN
      ! Wheeler stretching maps [-depth, eta] onto [-depth, 0]; it is undefined once the
      ! trough reaches the seabed (depth + eta <= 0), so that wave state fails closed.
      IF (.NOT. (depth + eta > EPSILON(depth)*depth)) THEN
        CALL fail(ErrStat, ErrMsg, 'Wheeler stretching is undefined: the wave trough reaches the seabed '// &
                  '(depth + eta <= 0); reduce the wave height or increase the water depth')
        RETURN
      END IF
      z_eval = (z - eta)*depth/(depth + eta)
    ELSE
      z_eval = z
    END IF
    ! Depth-profile ratios: the expressions of profile_ratios, with its seabed test (a function
    ! of z_eval and depth only) evaluated once.
    at_bed = ABS(z_eval + depth) <= 8.0_wp*EPSILON(CD_ONE)*MAX(CD_ONE, depth, ABS(z_eval))
    use_tail = .FALSE.
    IF (PRESENT(tail_sums)) use_tail = z_eval <= CD_ZERO .AND. z_eval >= -depth
    want_p = PRESENT(pdyn)
    lane_vc(1:lanes) = CD_ZERO
    lane_vs(1:lanes) = CD_ZERO
    lane_as(1:lanes) = CD_ZERO
    lane_ac(1:lanes) = CD_ZERO
    lane_p(1:lanes) = CD_ZERO
    lane_m(1:lanes, :) = CD_ZERO
    IF (spread) THEN
      lane_vy(1:lanes) = CD_ZERO
      lane_ay(1:lanes) = CD_ZERO
    END IF
    first_ratio = CD_ZERO
    DO i0 = 1, n, NLANE
      nk = MIN(n - i0 + 1, NLANE)
      i1 = i0 + nk - 1
      DO j = 1, nk
        th(j) = k_comp(i0 + j - 1)*z_eval
      END DO
      CALL CD_Wave_Exp(nk, th, ch)
      IF (PRESENT(exp_m2kd)) THEN
        sh(1:nk) = exp_m2kd(i0:i1)
      ELSE
        ! the intrinsic, as the caller's table exp_m2kd is built, so both give the same bits
        DO j = 1, nk
          sh(j) = EXP(-2.0_wp*(k_comp(i0 + j - 1)*depth))
        END DO
      END IF
      IF (at_bed) THEN
        DO j = 1, nk
          denom = CD_ONE - sh(j)
          ch(j) = (ch(j) + ch(j))/denom
          sh(j) = CD_ZERO
        END DO
      ELSE
        ! (e1 +- e2/e1)/(1 - e2) with e1 = exp(k z) and e2 = exp(-2 k depth) on one division; a
        ! block in which e1^2 or e2 leaves the normal range takes the stable form of
        ! profile_ratios, with the lower exponential of its own
        n_small = 0
        DO j = 1, nk
          n_small = n_small + MERGE(0, 1, ch(j)*ch(j) > TINY(CD_ONE) .AND. ch(j)*ch(j) < HUGE(CD_ONE) .AND. &
                                    sh(j) > TINY(CD_ONE))
        END DO
        IF (n_small == 0) THEN
          DO j = 1, nk
            e2 = sh(j)
            denom = CD_ONE/(ch(j)*(CD_ONE - e2))
            sh(j) = (ch(j)*ch(j) - e2)*denom
            ch(j) = (ch(j)*ch(j) + e2)*denom
          END DO
        ELSE
          DO j = 1, nk
            th(j) = -(k_comp(i0 + j - 1)*z_eval + 2.0_wp*(k_comp(i0 + j - 1)*depth))
          END DO
          CALL CD_Wave_Exp(nk, th, e_bed)
          DO j = 1, nk
            denom = CD_ONE - sh(j)
            sh(j) = (ch(j) - e_bed(j))/denom
            ch(j) = (ch(j) + e_bed(j))/denom
          END DO
        END IF
      END IF
      IF (i0 > nb) THEN
        IF (spread) THEN
          DO j = i0, i1
            th(j - i0 + 1) = k_comp(j)*(x*comp_cos(j) + y*comp_sin(j)) - omega_comp(j)*t + phase(j)
          END DO
        ELSE
          DO j = 1, nk
            th(j) = k_comp(i0 + j - 1)*x_along - omega_comp(i0 + j - 1)*t + phase(i0 + j - 1)
          END DO
        END IF
        CALL CD_Wave_SinCos(nk, th, bs, bc)
      END IF
      IF (spread) THEN
        IF (i0 <= nb) THEN
          CALL add_spread_lanes(nk, amplitude(i0:i1), omega_comp(i0:i1), comp_cos(i0:i1), comp_sin(i0:i1), ch, sh, &
                                cth(i0), sth(i0), lane_vc, lane_vy, lane_vs, lane_as, lane_ay, lane_ac, lane_m(1, 1), &
                                lane_m(1, 2))
        ELSE
          CALL add_spread_lanes(nk, amplitude(i0:i1), omega_comp(i0:i1), comp_cos(i0:i1), comp_sin(i0:i1), ch, sh, &
                                bc, bs, lane_vc, lane_vy, lane_vs, lane_as, lane_ay, lane_ac, lane_m(1, 1), &
                                lane_m(1, 2))
        END IF
      ELSE IF (i0 <= nb) THEN
        CALL add_velocity_lanes(nk, amplitude(i0:i1), omega_comp(i0:i1), ch, sh, cth(i0), sth(i0), lane_vc, &
                                lane_vs, lane_as, lane_ac, lane_m(1, 1), lane_m(1, 2))
      ELSE
        CALL add_velocity_lanes(nk, amplitude(i0:i1), omega_comp(i0:i1), ch, sh, bc, bs, lane_vc, lane_vs, lane_as, &
                                lane_ac, lane_m(1, 1), lane_m(1, 2))
      END IF
      IF (want_p) THEN
        IF (i0 <= nb) THEN
          CALL add_pressure_lanes(nk, amplitude(i0:i1), omega_comp(i0:i1), k_comp(i0:i1), ch, cth(i0), lane_p, &
                                  lane_m(1, 3))
        ELSE
          CALL add_pressure_lanes(nk, amplitude(i0:i1), omega_comp(i0:i1), k_comp(i0:i1), ch, bc, lane_p, lane_m(1, 3))
        END IF
      END IF
      IF (i0 == 1) first_ratio = ch(1)
      IF (use_tail) THEN
        IF (i0 + nk <= n) THEN
          rest = ch(nk)*tail_sums(:, i0 + nk)
          ! the ratios fall as k grows, so first_ratio*tail_sums(:, 1) bounds the magnitude: the
          ! lanes are added up only once the test below can pass
          IF (rest(1) <= HALF_ULP*first_ratio*tail_sums(1, 1) .AND. &
              rest(2) <= HALF_ULP*first_ratio*tail_sums(2, 1)) THEN
            DO m = 1, 3
              mag(m) = CD_Wave_Sum_Lanes(lane_m(:, m), lanes)
            END DO
            IF (rest(1) <= HALF_ULP*mag(1) .AND. rest(2) <= HALF_ULP*mag(2) .AND. &
                (.NOT. want_p .OR. rest(3) <= HALF_ULP*mag(3))) EXIT
          END IF
        END IF
      END IF
    END DO
    sum_vc = scl*CD_Wave_Sum_Lanes(lane_vc, lanes)
    sum_vs = scl*CD_Wave_Sum_Lanes(lane_vs, lanes)
    sum_as = scl*CD_Wave_Sum_Lanes(lane_as, lanes)
    sum_ac = scl*CD_Wave_Sum_Lanes(lane_ac, lanes)
    IF (spread) THEN
      velocity = [sum_vc, scl*CD_Wave_Sum_Lanes(lane_vy, lanes), sum_vs]
      acceleration = [sum_as, scl*CD_Wave_Sum_Lanes(lane_ay, lanes), -sum_ac]
    ELSE
      velocity = [sum_vc*cb, sum_vc*sb, sum_vs]
      acceleration = [sum_as*cb, sum_as*sb, -sum_ac]
    END IF
    IF (want_p) pdyn = scl*CD_Wave_Sum_Lanes(lane_p, lanes)
  END SUBROUTINE component_sums

  PURE SUBROUTINE add_elevation_lanes(n, amplitude, c, lane)
    !! lane(l) += a c over components l, l + NLANE, ... of the n given, for the elevation of
    !! CD_Component_Wave_Kinematics. Explicit-shape, so that the loops vectorise.
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: amplitude(n), c(n)
    REAL(wp), INTENT(INOUT) :: lane(NLANE)
    INTEGER :: i0, j
    DO i0 = 0, n - 1, NLANE
      DO j = 1, MIN(NLANE, n - i0)
        lane(j) = lane(j) + amplitude(i0 + j)*c(i0 + j)
      END DO
    END DO
  END SUBROUTINE add_elevation_lanes

  PURE SUBROUTINE add_velocity_lanes(n, amplitude, omega, ch, sh, c, s, lane_vc, lane_vs, lane_as, lane_ac, &
                                     lane_mv, lane_ma)
    !! One block (n <= NLANE) of the velocity and acceleration sums of
    !! CD_Component_Wave_Kinematics, and of the magnitudes a omega ch and a omega^2 ch.
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: amplitude(n), omega(n), ch(n), sh(n), c(n), s(n)
    REAL(wp), INTENT(INOUT) :: lane_vc(n), lane_vs(n), lane_as(n), lane_ac(n), lane_mv(n), lane_ma(n)
    INTEGER :: j
    REAL(wp) :: wv, wa, gv, ga
    DO j = 1, n
      wv = amplitude(j)*omega(j)
      wa = wv*omega(j)
      gv = wv*ch(j)
      ga = wa*ch(j)
      lane_vc(j) = lane_vc(j) + gv*c(j)
      lane_vs(j) = lane_vs(j) + (wv*sh(j))*s(j)
      lane_as(j) = lane_as(j) + ga*s(j)
      lane_ac(j) = lane_ac(j) + (wa*sh(j))*c(j)
      lane_mv(j) = lane_mv(j) + gv
      lane_ma(j) = lane_ma(j) + ga
    END DO
  END SUBROUTINE add_velocity_lanes

  PURE SUBROUTINE add_spread_lanes(n, amplitude, omega, cosb, sinb, ch, sh, c, s, lane_vx, lane_vy, lane_vs, lane_ax, &
                                   lane_ay, lane_ac, lane_mv, lane_ma)
    !! add_velocity_lanes for components each with its own direction: the horizontal sums go to
    !! x and y apart.
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: amplitude(n), omega(n), cosb(n), sinb(n), ch(n), sh(n), c(n), s(n)
    REAL(wp), INTENT(INOUT) :: lane_vx(n), lane_vy(n), lane_vs(n), lane_ax(n), lane_ay(n), lane_ac(n), lane_mv(n), &
                               lane_ma(n)
    INTEGER :: j
    REAL(wp) :: wv, wa, gv, ga, uh
    DO j = 1, n
      wv = amplitude(j)*omega(j)
      wa = wv*omega(j)
      gv = wv*ch(j)
      ga = wa*ch(j)
      uh = gv*c(j)
      lane_vx(j) = lane_vx(j) + uh*cosb(j)
      lane_vy(j) = lane_vy(j) + uh*sinb(j)
      lane_vs(j) = lane_vs(j) + (wv*sh(j))*s(j)
      uh = ga*s(j)
      lane_ax(j) = lane_ax(j) + uh*cosb(j)
      lane_ay(j) = lane_ay(j) + uh*sinb(j)
      lane_ac(j) = lane_ac(j) + (wa*sh(j))*c(j)
      lane_mv(j) = lane_mv(j) + gv
      lane_ma(j) = lane_ma(j) + ga
    END DO
  END SUBROUTINE add_spread_lanes

  PURE SUBROUTINE add_pressure_lanes(n, amplitude, omega, k, ch, c, lane_p, lane_mp)
    !! One block (n <= NLANE) of the pressure sum of CD_Component_Wave_Kinematics.
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(IN) :: amplitude(n), omega(n), k(n), ch(n), c(n)
    REAL(wp), INTENT(INOUT) :: lane_p(n), lane_mp(n)
    INTEGER :: j
    REAL(wp) :: gp
    DO j = 1, n
      gp = amplitude(j)*omega(j)*omega(j)/k(j)*ch(j)
      lane_p(j) = lane_p(j) + gp*c(j)
      lane_mp(j) = lane_mp(j) + gp
    END DO
  END SUBROUTINE add_pressure_lanes

  SUBROUTINE assemble_drag_force_only(q, v, elem_conn, l0, fluid_velocity, waterline_z, &
                                      rho, diameter, cdn, cdt, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:), l0(:), fluid_velocity(:, :), waterline_z(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, a, b, ia, ib
    REAL(wp) :: nodes(3, SIZE(q)/3), vel(3, SIZE(q)/3)
    REAL(wp) :: frac, chord(3), length, tangent(3), fluid_e(3), rel(3), f_per_len(3)
    REAL(wp) :: za, zb, wa, wb, lower, higher

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    nodes = RESHAPE(q, [3, SIZE(q)/3])
    vel = RESHAPE(v, [3, SIZE(v)/3])
    DO e = 1, SIZE(elem_conn, 2)
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > SIZE(nodes, 2) .OR. b < 1 .OR. b > SIZE(nodes, 2) .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_only(za, zb, frac)
      IF (frac <= CD_ZERO) CYCLE
      chord = nodes(:, b) - nodes(:, a)
      length = SQRT(DOT_PRODUCT(chord, chord))
      IF (length <= MIN_TANGENT_NORM) THEN
        CALL fail(ErrStat, ErrMsg, 'drag element collapsed to zero length')
        RETURN
      END IF
      tangent = chord/length
      higher = 0.5_wp*frac
      lower = CD_ONE - higher
      IF (za <= zb) THEN
        wa = lower
        wb = higher
      ELSE
        wa = higher
        wb = lower
      END IF
      fluid_e = wa*fluid_velocity(:, a) + wb*fluid_velocity(:, b)
      rel = fluid_e - (wa*vel(:, a) + wb*vel(:, b))
      CALL CD_Morison_Drag_Per_Length(rel, tangent, rho, diameter, cdn, cdt, f_per_len, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      ia = 3*a - 2
      ib = 3*b - 2
      force(ia:ia + 2) = force(ia:ia + 2) + 0.5_wp*l0(e)*frac*f_per_len
      force(ib:ib + 2) = force(ib:ib + 2) + 0.5_wp*l0(e)*frac*f_per_len
    END DO
  END SUBROUTINE assemble_drag_force_only

  SUBROUTINE assemble_fk_force_only(q, elem_conn, l0, fluid_acceleration, waterline_z, &
                                    rho, diameter, can, cat, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), l0(:), fluid_acceleration(:, :), waterline_z(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, a, b, lo, hi, ilo, ihi
    REAL(wp) :: nodes(3, SIZE(q)/3)
    REAL(wp) :: frac, za, zb, chord(3), length, tangent(3)
    REAL(wp) :: f_lo(3), f_hi(3), c_lolo, c_lohi, c_hihi, f

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    nodes = RESHAPE(q, [3, SIZE(q)/3])
    DO e = 1, SIZE(elem_conn, 2)
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > SIZE(nodes, 2) .OR. b < 1 .OR. b > SIZE(nodes, 2) .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_only(za, zb, frac)
      IF (frac <= CD_ZERO) CYCLE
      chord = nodes(:, b) - nodes(:, a)
      length = SQRT(DOT_PRODUCT(chord, chord))
      IF (length <= MIN_TANGENT_NORM) THEN
        CALL fail(ErrStat, ErrMsg, 'FK element collapsed to zero length')
        RETURN
      END IF
      tangent = chord/length
      IF (za <= zb) THEN
        lo = a
        hi = b
      ELSE
        lo = b
        hi = a
      END IF
      CALL CD_Froude_Krylov_Per_Length(fluid_acceleration(:, lo), tangent, rho, diameter, can, cat, &
                                       f_lo, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      CALL CD_Froude_Krylov_Per_Length(fluid_acceleration(:, hi), tangent, rho, diameter, can, cat, &
                                       f_hi, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      f = frac
      c_lolo = l0(e)*(f - f*f + f**3/3.0_wp)
      c_lohi = l0(e)*(0.5_wp*f*f - f**3/3.0_wp)
      c_hihi = l0(e)*f**3/3.0_wp
      ilo = 3*lo - 2
      ihi = 3*hi - 2
      force(ilo:ilo + 2) = force(ilo:ilo + 2) + c_lolo*f_lo + c_lohi*f_hi
      force(ihi:ihi + 2) = force(ihi:ihi + 2) + c_lohi*f_lo + c_hihi*f_hi
    END DO
  END SUBROUTINE assemble_fk_force_only

  SUBROUTINE assemble_buoyancy_recovery_force_only(q, elem_conn, l0, waterline_z, &
                                                   rho, diameter, gravity, force, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), l0(:), waterline_z(:), rho, diameter, gravity
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, a, b, iza, izb
    REAL(wp) :: nodes(3, SIZE(q)/3)
    REAL(wp) :: frac, za, zb, half_g, recovery, buoyancy

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    nodes = RESHAPE(q, [3, SIZE(q)/3])
    buoyancy = rho*0.25_wp*PI*diameter*diameter*gravity
    DO e = 1, SIZE(elem_conn, 2)
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > SIZE(nodes, 2) .OR. b < 1 .OR. b > SIZE(nodes, 2) .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = nodes(3, a) - waterline_z(a)
      zb = nodes(3, b) - waterline_z(b)
      CALL submerged_fraction_only(za, zb, frac)
      half_g = 0.5_wp*buoyancy*l0(e)
      recovery = -(CD_ONE - frac)*half_g
      iza = 3*a
      izb = 3*b
      force(iza) = force(iza) + recovery
      force(izb) = force(izb) + recovery
    END DO
  END SUBROUTINE assemble_buoyancy_recovery_force_only

  SUBROUTINE validate_cable_load_shapes(q, v, elem_conn, l0, field, waterline_z, &
                                        force, jac_q, jac_v, n_dof, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:), l0(:), field(:, :), waterline_z(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: n_dof, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(v) /= n_dof .OR. &
        SIZE(force) /= n_dof .OR. SIZE(jac_q, 1) /= n_dof .OR. SIZE(jac_q, 2) /= n_dof .OR. &
        SIZE(jac_v, 1) /= n_dof .OR. SIZE(jac_v, 2) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/v/force/Jacobian shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(field, 1) /= 3 .OR. &
        SIZE(field, 2) /= n_nodes .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad mesh/load-field shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(field) .OR. .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, l0, field, and waterline_z must be finite')
    END IF
  END SUBROUTINE validate_cable_load_shapes

  SUBROUTINE validate_cable_force_shapes(q, v, elem_conn, l0, field, waterline_z, &
                                         force, n_dof, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:), l0(:), field(:, :), waterline_z(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: n_dof, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(v) /= n_dof .OR. SIZE(force) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/v/force shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(field, 1) /= 3 .OR. &
        SIZE(field, 2) /= n_nodes .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad mesh/load-field shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(field) .OR. .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, l0, field, and waterline_z must be finite')
    END IF
  END SUBROUTINE validate_cable_force_shapes

  SUBROUTINE validate_waterline_load_shapes(q, v, elem_conn, l0, waterline_z, force, jac_q, jac_v, &
                                            n_dof, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:), l0(:), waterline_z(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: force(:), jac_q(:, :), jac_v(:, :)
    INTEGER, INTENT(OUT) :: n_dof, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem

    force = CD_ZERO
    jac_q = CD_ZERO
    jac_v = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(v) /= n_dof .OR. &
        SIZE(force) /= n_dof .OR. SIZE(jac_q, 1) /= n_dof .OR. SIZE(jac_q, 2) /= n_dof .OR. &
        SIZE(jac_v, 1) /= n_dof .OR. SIZE(jac_v, 2) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/v/force/Jacobian shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad mesh/waterline shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, l0, and waterline_z must be finite')
    END IF
  END SUBROUTINE validate_waterline_load_shapes

  SUBROUTINE validate_waterline_force_shapes(q, v, elem_conn, l0, waterline_z, force, n_dof, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), v(:), l0(:), waterline_z(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: force(:)
    INTEGER, INTENT(OUT) :: n_dof, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem

    force = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(v) /= n_dof .OR. SIZE(force) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/v/force shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad mesh/waterline shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(v) .OR. &
        .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, v, l0, and waterline_z must be finite')
    END IF
  END SUBROUTINE validate_waterline_force_shapes

  SUBROUTINE assemble_added_mass_matrix_only(q, elem_conn, l0, waterline_z, rho, diameter, can, cat, &
                                             M_add, ErrStat, ErrMsg)
    !! The callers validate the section scalars first, so the per-length matrix is formed with
    !! the statements of CD_Morison_Added_Mass_Per_Length after its tangent checks alone.
    REAL(wp), INTENT(IN) :: q(:), l0(:), waterline_z(:), rho, diameter, can, cat
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: M_add(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: e, a, b, lo, hi, n_nodes
    REAL(wp) :: frac, za, zb, chord(3), length, tangent(3), Me(3, 3), unit(3)
    REAL(wp) :: c_lolo, c_lohi, c_hihi, f

    M_add = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    ! node j is q(3j-2:3j); read in place rather than through a per-call nodal copy
    n_nodes = SIZE(q)/3
    DO e = 1, SIZE(elem_conn, 2)
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      IF (a < 1 .OR. a > n_nodes .OR. b < 1 .OR. b > n_nodes .OR. a == b) THEN
        CALL fail(ErrStat, ErrMsg, 'element connectivity out of range')
        RETURN
      END IF
      za = q(3*a) - waterline_z(a)
      zb = q(3*b) - waterline_z(b)
      CALL submerged_fraction_only(za, zb, frac)
      IF (frac <= CD_ZERO) CYCLE
      chord = q(3*b - 2:3*b) - q(3*a - 2:3*a)
      length = SQRT(DOT_PRODUCT(chord, chord))
      IF (length <= MIN_TANGENT_NORM) THEN
        CALL fail(ErrStat, ErrMsg, 'added-mass element collapsed to zero length')
        RETURN
      END IF
      tangent = chord/length
      IF (za <= zb) THEN
        lo = a
        hi = b
      ELSE
        lo = b
        hi = a
      END IF
      CALL unit_tangent(tangent, unit, ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) RETURN
      CALL added_mass_about_unit(unit, rho, diameter, can, cat, Me)
      f = frac
      c_lolo = l0(e)*(f - f*f + f**3/3.0_wp)
      c_lohi = l0(e)*(0.5_wp*f*f - f**3/3.0_wp)
      c_hihi = l0(e)*f**3/3.0_wp
      CALL scatter_mass_block(M_add, lo, lo, c_lolo*Me)
      CALL scatter_mass_block(M_add, lo, hi, c_lohi*Me)
      CALL scatter_mass_block(M_add, hi, lo, c_lohi*Me)
      CALL scatter_mass_block(M_add, hi, hi, c_hihi*Me)
    END DO
  END SUBROUTINE assemble_added_mass_matrix_only

  SUBROUTINE validate_added_mass_shapes(q, accel, elem_conn, l0, waterline_z, M_add, dMa_a_dq, &
                                        n_dof, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), accel(:), l0(:), waterline_z(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    REAL(wp), INTENT(OUT) :: M_add(:, :), dMa_a_dq(:, :)
    INTEGER, INTENT(OUT) :: n_dof, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n_nodes, n_elem

    M_add = CD_ZERO
    dMa_a_dq = CD_ZERO
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    n_dof = SIZE(q)
    IF (MOD(n_dof, 3) /= 0 .OR. n_dof < 6 .OR. SIZE(accel) /= n_dof .OR. &
        SIZE(M_add, 1) /= n_dof .OR. SIZE(M_add, 2) /= n_dof .OR. &
        SIZE(dMa_a_dq, 1) /= n_dof .OR. SIZE(dMa_a_dq, 2) /= n_dof) THEN
      CALL fail(ErrStat, ErrMsg, 'q/accel/matrix shapes must match a positions-only state')
      RETURN
    END IF
    n_nodes = n_dof/3
    n_elem = SIZE(elem_conn, 2)
    IF (SIZE(elem_conn, 1) /= 2 .OR. SIZE(l0) /= n_elem .OR. SIZE(waterline_z) /= n_nodes) THEN
      CALL fail(ErrStat, ErrMsg, 'bad added-mass mesh/waterline shapes')
      RETURN
    END IF
    IF (.NOT. CD_All_Finite(q) .OR. .NOT. CD_All_Finite(accel) .OR. &
        .NOT. CD_All_Finite(l0) .OR. ANY(l0 <= CD_ZERO) .OR. &
        .NOT. CD_All_Finite(waterline_z)) THEN
      CALL fail(ErrStat, ErrMsg, 'q, accel, l0, and waterline_z must be finite')
    END IF
  END SUBROUTINE validate_added_mass_shapes

  SUBROUTINE scatter_mass_block(M, node_row, node_col, block)
    REAL(wp), INTENT(INOUT) :: M(:, :)
    INTEGER, INTENT(IN) :: node_row, node_col
    REAL(wp), INTENT(IN) :: block(3, 3)
    INTEGER :: i, j, row0, col0

    row0 = 3*node_row - 2
    col0 = 3*node_col - 2
    DO j = 1, 3
      DO i = 1, 3
        M(row0 + i - 1, col0 + j - 1) = M(row0 + i - 1, col0 + j - 1) + block(i, j)
      END DO
    END DO
  END SUBROUTINE scatter_mass_block

  SUBROUTINE CD_Submerged_Fraction(za, zb, fraction)
    !! Wetted fraction of a straight element whose end heights above the local waterline
    !! are za and zb: the convention every element load of this module uses.
    REAL(wp), INTENT(IN) :: za, zb
    REAL(wp), INTENT(OUT) :: fraction
    CALL submerged_fraction_only(za, zb, fraction)
  END SUBROUTINE CD_Submerged_Fraction

  SUBROUTINE submerged_fraction_only(za, zb, fraction)
    REAL(wp), INTENT(IN) :: za, zb
    REAL(wp), INTENT(OUT) :: fraction
    REAL(wp) :: lo, hi

    lo = MIN(za, zb)
    hi = MAX(za, zb)
    IF (hi <= CD_ZERO) THEN
      fraction = CD_ONE
    ELSE IF (lo >= CD_ZERO) THEN
      fraction = CD_ZERO
    ELSE
      fraction = -lo/(hi - lo)
    END IF
  END SUBROUTINE submerged_fraction_only

  SUBROUTINE submerged_fraction_with_derivatives(za, zb, fraction, df_da, df_db)
    REAL(wp), INTENT(IN) :: za, zb
    REAL(wp), INTENT(OUT) :: fraction, df_da, df_db
    REAL(wp) :: denom

    df_da = CD_ZERO
    df_db = CD_ZERO
    IF (MAX(za, zb) <= CD_ZERO) THEN
      fraction = CD_ONE
    ELSE IF (MIN(za, zb) >= CD_ZERO) THEN
      fraction = CD_ZERO
    ELSE IF (za <= zb) THEN
      denom = zb - za
      fraction = -za/denom
      df_da = -zb/(denom*denom)
      df_db = za/(denom*denom)
    ELSE
      denom = za - zb
      fraction = -zb/denom
      df_da = zb/(denom*denom)
      df_db = -za/(denom*denom)
    END IF
  END SUBROUTINE submerged_fraction_with_derivatives

  SUBROUTINE wet_endpoint_weights(za, zb, fraction, df_da, df_db, wa, wb, dwa_da, dwa_db, dwb_da, dwb_db)
    REAL(wp), INTENT(IN) :: za, zb, fraction, df_da, df_db
    REAL(wp), INTENT(OUT) :: wa, wb, dwa_da, dwa_db, dwb_da, dwb_db

    IF (za <= zb) THEN
      wa = CD_ONE - 0.5_wp*fraction
      wb = 0.5_wp*fraction
      dwa_da = -0.5_wp*df_da
      dwa_db = -0.5_wp*df_db
      dwb_da = 0.5_wp*df_da
      dwb_db = 0.5_wp*df_db
    ELSE
      wa = 0.5_wp*fraction
      wb = CD_ONE - 0.5_wp*fraction
      dwa_da = 0.5_wp*df_da
      dwa_db = 0.5_wp*df_db
      dwb_da = -0.5_wp*df_da
      dwb_db = -0.5_wp*df_db
    END IF
  END SUBROUTINE wet_endpoint_weights

  SUBROUTINE wet_consistent_coefficients(l0, fraction, c_lolo, c_lohi, c_hihi)
    REAL(wp), INTENT(IN) :: l0, fraction
    REAL(wp), INTENT(OUT) :: c_lolo, c_lohi, c_hihi

    c_lolo = l0*(fraction - fraction*fraction + fraction**3/3.0_wp)
    c_lohi = l0*(0.5_wp*fraction*fraction - fraction**3/3.0_wp)
    c_hihi = l0*fraction**3/3.0_wp
  END SUBROUTINE wet_consistent_coefficients

  SUBROUTINE wet_consistent_coefficient_derivatives(l0, fraction, df, dc_lolo, dc_lohi, dc_hihi)
    REAL(wp), INTENT(IN) :: l0, fraction, df
    REAL(wp), INTENT(OUT) :: dc_lolo, dc_lohi, dc_hihi

    dc_lolo = l0*(CD_ONE - 2.0_wp*fraction + fraction*fraction)*df
    dc_lohi = l0*(fraction - fraction*fraction)*df
    dc_hihi = l0*fraction*fraction*df
  END SUBROUTINE wet_consistent_coefficient_derivatives

  SUBROUTINE drag_per_length_with_jacobian(rel, tangent, rho, diameter, cdn, cdt, force, Jrel, want_jac)
    !! The force statements run identically with or without the Jacobian, so a force-only
    !! call (want_jac = .FALSE., Jrel absent) is bit-for-bit the with-Jacobian force.
    REAL(wp), INTENT(IN) :: rel(3), tangent(3), rho, diameter, cdn, cdt
    REAL(wp), INTENT(OUT) :: force(3)
    REAL(wp), INTENT(OUT), OPTIONAL :: Jrel(3, 3)
    LOGICAL, INTENT(IN) :: want_jac
    REAL(wp) :: alpha, normal(3), tangential(3), nmag, cn, ct

    cn = 0.5_wp*rho*diameter*cdn
    ct = 0.5_wp*rho*PI*diameter*cdt
    alpha = DOT_PRODUCT(rel, tangent)
    tangential = alpha*tangent
    normal = rel - tangential
    nmag = SQRT(DOT_PRODUCT(normal, normal))
    force = cn*nmag*normal + ct*ABS(alpha)*alpha*tangent
    IF (.NOT. want_jac) RETURN
    Jrel = CD_ZERO
    IF (nmag > MIN_TANGENT_NORM) THEN
      Jrel = Jrel + cn*(nmag*identity3() + outer3(normal, normal)/nmag) &
             - cn*MATMUL(nmag*identity3() + outer3(normal, normal)/nmag, outer3(tangent, tangent))
    END IF
    IF (ABS(alpha) > MIN_TANGENT_NORM) THEN
      Jrel = Jrel + ct*2.0_wp*ABS(alpha)*outer3(tangent, tangent)
    END IF
  END SUBROUTINE drag_per_length_with_jacobian

  SUBROUTINE drag_tangent_directional(rel, tangent, rho, diameter, cdn, cdt, dt, dforce)
    REAL(wp), INTENT(IN) :: rel(3), tangent(3), rho, diameter, cdn, cdt, dt(3)
    REAL(wp), INTENT(OUT) :: dforce(3)
    REAL(wp) :: alpha, dalpha, normal(3), dnormal(3), nmag, cn, ct

    cn = 0.5_wp*rho*diameter*cdn
    ct = 0.5_wp*rho*PI*diameter*cdt
    alpha = DOT_PRODUCT(rel, tangent)
    dalpha = DOT_PRODUCT(rel, dt)
    normal = rel - alpha*tangent
    dnormal = -dalpha*tangent - alpha*dt
    nmag = SQRT(DOT_PRODUCT(normal, normal))
    dforce = CD_ZERO
    IF (nmag > MIN_TANGENT_NORM) THEN
      dforce = dforce + cn*(nmag*dnormal + DOT_PRODUCT(normal, dnormal)*normal/nmag)
    END IF
    IF (ABS(alpha) > MIN_TANGENT_NORM) THEN
      dforce = dforce + ct*(2.0_wp*ABS(alpha)*dalpha*tangent + ABS(alpha)*alpha*dt)
    END IF
  END SUBROUTINE drag_tangent_directional

  SUBROUTINE fk_per_length_with_tangent_derivative(accel, tangent, rho, diameter, can, cat, dt, force, dforce)
    REAL(wp), INTENT(IN) :: accel(3), tangent(3), rho, diameter, can, cat, dt(3)
    REAL(wp), INTENT(OUT) :: force(3), dforce(3)
    REAL(wp) :: area, alpha, dalpha, coeff_n, coeff_t

    area = 0.25_wp*PI*diameter*diameter
    coeff_n = CD_ONE + can
    coeff_t = CD_ONE + cat
    alpha = DOT_PRODUCT(accel, tangent)
    dalpha = DOT_PRODUCT(accel, dt)
    force = rho*area*(coeff_n*accel + (coeff_t - coeff_n)*alpha*tangent)
    dforce = rho*area*(coeff_t - coeff_n)*(dalpha*tangent + alpha*dt)
  END SUBROUTINE fk_per_length_with_tangent_derivative

  SUBROUTINE added_mass_with_tangent_derivative(tangent, rho, diameter, can, cat, dt, M_a, dM_a)
    REAL(wp), INTENT(IN) :: tangent(3), rho, diameter, can, cat, dt(3)
    REAL(wp), INTENT(OUT) :: M_a(3, 3), dM_a(3, 3)
    REAL(wp) :: area

    area = 0.25_wp*PI*diameter*diameter
    M_a = rho*area*(can*identity3() + (cat - can)*outer3(tangent, tangent))
    dM_a = rho*area*(cat - can)*(outer3(dt, tangent) + outer3(tangent, dt))
  END SUBROUTINE added_mass_with_tangent_derivative

  SUBROUTINE profile_ratios(k, depth, z_eval, cosh_ratio, sinh_ratio)
    REAL(wp), INTENT(IN) :: k, depth, z_eval
    REAL(wp), INTENT(OUT) :: cosh_ratio, sinh_ratio
    REAL(wp) :: kd, kz, e_kz, e_neg2kd, e_neg, denom
    kd = k*depth
    kz = k*z_eval
    e_kz = EXP(kz)
    e_neg2kd = EXP(-2.0_wp*kd)
    ! Enforce the impermeable-bed boundary analytically.  In deep-water/high-k
    ! cases the two representable exponentials in the sinh numerator can differ
    ! by their final rounding bit even when z_eval is exactly -depth.  Subtracting
    ! them would then create a small, non-physical vertical velocity at the bed.
    IF (ABS(z_eval + depth) <= 8.0_wp*EPSILON(CD_ONE)*MAX(CD_ONE, depth, ABS(z_eval))) THEN
      denom = CD_ONE - e_neg2kd
      cosh_ratio = (e_kz + e_kz)/denom
      sinh_ratio = CD_ZERO
      RETURN
    END IF
    IF (e_kz <= TINY(e_kz) .OR. e_neg2kd <= TINY(e_neg2kd)) THEN
      ! Preserve the original stable expression if either cached factor underflows.
      ! Besides avoiding 0/0, this retains a representable lower exponential near the
      ! seabed when exp(-2kd) has vanished but exp(-(kz+2kd)) has not.
      e_neg = EXP(-(kz + 2.0_wp*kd))
    ELSE
      e_neg = e_neg2kd/e_kz
    END IF
    denom = CD_ONE - e_neg2kd
    cosh_ratio = (e_kz + e_neg)/denom
    sinh_ratio = (e_kz - e_neg)/denom
  END SUBROUTINE profile_ratios

  SUBROUTINE unit_tangent(tangent, unit, ErrStat, ErrMsg)
    !! Writes ErrMsg only on failure: every caller has cleared it.
    REAL(wp), INTENT(IN) :: tangent(3)
    REAL(wp), INTENT(OUT) :: unit(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg
    REAL(wp) :: norm
    unit = CD_ZERO
    ErrStat = CD_HYDRO_OK
    IF (.NOT. CD_All_Finite(tangent)) THEN
      CALL fail(ErrStat, ErrMsg, 'tangent must be finite')
      RETURN
    END IF
    norm = SQRT(DOT_PRODUCT(tangent, tangent))
    IF (norm <= MIN_TANGENT_NORM) THEN
      CALL fail(ErrStat, ErrMsg, 'tangent must be a non-zero direction')
      RETURN
    END IF
    unit = tangent/norm
  END SUBROUTINE unit_tangent

  PURE SUBROUTINE split_about_unit(vector, unit, normal, tangential)
    !! Normal and tangential parts of vector about a unit tangent from unit_tangent.
    REAL(wp), INTENT(IN) :: vector(3), unit(3)
    REAL(wp), INTENT(OUT) :: normal(3), tangential(3)
    REAL(wp) :: dot_vt
    dot_vt = DOT_PRODUCT(vector, unit)
    tangential = dot_vt*unit
    normal = vector - tangential
  END SUBROUTINE split_about_unit

  PURE SUBROUTINE fk_force_from_split(normal, tangential, rho, diameter, can, cat, force)
    !! Froude-Krylov plus fluid-inertia force per unit length from the split fluid acceleration.
    REAL(wp), INTENT(IN) :: normal(3), tangential(3), rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: force(3)
    REAL(wp) :: area
    area = 0.25_wp*PI*diameter*diameter
    force = rho*area*((CD_ONE + can)*normal + (CD_ONE + cat)*tangential)
  END SUBROUTINE fk_force_from_split

  PURE SUBROUTINE added_mass_about_unit(unit, rho, diameter, can, cat, M_a)
    !! Morison added-mass matrix per unit length about a unit tangent from unit_tangent.
    REAL(wp), INTENT(IN) :: unit(3), rho, diameter, can, cat
    REAL(wp), INTENT(OUT) :: M_a(3, 3)
    REAL(wp) :: q_outer(3, 3), eye(3, 3), area
    eye = identity3()
    q_outer = outer3(unit, unit)
    area = 0.25_wp*PI*diameter*diameter
    M_a = rho*area*(can*(eye - q_outer) + cat*q_outer)
  END SUBROUTINE added_mass_about_unit

  PURE LOGICAL FUNCTION trusted(inputs_validated) RESULT(trust)
    !! The value of an optional inputs_validated flag (.FALSE. when absent).
    LOGICAL, INTENT(IN), OPTIONAL :: inputs_validated
    trust = .FALSE.
    IF (PRESENT(inputs_validated)) trust = inputs_validated
  END FUNCTION trusted

  SUBROUTINE validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: rho, diameter
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(rho) .AND. rho > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'rho must be finite and positive')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(diameter) .AND. diameter > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'diameter must be finite and positive')
    END IF
  END SUBROUTINE validate_hydro_scalars

  SUBROUTINE validate_drag_element_inputs(qa, qb, va, vb, l0, fluid_a, fluid_b, wl_a, wl_b, &
                                          rho, diameter, cdn, cdt, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3), l0, fluid_a(3), fluid_b(3), wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, cdn, cdt
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(qa) .AND. CD_All_Finite(qb) .AND. &
               CD_All_Finite(va) .AND. CD_All_Finite(vb) .AND. &
               CD_All_Finite(fluid_a) .AND. CD_All_Finite(fluid_b) .AND. &
               CD_Is_Finite(l0) .AND. CD_Is_Finite(wl_a) .AND. CD_Is_Finite(wl_b))) THEN
      CALL fail(ErrStat, ErrMsg, 'drag element inputs must be finite')
      RETURN
    END IF
    IF (l0 <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'drag element length must be positive')
      RETURN
    END IF
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(cdn) .AND. CD_Is_Finite(cdt) .AND. cdn >= CD_ZERO .AND. cdt >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'drag coefficients must be finite and non-negative')
    END IF
  END SUBROUTINE validate_drag_element_inputs

  SUBROUTINE validate_added_mass_element_inputs(qa, qb, accel_a, accel_b, l0, wl_a, wl_b, &
                                                rho, diameter, can, cat, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: qa(3), qb(3), accel_a(3), accel_b(3), l0, wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(qa) .AND. CD_All_Finite(qb) .AND. &
               CD_All_Finite(accel_a) .AND. CD_All_Finite(accel_b) .AND. &
               CD_Is_Finite(l0) .AND. CD_Is_Finite(wl_a) .AND. CD_Is_Finite(wl_b))) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass element inputs must be finite')
      RETURN
    END IF
    IF (l0 <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass element length must be positive')
      RETURN
    END IF
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'added-mass coefficients must be finite and non-negative')
    END IF
  END SUBROUTINE validate_added_mass_element_inputs

  SUBROUTINE validate_buoyancy_element_inputs(qa, qb, l0, wl_a, wl_b, rho, diameter, gravity, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: qa(3), qb(3), l0, wl_a, wl_b, rho, diameter, gravity
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(qa) .AND. CD_All_Finite(qb) .AND. &
               CD_Is_Finite(l0) .AND. CD_Is_Finite(wl_a) .AND. CD_Is_Finite(wl_b))) THEN
      CALL fail(ErrStat, ErrMsg, 'buoyancy recovery element inputs must be finite')
      RETURN
    END IF
    IF (l0 <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'buoyancy recovery element length must be positive')
      RETURN
    END IF
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive')
    END IF
  END SUBROUTINE validate_buoyancy_element_inputs

  SUBROUTINE validate_fk_element_inputs(qa, qb, va, vb, l0, accel_a, accel_b, wl_a, wl_b, &
                                        rho, diameter, can, cat, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3), l0, accel_a(3), accel_b(3), wl_a, wl_b
    REAL(wp), INTENT(IN) :: rho, diameter, can, cat
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    ErrStat = CD_HYDRO_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(qa) .AND. CD_All_Finite(qb) .AND. &
               CD_All_Finite(va) .AND. CD_All_Finite(vb) .AND. &
               CD_All_Finite(accel_a) .AND. CD_All_Finite(accel_b) .AND. &
               CD_Is_Finite(l0) .AND. CD_Is_Finite(wl_a) .AND. CD_Is_Finite(wl_b))) THEN
      CALL fail(ErrStat, ErrMsg, 'FK element inputs must be finite')
      RETURN
    END IF
    IF (l0 <= CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'FK element length must be positive')
      RETURN
    END IF
    CALL validate_hydro_scalars(rho, diameter, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HYDRO_OK) RETURN
    IF (.NOT. (CD_Is_Finite(can) .AND. CD_Is_Finite(cat) .AND. can >= CD_ZERO .AND. cat >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'FK coefficients must be finite and non-negative')
    END IF
  END SUBROUTINE validate_fk_element_inputs

  PURE FUNCTION identity3() RESULT(eye)
    REAL(wp) :: eye(3, 3)
    eye = CD_ZERO
    eye(1, 1) = CD_ONE
    eye(2, 2) = CD_ONE
    eye(3, 3) = CD_ONE
  END FUNCTION identity3

  PURE FUNCTION outer3(a, b) RESULT(out)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: out(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        out(i, j) = a(i)*b(j)
      END DO
    END DO
  END FUNCTION outer3

  PURE REAL(wp) FUNCTION deterministic_phase(i) RESULT(phase)
    INTEGER, INTENT(IN) :: i
    REAL(wp), PARAMETER :: GOLDEN = 0.618033988749894848204586834365638118_wp
    phase = 2.0_wp*PI*MOD(REAL(i*i + 3*i, wp)*GOLDEN, CD_ONE)
  END FUNCTION deterministic_phase

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_HYDRO_BADINPUT
    ErrMsg = 'CableDyn_Hydro: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Hydro
