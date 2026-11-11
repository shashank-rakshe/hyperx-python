! File: tests/test_hermite_drag_dynamics.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_drag_dynamics
  !! Morison drag on the finite-EI Hermite dynamic cable -- the hydrodynamic damping that makes a
  !! driven dynamic power cable physical (an undamped cable builds up under sustained forcing). The
  !! drag is quadratic in the cable velocity relative to the fluid, wired into the implicit gen-alpha
  !! residual with its velocity Jacobian folded into the effective tangent through the Newmark
  !! dv/dq coupling. Gates:
  !!   A  still-water fixed point -- drag is zero at rest (current = 0, v = 0), so the equilibrium is
  !!      unchanged and the model does not drift,
  !!   B  ENERGY DISSIPATION -- with rho_inf = 1 (no algorithmic damping) a submerged beam released
  !!      from a modal displacement loses total mechanical energy MONOTONICALLY with drag on, whereas
  !!      the same run with drag off conserves it: drag is dissipative and correctly wired,
  !!   C  IMPLICIT-TANGENT CORRECTNESS -- a drag-active step under prescribed motion converges in a
  !!      few Newton iterations; a wrong velocity Jacobian would degrade or break that convergence,
  !!   D  fail-closed on a bad drag configuration.
  !!
  !! Submerged straight beam along x (planar x-z), pinned ends, so the transverse (z) motion drives
  !! the normal drag. The beam sits well below the waterline, so the submerged fraction is 1.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Step, &
                                          CD_HermiteCable_Dyn_Set_Held_Fluid, &
                                          CD_HermiteCable_Dyn_Set_TangentReuse, &
                                          CD_HermiteCable_Dyn_Energy, CD_HermiteCable_Dyn_End, &
                                          CD_HermiteCable_Drag_Element, CD_HCDYN_OK
  USE CableDyn_Hydro, ONLY: CD_Morison_Drag_Per_Length_Jac, CD_HYDRO_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: LB = 10.0_wp, RHOA = 1.0_wp, EI = 100.0_wp, EA = 1.0e5_wp
  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, DIAM = 0.30_wp, CDN = 2.0_wp, CDT = 0.1_wp, WL = 100.0_wp
  INTEGER, PARAMETER :: NE = 10
  INTEGER :: nfail

  nfail = 0
  CALL check_drag_element_jacobian()
  CALL check_drag_arc_length_scaling()
  CALL check_set_drag_rollback()
  CALL check_fully_constrained_validation()
  CALL check_still_water_fixed_point()
  CALL check_current_rest_acceleration()
  CALL check_held_field_history_contract()
  CALL check_energy_dissipation()
  CALL check_tangent_convergence()
  CALL check_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Morison drag on the Hermite dynamic cable -- dissipative, implicit, fixed-point-safe'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE build_beam(amp, l0, EAv, EIv, rhoAv, wv, seed, fixed_dofs)
    !! Straight submerged beam along x with a mode-1 transverse seed of amplitude amp.
    REAL(wp), INTENT(IN) :: amp
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed_dofs(:)
    INTEGER :: nn, i, k
    REAL(wp) :: h, xi
    nn = NE + 1
    h = LB/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*nn))
    l0 = h; EAv = EA; EIv = EI; rhoAv = RHOA; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      xi = REAL(i - 1, wp)*h
      seed(6*(i - 1) + 1) = xi
      seed(6*(i - 1) + 3) = amp*SIN(PI*xi/LB)
      seed(6*(i - 1) + 4) = 1.0_wp
      seed(6*(i - 1) + 6) = amp*(PI/LB)*COS(PI*xi/LB)
    END DO
    ! planar x-z: fix r_y + m_y everywhere; pin both ends in translation (r_x, r_z); m_x free
    ALLOCATE (fixed_dofs(2*nn + 4))
    k = 0
    DO i = 1, nn
      fixed_dofs(k + 1) = 6*(i - 1) + 2; fixed_dofs(k + 2) = 6*(i - 1) + 5; k = k + 2
    END DO
    fixed_dofs(k + 1) = 1; fixed_dofs(k + 2) = 3
    fixed_dofs(k + 3) = 6*(nn - 1) + 1; fixed_dofs(k + 4) = 6*(nn - 1) + 3
  END SUBROUTINE build_beam

  SUBROUTINE enable_drag(m, current_x)
    !! Turn on Morison drag with a uniform along-x current.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    REAL(wp), INTENT(IN) :: current_x
    REAL(wp) :: dv(NE), cn(NE), ct(NE), cur(3)
    INTEGER :: es
    CHARACTER(300) :: em
    dv = DIAM; cn = CDN; ct = CDT; cur = [current_x, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL require(es == CD_HCDYN_OK, 'enable drag: '//TRIM(em))
  END SUBROUTINE enable_drag

  SUBROUTINE check_drag_element_jacobian()
    !! The consistent drag element's analytic Jacobians djq/djv match central FD of the drag load --
    !! INCLUDING the material-tangent (m) DOF rows/columns the old lumped-endpoint drag omitted --
    !! and the m-DOFs actually carry a non-zero consistent drag generalized force.
    REAL(wp) :: qe(12), ve(12), fluid(3), fd(12), jq(12, 12), jv(12, 12)
    REAL(wp) :: qp(12), fp(12), fm(12), dfd(12, 12), dj(12, 12), djd(12, 12)
    REAL(wp) :: hstep, errq, errv, mmag
    INTEGER :: i, es
    CHARACTER(300) :: em
    ! A deformed, moving, fully submerged element (waterline well above).
    qe = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.10_wp, 1.02_wp, 0.0_wp, 0.20_wp, 1.0_wp, 0.0_wp, -0.10_wp]
    ve = [0.10_wp, 0.0_wp, 0.30_wp, 0.20_wp, 0.0_wp, 0.10_wp, -0.10_wp, 0.0_wp, 0.40_wp, 0.05_wp, 0.0_wp, 0.20_wp]
    fluid = [0.20_wp, 0.0_wp, -0.10_wp]
    CALL CD_HermiteCable_Drag_Element(qe, ve, 1.0_wp, fluid, 100.0_wp, RHOW, DIAM, CDN, CDT, fd, jq, jv, es, em)
    CALL require(es == CD_HCDYN_OK, 'drag element accepted: '//TRIM(em))
    ! central FD of the velocity Jacobian
    DO i = 1, 12
      hstep = 1.0e-7_wp*MAX(1.0_wp, ABS(ve(i)))
      qp = ve; qp(i) = ve(i) + hstep
      CALL CD_HermiteCable_Drag_Element(qe, qp, 1.0_wp, fluid, 100.0_wp, RHOW, DIAM, CDN, CDT, fp, dj, djd, es, em)
      qp(i) = ve(i) - hstep
      CALL CD_HermiteCable_Drag_Element(qe, qp, 1.0_wp, fluid, 100.0_wp, RHOW, DIAM, CDN, CDT, fm, dj, djd, es, em)
      dfd(:, i) = (fp - fm)/(2.0_wp*hstep)
    END DO
    errv = nan_max_abs(jv - dfd)/MAX(1.0_wp, nan_max_abs(dfd))
    ! central FD of the position Jacobian
    DO i = 1, 12
      hstep = 1.0e-7_wp*MAX(1.0_wp, ABS(qe(i)))
      qp = qe; qp(i) = qe(i) + hstep
      CALL CD_HermiteCable_Drag_Element(qp, ve, 1.0_wp, fluid, 100.0_wp, RHOW, DIAM, CDN, CDT, fp, dj, djd, es, em)
      qp(i) = qe(i) - hstep
      CALL CD_HermiteCable_Drag_Element(qp, ve, 1.0_wp, fluid, 100.0_wp, RHOW, DIAM, CDN, CDT, fm, dj, djd, es, em)
      dfd(:, i) = (fp - fm)/(2.0_wp*hstep)
    END DO
    errq = nan_max_abs(jq - dfd)/MAX(1.0_wp, nan_max_abs(dfd))
    WRITE (*, '(A,ES10.3,A,ES10.3)') '  [drag] Jacobian vs central FD: djv err = ', errv, '   djq err = ', errq
    CALL require(errv < 1.0e-5_wp, 'consistent drag velocity Jacobian matches central FD')
    CALL require(errq < 1.0e-5_wp, 'consistent drag position Jacobian matches central FD')
    ! the material-tangent (m) DOFs carry a non-zero consistent drag generalized force
    mmag = nan_max_abs(fd(4:6)) + nan_max_abs(fd(10:12))
    CALL require(mmag > 1.0e-6_wp, 'material-tangent (m) DOFs carry consistent drag load (interior motion damped)')
  END SUBROUTINE check_drag_element_jacobian

  SUBROUTINE check_drag_arc_length_scaling()
    !! Drag integrates over the DEFORMED cable length, not the reference length: a straight element
    !! uniformly stretched 2x (same l0) under the same transverse velocity gets ~2x the net drag.
    !! (With a reference-length measure both would be identical, which this check excludes.)
    REAL(wp) :: qa(12), qb(12), ve(12), fluid(3), fa(12), fb(12), jq(12, 12), jv(12, 12), ratio
    REAL(wp), PARAMETER :: VT = 0.5_wp
    INTEGER :: es
    CHARACTER(300) :: em
    fluid = 0.0_wp
    ! straight along x, unit stretch: r2 = (1,0,0), m1 = m2 = (1,0,0) -> |dr/dxi| = 1
    qa = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    ! straight along x, uniform 2x stretch: r2 = (2,0,0), m1 = m2 = (2,0,0) -> |dr/dxi| = 2
    qb = [0.0_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    ! uniform transverse (z) velocity: r-velocities = VT, m-velocities = 0
    ve = [0.0_wp, 0.0_wp, VT, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, VT, 0.0_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Drag_Element(qa, ve, 1.0_wp, fluid, 100.0_wp, RHOW, DIAM, CDN, CDT, fa, jq, jv, es, em)
    CALL require(es == CD_HCDYN_OK, 'unit-stretch drag: '//TRIM(em))
    CALL CD_HermiteCable_Drag_Element(qb, ve, 1.0_wp, fluid, 100.0_wp, RHOW, DIAM, CDN, CDT, fb, jq, jv, es, em)
    CALL require(es == CD_HCDYN_OK, '2x-stretch drag: '//TRIM(em))
    ratio = (fb(3) + fb(9))/(fa(3) + fa(9))            ! net transverse force ratio
    WRITE (*, '(A,F6.3)') '  [drag] net transverse force ratio (2x stretch / unit) = ', ratio
    CALL require(ABS(ratio - 2.0_wp) < 0.05_wp, 'drag scales with deformed cable length (2x stretch -> 2x drag)')
  END SUBROUTINE check_drag_arc_length_scaling

  SUBROUTINE check_set_drag_rollback()
    !! Set_Drag is transactional: when the consistent-acceleration refresh fails AFTER the parameters
    !! are installed (a finite but overflowing current makes the rest drag non-finite), the model
    !! must be rolled back to its previous valid state -- from a no-drag prior (has_drag stays off,
    !! a stays ~0) AND from a valid-drag prior (the old current survives) -- and remain steppable.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dv(NE), cn(NE), ct(NE), cur(3)
    INTEGER :: es
    CHARACTER(300) :: em
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'rollback init: '//TRIM(em))
    dv = DIAM; cn = CDN; ct = CDT
    ! Overflowing (finite) current: |u| u ~ 1e400 -> Inf rest drag -> the refresh fails.
    cur = [1.0e200_wp, 0.0_wp, 0.0_wp]
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCDYN_OK, 'overflowing current fails the drag refresh')
    CALL require(.NOT. m%has_drag, 'failed Set_Drag from a no-drag prior rolls has_drag back off')
    CALL require(nan_max_abs(m%a) < 1.0e-8_wp, 'failed Set_Drag restores the previous acceleration')
    CALL CD_HermiteCable_Dyn_Step(m, 0.05_wp, 30, 1.0e-8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'model still steps after a failed Set_Drag: '//TRIM(em))
    ! From a VALID drag prior: the old configuration must survive a failed re-configure.
    cur = [0.5_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL require(es == CD_HCDYN_OK, 'valid Set_Drag accepted: '//TRIM(em))
    cur = [1.0e200_wp, 0.0_wp, 0.0_wp]
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCDYN_OK, 'overflowing re-configure fails')
    CALL require(m%has_drag .AND. ABS(m%current(1) - 0.5_wp) <= 0.0_wp, &
                 'failed re-configure keeps the previous valid drag configuration')
    CALL CD_HermiteCable_Dyn_Step(m, 0.05_wp, 30, 1.0e-8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'model still steps on the rolled-back drag config: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_set_drag_rollback

  SUBROUTINE check_fully_constrained_validation()
    !! A fully constrained model (no free DOFs) must still VALIDATE its configuration: Init rejects a
    !! geometrically degenerate seed, and Set_Drag with a non-finite rest drag fails closed (and rolls
    !! back) instead of deferring the failure to the next Step. The early no-free-DOF return must skip
    !! only the mass solve, not the residual assembly.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp) :: l1(1), ea1(1), ei1(1), ra1(1), w1(1), seed(12), dv(1), cn(1), ct(1), cur(3)
    INTEGER :: fx(12), i, es
    CHARACTER(300) :: em
    l1 = 1.0_wp; ea1 = EA; ei1 = EI; ra1 = RHOA; w1 = 0.0_wp
    fx = [(i, i=1, 12)]                                  ! every DOF fixed
    ! Degenerate fully constrained seed (coincident nodes, zero tangents) must be rejected at Init.
    seed = 0.0_wp
    CALL CD_HermiteCable_Dyn_Init(m, l1, ea1, ei1, ra1, w1, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es /= CD_HCDYN_OK, 'fully constrained Init rejects a degenerate seed')
    ! Valid straight fully constrained seed: Init OK.
    seed = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Dyn_Init(m, l1, ea1, ei1, ra1, w1, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'fully constrained Init accepts a valid seed: '//TRIM(em))
    ! Overflowing current: the rest drag is non-finite, so Set_Drag must fail closed and roll back
    ! even though there is no mass solve to run.
    dv = DIAM; cn = CDN; ct = CDT; cur = [1.0e200_wp, 0.0_wp, 0.0_wp]
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCDYN_OK, 'fully constrained Set_Drag fails closed on a non-finite rest drag')
    CALL require(.NOT. m%has_drag, 'fully constrained failed Set_Drag rolls back')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE check_fully_constrained_validation

  SUBROUTINE check_still_water_fixed_point()
    !! Drag is zero at rest in still water: the straight equilibrium stays put.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: maxv
    INTEGER :: es, s
    CHARACTER(300) :: em
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'still-water init: '//TRIM(em))
    CALL enable_drag(m, 0.0_wp)
    maxv = 0.0_wp
    DO s = 1, 20
      CALL CD_HermiteCable_Dyn_Step(m, 0.05_wp, 30, 1.0e-9_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN; CALL require(.FALSE., 'still-water step: '//TRIM(em)); EXIT; END IF
      maxv = MAX(maxv, nan_max_abs(m%v))
    END DO
    CALL require(maxv < 1.0e-9_wp, 'still-water rest state stays at rest with drag enabled')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_still_water_fixed_point

  SUBROUTINE check_current_rest_acceleration()
    !! A transverse current on an at-rest straight cable induces a non-zero initial acceleration --
    !! confirming Set_Drag refreshes the consistent a0 (still water leaves the straight cable at a0=0).
    TYPE(CD_HermiteCableDynType), ALLOCATABLE :: m   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dv(NE), cn(NE), ct(NE), cur(3)
    INTEGER :: es
    CHARACTER(300) :: em
    ALLOCATE (m)
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'current-a0 init: '//TRIM(em))
    CALL require(nan_max_abs(m%a) < 1.0e-8_wp, 'straight no-load cable has ~zero initial acceleration')
    dv = DIAM; cn = CDN; ct = CDT; cur = [0.0_wp, 0.0_wp, 0.4_wp]      ! transverse current
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL require(es == CD_HCDYN_OK, 'set transverse-current drag: '//TRIM(em))
    CALL require(nan_max_abs(m%a) > 1.0e-3_wp, 'transverse current induces a nonzero rest acceleration (a0 refreshed)')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_current_rest_acceleration

  SUBROUTINE check_held_field_history_contract()
    !! A host-held field is sampled for the NEXT time interval. Its first installation
    !! completes a0 initialisation, but a later update must not overwrite the committed
    !! generalised-alpha acceleration from the preceding time station. The update still
    !! validates the proposed load transactionally.
    TYPE(CD_HermiteCableDynType), ALLOCATABLE :: m   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: fluid_v(3, NE + 1), fluid_a(3, NE + 1), waterline(NE + 1)
    REAL(wp), ALLOCATABLE :: committed_a(:)
    INTEGER :: es
    CHARACTER(300) :: em

    ALLOCATE (m)
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.4_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'held-field init: '//TRIM(em))
    CALL enable_drag(m, 0.0_wp)
    fluid_v = 0.0_wp; fluid_v(3, :) = 0.4_wp
    fluid_a = 0.0_wp; waterline = WL
    CALL CD_HermiteCable_Dyn_Set_Held_Fluid(m, fluid_v, fluid_a, waterline, es, em)
    CALL require(es == CD_HCDYN_OK, 'first held field accepted: '//TRIM(em))
    CALL require(nan_max_abs(m%a) > 1.0e-3_wp, 'first held field establishes a consistent a0')

    committed_a = m%a
    fluid_v(3, :) = 0.8_wp
    CALL CD_HermiteCable_Dyn_Set_Held_Fluid(m, fluid_v, fluid_a, waterline, es, em)
    CALL require(es == CD_HCDYN_OK, 'later held field accepted: '//TRIM(em))
    CALL require(ALL(m%a == committed_a), 'later held field preserves committed acceleration bit-for-bit')
    CALL require(ALL(m%hf_u == fluid_v), 'later held field is installed for the next interval')

    fluid_v = 0.0_wp; fluid_v(3, :) = 1.0e200_wp
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_Dyn_Set_Held_Fluid(m, fluid_v, fluid_a, waterline, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCDYN_OK, 'overflowing repeated held field fails validation')
    CALL require(ALL(m%a == committed_a), 'failed repeated held field preserves committed acceleration')
    CALL require(ALL(m%hf_u(3, :) == 0.8_wp), 'failed repeated held field restores the prior fluid field')

    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx, committed_a)
  END SUBROUTINE check_held_field_history_contract

  SUBROUTINE check_energy_dissipation()
    !! With rho_inf = 1 the only dissipation is drag: total mechanical energy must fall monotonically
    !! with drag on, and be conserved with drag off.
    REAL(wp) :: e_off, e_on
    e_off = run_energy(.FALSE.)
    e_on = run_energy(.TRUE.)
    WRITE (*, '(A,F7.3,A,F7.3,A)') '  [drag] energy retained after 2 periods: drag off = ', e_off, &
      '   drag on = ', e_on, '  (fraction of initial)'
    CALL require(e_off > 0.98_wp, 'drag OFF conserves mechanical energy (rho_inf=1)')
    CALL require(e_on < 0.85_wp, 'drag ON dissipates a clear fraction of the mechanical energy')
  END SUBROUTINE check_energy_dissipation

  REAL(wp) FUNCTION run_energy(with_drag) RESULT(retained)
    !! Release a submerged beam from a modal displacement; return E_end/E_0 over 2 periods, and
    !! (drag on) assert monotone decay.
    LOGICAL, INTENT(IN) :: with_drag
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: AMP = 0.3_wp, DT = 0.02_wp
    REAL(wp) :: ke, se, e0, eprev, enow, omega1, T1
    INTEGER :: es, s, nstep
    CHARACTER(300) :: em
    omega1 = (PI/LB)**2*SQRT(EI/RHOA); T1 = 2.0_wp*PI/omega1
    nstep = NINT(2.0_wp*T1/DT)
    CALL build_beam(AMP, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 1.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'energy init: '//TRIM(em))
    IF (with_drag) CALL enable_drag(m, 0.0_wp)
    CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
    e0 = ke + se; eprev = e0; enow = e0
    DO s = 1, nstep
      CALL CD_HermiteCable_Dyn_Step(m, DT, 40, 1.0e-8_wp, es, em)
      IF (es /= CD_HCDYN_OK) THEN; CALL require(.FALSE., 'energy step: '//TRIM(em)); EXIT; END IF
      CALL CD_HermiteCable_Dyn_Energy(m, ke, se, es, em)
      enow = ke + se
      IF (with_drag) CALL require(enow <= eprev + 1.0e-9_wp*e0, 'drag energy is monotone non-increasing')
      eprev = enow
    END DO
    retained = enow/e0
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END FUNCTION run_energy

  SUBROUTINE check_tangent_convergence()
    !! A drag-active step under prescribed hang-off-like motion converges in a few Newton iterations,
    !! which requires the analytic velocity Jacobian folded into the effective tangent to be correct.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: DT = 0.05_wp
    REAL(wp) :: t, res
    INTEGER :: es, s, iters, maxiters, pd(1)
    REAL(wp) :: pq(1), pv(1), pa(1)
    CHARACTER(300) :: em
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'tangent init: '//TRIM(em))
    CALL enable_drag(m, 0.5_wp)          ! a steady current so drag is active and nonlinear
    ! The iteration count gauges the tangent at each iterate: no factor carried across steps.
    CALL CD_HermiteCable_Dyn_Set_TangentReuse(m, .FALSE., es, em)
    CALL require(es == CD_HCDYN_OK, 'tangent reuse off: '//TRIM(em))
    pd(1) = 3; maxiters = 0
    DO s = 1, 40
      t = REAL(s, wp)*DT
      pq(1) = 0.5_wp*SIN(2.0_wp*PI*t/5.0_wp)
      pv(1) = 0.5_wp*(2.0_wp*PI/5.0_wp)*COS(2.0_wp*PI*t/5.0_wp)
      pa(1) = -0.5_wp*(2.0_wp*PI/5.0_wp)**2*SIN(2.0_wp*PI*t/5.0_wp)
      CALL CD_HermiteCable_Dyn_Step(m, DT, 30, 1.0e-8_wp, es, em, iters_out=iters, res_out=res, &
                                    pres_dofs=pd, pres_q=pq, pres_v=pv, pres_a=pa)
      IF (es /= CD_HCDYN_OK) THEN; CALL require(.FALSE., 'tangent step: '//TRIM(em)); EXIT; END IF
      maxiters = MAX(maxiters, iters)
    END DO
    WRITE (*, '(A,I0,A)') '  [drag] max Newton iterations per step under drag + current + drive = ', maxiters, &
      ' (correct implicit tangent => few)'
    CALL require(es == CD_HCDYN_OK .AND. maxiters <= 6, 'drag-active steps converge in a few Newton iterations')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
  END SUBROUTINE check_tangent_convergence

  SUBROUTINE check_fail_closed()
    !! Bad drag configuration is rejected.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp) :: dv(NE), cn(NE), ct(NE), cur(3)
    INTEGER :: es
    CHARACTER(300) :: em
    dv = DIAM; cn = CDN; ct = CDT; cur = 0.0_wp
    ! Set_Drag before init.
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject Set_Drag on an uninitialised model')
    CALL build_beam(0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'init for drag fail-closed')
    CALL CD_HermiteCable_Dyn_Set_Drag(m, -1.0_wp, dv, cn, ct, WL, cur, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject nonpositive rho_w')
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)     ! valid baseline
    CALL require(es == CD_HCDYN_OK, 'accept valid drag config')
    cn(1) = -1.0_wp
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv, cn, ct, WL, cur, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject negative drag coefficient')
    cn(1) = CDN
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, dv(1:NE - 1), cn, ct, WL, cur, es, em)
    CALL require(es /= CD_HCDYN_OK, 'reject wrong-length diam array')
    CALL CD_HermiteCable_Dyn_End(m)
    DEALLOCATE (l0, EAv, EIv, rhoAv, wv, seed, fx)
    ! The public per-length drag primitive rejects a non-finite relative velocity rather than
    ! returning NaN force/Jacobians with ErrStat = OK.
    CALL check_drag_primitive_nan()
  END SUBROUTINE check_fail_closed

  SUBROUTINE check_drag_primitive_nan()
    REAL(wp) :: rel(3), tan(3), force(3), jr(3, 3), jt(3, 3), nan
    INTEGER :: es
    CHARACTER(300) :: em
    nan = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    tan = [1.0_wp, 0.0_wp, 0.0_wp]; rel = [0.5_wp, nan, 0.0_wp]
    CALL CD_Morison_Drag_Per_Length_Jac(rel, tan, RHOW, DIAM, CDN, CDT, force, jr, jt, es, em)
    CALL require(es /= CD_HYDRO_OK, 'drag primitive rejects a non-finite relative velocity')
    ! A fully DRY element must still reject malformed hydro scalars (the wet/dry cull must not skip
    ! config validation): straight element at z = 0, waterline far below -> every Gauss point dry.
    CALL check_dry_element_bad_scalars()
  END SUBROUTINE check_drag_primitive_nan

  SUBROUTINE check_dry_element_bad_scalars()
    REAL(wp) :: qe(12), ve(12), fluid(3), fd(12), jq(12, 12), jv(12, 12)
    INTEGER :: es
    CHARACTER(300) :: em
    qe = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    ve = 0.0_wp; fluid = 0.0_wp
    ! waterline at z = -100 -> the element (z = 0) is fully dry; diameter is negative.
    CALL CD_HermiteCable_Drag_Element(qe, ve, 1.0_wp, fluid, -100.0_wp, RHOW, -1.0_wp, CDN, CDT, &
                                      fd, jq, jv, es, em)
    CALL require(es /= CD_HCDYN_OK, 'dry element rejects a negative diameter (config check precedes culling)')
    ! Same dry element with a valid config is fine and returns zero loads.
    CALL CD_HermiteCable_Drag_Element(qe, ve, 1.0_wp, fluid, -100.0_wp, RHOW, DIAM, CDN, CDT, &
                                      fd, jq, jv, es, em)
    CALL require(es == CD_HCDYN_OK .AND. nan_max_abs(fd) <= 0.0_wp, 'valid dry element returns OK with zero drag')
  END SUBROUTINE check_dry_element_bad_scalars

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_drag_dynamics
