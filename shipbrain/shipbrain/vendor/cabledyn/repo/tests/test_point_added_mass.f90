! File: tests/test_point_added_mass.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_point_added_mass
  !! Stability gate for a light or massless Free/Connect junction whose attached lines
  !! carry Morison added mass. The dynamic-point step must treat the attached end nodes'
  !! full self inertia (structural diagonal AND the added-mass self block) implicitly;
  !! a lagged added-mass block larger than the point's implicit mass gives an explicit
  !! amplification factor above one at every dt, so the junction diverges and a smaller
  !! dt only makes it diverge in fewer seconds. The stiff end-segment axial mode
  !! (sqrt(2 EA/l0 / m) ~ 550 rad/s here) must also stay bounded from dt 1e-2 to 1e-5,
  !! which needs the end-segment stiffness advanced implicitly as well.
  !!
  !! Rig: two 10-element EI=0 lines (EA 1e6 N, rho_a 10 kg/m, l0 1 m, 0.1% pre-strain,
  !! 1000 N tension) meet at a Free junction between two Fixed anchors; fully wet
  !! (rho 1025, D 0.5 m, Cat 0). The junction starts 0.01 m off the line axis.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_End_Model, CD_MODEL_OK, &
                            CD_Get_Model_EndNodeAddedMass, CD_Get_Model_EndNodeTangent
  USE CableDyn_System, ONLY: CD_SystemType, CD_SystemPointType, CD_LineEndpointBinding, &
                             CD_Init_System_From_Points, CD_End_System, CD_Get_System_CoupledMotion, &
                             CD_Update_System_CoupledMotion, CD_Get_System_Point_State, &
                             CD_Step_System_DynamicPoints, CD_SYSTEM_OK, CD_POINT_FIXED, CD_POINT_FREE, &
                             CD_LINE_END_A, CD_LINE_END_B
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 10
  REAL(wp), PARAMETER :: RHO = 1025.0_wp, DIAM = 0.5_wp, Z0 = 0.01_wp
  REAL(wp), PARAMETER :: EA_LINE = 1.0e6_wp, RHOA = 10.0_wp, STRAIN = 1.0e-3_wp, TENSION = EA_LINE*STRAIN
  REAL(wp), PARAMETER :: SPAN = 10.0_wp*(1.0_wp + STRAIN)
  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  INTEGER :: failures, icase, idt, im
  REAL(wp) :: cans(4), dts(4), masses(4), t_half(4), t_mass(4), zmax, amax, t_h, z_end(2), omega, t_ref
  LOGICAL :: ok

  failures = 0
  cans = [0.0_wp, 0.1_wp, 1.0_wp, 2.0_wp]
  dts = [1.0e-2_wp, 1.0e-3_wp, 1.0e-4_wp, 1.0e-5_wp]

  CALL case_end_node_block()

  ! (1) Massless junction: finite and bounded for every Can at every dt. A fixed step
  ! count (not a fixed window) is the stringent form: the pre-fix amplification is per
  ! step, so the smallest dt diverged the fastest.
  DO icase = 1, SIZE(cans)
    DO idt = 1, SIZE(dts)
      CALL run(cans(icase), 0.0_wp, dts(idt), 400, ok, zmax, amax, t_h, z_end(1))
      CALL require(ok, 'massless junction step failed or went non-finite', cans(icase), dts(idt))
      CALL require(zmax <= 1.5_wp*Z0, 'massless junction displacement grew beyond the release offset', &
                   cans(icase), dts(idt))
      CALL require(amax < 1.0e3_wp, 'massless junction acceleration unbounded', cans(icase), dts(idt))
    END DO
  END DO

  ! (2) Physical trend: the junction relaxes on the transverse wave time l0/c with
  ! c = sqrt(T/(rho_a + m_added)), so the half-offset time grows with Can; a smaller dt
  ! converges the massless trajectory instead of destabilizing it.
  DO icase = 1, SIZE(cans)
    CALL run(cans(icase), 0.0_wp, 1.0e-4_wp, 5000, ok, zmax, amax, t_half(icase), z_end(1))
    CALL require(ok .AND. t_half(icase) > 0.0_wp, 'massless junction never relaxed to half offset', &
                 cans(icase), 1.0e-4_wp)
  END DO
  DO icase = 2, SIZE(cans)
    CALL require(t_half(icase) > t_half(icase - 1), 'half-offset time must grow with added mass', &
                 cans(icase), 1.0e-4_wp)
  END DO
  ! The relaxation time scales like sqrt(rho_a + m_added): Can 2 vs Can 0 is sqrt(41.25).
  CALL require(ABS(t_half(4)/t_half(1)/SQRT((RHOA + 2.0_wp*RHO*PI/4.0_wp*DIAM**2)/RHOA) - 1.0_wp) < 0.25_wp, &
               'half-offset time ratio does not follow the transverse wave-speed ratio', 2.0_wp, 1.0e-4_wp)
  CALL run(1.0_wp, 0.0_wp, 1.0e-3_wp, 2000, ok, zmax, amax, t_h, z_end(1))
  CALL require(ok, 'Can 1 dt 1e-3 two-second march', 1.0_wp, 1.0e-3_wp)
  CALL run(1.0_wp, 0.0_wp, 1.0e-4_wp, 20000, ok, zmax, amax, t_h, z_end(2))
  CALL require(ok, 'Can 1 dt 1e-4 two-second march', 1.0_wp, 1.0e-4_wp)
  CALL require(ABS(z_end(1) - z_end(2)) < 0.1_wp*Z0, 'massless trajectory does not converge in dt', &
               1.0_wp, 1.0e-4_wp)

  ! (3) Heavy-junction limit: at Can 1 the junction-mass family is continuous down to
  ! the massless limit (the half-offset time falls monotonically with junction mass and
  ! a 1 kg junction matches the massless one), and a dominant junction mass recovers
  ! the spring-mass half-offset time acos(1/2)/omega with k = 2T/L.
  masses = [1.0e3_wp, 1.0e2_wp, 1.0_wp, 0.0_wp]
  DO im = 1, SIZE(masses)
    CALL run(1.0_wp, masses(im), 1.0e-3_wp, 4000, ok, zmax, amax, t_mass(im), z_end(1))
    CALL require(ok .AND. t_mass(im) > 0.0_wp, 'junction-mass family run failed', masses(im), 1.0e-3_wp)
  END DO
  DO im = 2, SIZE(masses)
    CALL require(t_mass(im) < t_mass(im - 1), 'half-offset time must fall with junction mass', &
                 masses(im), 1.0e-3_wp)
  END DO
  CALL require(ABS(t_mass(3) - t_mass(4)) <= 0.05_wp*t_mass(4) + 2.0e-3_wp, &
               '1 kg junction does not match the massless limit', 1.0_wp, 1.0e-3_wp)
  CALL run(1.0_wp, 1.0e5_wp, 1.0e-2_wp, 4000, ok, zmax, amax, t_h, z_end(1))
  omega = SQRT(2.0_wp*TENSION/SPAN/1.0e5_wp)
  t_ref = ACOS(0.5_wp)/omega
  CALL require(ok .AND. ABS(t_h/t_ref - 1.0_wp) < 0.03_wp, 'heavy junction misses the spring-mass limit', &
               1.0e5_wp, 1.0e-2_wp)

  IF (failures /= 0) THEN
    WRITE (*, '(A,I0,A)') 'test_point_added_mass: ', failures, ' failure(s)'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'test_point_added_mass: all checks passed'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_end_node_block()
    !! The accessor returns the end node's own wet consistent added-mass block: for a
    !! horizontal line, Cat 0, fully wet, it is (l0/3) rho pi D^2/4 Can on the two
    !! normal axes and zero along the axis, summed over the one attached element.
    TYPE(CD_ModelType) :: model
    REAL(wp) :: blk(3, 3), cblk(3, 3), ma, kvn(3)
    INTEGER :: es, k
    CHARACTER(240) :: em
    CALL init_line(model, 0.0_wp, 1.0_wp)
    ma = RHO*PI/4.0_wp*DIAM**2*1.0_wp/3.0_wp
    CALL CD_Get_Model_EndNodeAddedMass(model, 1, blk, es, em)
    CALL require(es == CD_MODEL_OK .AND. ABS(blk(1, 1)) < 1.0e-9_wp .AND. ABS(blk(2, 2) - ma) < 1.0e-9_wp*ma &
                 .AND. ABS(blk(3, 3) - ma) < 1.0e-9_wp*ma .AND. ABS(blk(2, 3)) < 1.0e-9_wp, &
                 'end-node added-mass block (slot A)', 1.0_wp, 0.0_wp)
    CALL CD_Get_Model_EndNodeAddedMass(model, 2, blk, es, em)
    CALL require(es == CD_MODEL_OK .AND. ABS(blk(3, 3) - ma) < 1.0e-9_wp*ma, &
                 'end-node added-mass block (slot B)', 1.0_wp, 0.0_wp)
    CALL CD_Get_Model_EndNodeAddedMass(model, 3, blk, es, em)
    CALL require(es /= CD_MODEL_OK .AND. nan_max_abs(blk) <= 0.0_wp, 'bad coupled slot must fail closed', &
                 1.0_wp, 0.0_wp)
    CALL CD_End_Model(model, es, em)
    CALL init_line(model, 0.0_wp, 0.0_wp)
    CALL CD_Get_Model_EndNodeAddedMass(model, 1, blk, es, em)
    CALL require(es == CD_MODEL_OK .AND. nan_max_abs(blk) <= 0.0_wp, 'no added mass gives a zero block', 0.0_wp, 0.0_wp)
    ! End-segment tangent: EA/l0 along the (x) axis, T/l on the normal axes, and no
    ! damping block on an undamped line.
    CALL CD_Get_Model_EndNodeTangent(model, 2, blk, cblk, es, em)
    CALL require(es == CD_MODEL_OK .AND. ABS(blk(1, 1) - EA_LINE) < 1.0e-9_wp*EA_LINE .AND. &
                 ABS(blk(2, 2) - TENSION/(1.0_wp + STRAIN)) < 1.0e-9_wp*TENSION .AND. &
                 ABS(blk(1, 2)) < 1.0e-6_wp .AND. nan_max_abs(cblk) <= 0.0_wp, &
                 'end-node elastic tangent block', 0.0_wp, 0.0_wp)
    ! Neighbour coupling: a rigid translation carries the neighbour at the end node's
    ! velocity, so sum K_e v_o equals K v and the implicit point update feels no spring
    ! force (the point is not braked); a neighbour at rest gives zero.
    model%v = 0.0_wp
    CALL CD_Get_Model_EndNodeTangent(model, 2, blk, cblk, es, em, kvn)
    CALL require(es == CD_MODEL_OK .AND. nan_max_abs(kvn) <= 0.0_wp, 'neighbour at rest: zero coupling', &
                 0.0_wp, 0.0_wp)
    DO k = 1, SIZE(model%v)/3
      model%v(3*k - 2:3*k) = [0.3_wp, -0.2_wp, 0.1_wp]
    END DO
    CALL CD_Get_Model_EndNodeTangent(model, 2, blk, cblk, es, em, kvn)
    CALL require(es == CD_MODEL_OK .AND. &
                 nan_max_abs(kvn - MATMUL(blk, [0.3_wp, -0.2_wp, 0.1_wp])) <= 1.0e-9_wp*EA_LINE, &
                 'rigid translation: neighbour coupling equals K v', 0.0_wp, 0.0_wp)
    model%v = 0.0_wp
    CALL CD_Get_Model_EndNodeTangent(model, 0, blk, cblk, es, em)
    CALL require(es /= CD_MODEL_OK .AND. nan_max_abs(blk) <= 0.0_wp, 'tangent bad slot must fail closed', &
                 0.0_wp, 0.0_wp)
    CALL CD_End_Model(model, es, em)
  END SUBROUTINE case_end_node_block

  SUBROUTINE run(can, point_mass, dt, nstep, run_ok, run_zmax, run_amax, run_thalf, run_zlast)
    !! March the rig; report success, the peak junction offset and acceleration, the
    !! first time the offset falls to half the release value (-1 if never), and the
    !! final offset.
    REAL(wp), INTENT(IN) :: can, point_mass, dt
    INTEGER, INTENT(IN) :: nstep
    LOGICAL, INTENT(OUT) :: run_ok
    REAL(wp), INTENT(OUT) :: run_zmax, run_amax, run_thalf, run_zlast
    TYPE(CD_ModelType) :: models(2)
    TYPE(CD_SystemType) :: sys
    TYPE(CD_SystemPointType) :: points(3)
    TYPE(CD_LineEndpointBinding) :: bindings(4)
    REAL(wp) :: q(9), v(9), a(9), qp(3), vp(3), ap(3)
    INTEGER :: es, it, k
    LOGICAL :: conv, stl
    CHARACTER(240) :: em

    run_ok = .FALSE.
    run_zmax = 0.0_wp
    run_amax = 0.0_wp
    run_thalf = -1.0_wp
    run_zlast = 0.0_wp
    CALL init_line(models(1), 0.0_wp, can)
    CALL init_line(models(2), SPAN, can)
    points(1) = CD_SystemPointType(id=1, point_type=CD_POINT_FIXED, q=[0.0_wp, 0.0_wp, 0.0_wp])
    points(2) = CD_SystemPointType(id=2, point_type=CD_POINT_FREE, q=[SPAN, 0.0_wp, 0.0_wp], mass=point_mass)
    points(3) = CD_SystemPointType(id=3, point_type=CD_POINT_FIXED, q=[2.0_wp*SPAN, 0.0_wp, 0.0_wp])
    bindings(1) = CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_A, point_id=1)
    bindings(2) = CD_LineEndpointBinding(line_index=1, line_end=CD_LINE_END_B, point_id=2)
    bindings(3) = CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_A, point_id=2)
    bindings(4) = CD_LineEndpointBinding(line_index=2, line_end=CD_LINE_END_B, point_id=3)
    march: BLOCK
      CALL CD_Init_System_From_Points(sys, models, points, bindings, es, em)
      IF (es /= CD_SYSTEM_OK) THEN
        WRITE (*, '(A)') 'system init failed: '//TRIM(em)
        EXIT march
      END IF
      CALL CD_Get_System_CoupledMotion(sys, q, v, a, es, em)
      q(6) = q(6) + Z0
      CALL CD_Update_System_CoupledMotion(sys, q, v, a, es, em)
      IF (es /= CD_SYSTEM_OK) EXIT march
      qp = 0.0_wp
      DO k = 1, nstep
        CALL CD_Step_System_DynamicPoints(sys, dt, conv, stl, it, es, em)
        IF (es /= CD_SYSTEM_OK) THEN
          WRITE (*, '(A,I0,A)') 'step ', k, ' failed: '//TRIM(em)
          EXIT march
        END IF
        CALL CD_Get_System_Point_State(sys, 2, qp, vp, ap, es, em)
        IF (es /= CD_SYSTEM_OK) EXIT march
        IF (.NOT. (ALL(IEEE_IS_FINITE(qp)) .AND. ALL(IEEE_IS_FINITE(ap)))) EXIT march
        run_zmax = MAX(run_zmax, ABS(qp(3)))
        run_amax = MAX(run_amax, ABS(ap(3)))
        IF (run_thalf < 0.0_wp .AND. qp(3) <= 0.5_wp*Z0) run_thalf = REAL(k, wp)*dt
      END DO
      run_zlast = qp(3)
      run_ok = .TRUE.
    END BLOCK march
    CALL CD_End_System(sys, es, em)
    CALL CD_End_Model(models(1), es, em)
    CALL CD_End_Model(models(2), es, em)
  END SUBROUTINE run

  SUBROUTINE init_line(model, x0, can)
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    REAL(wp), INTENT(IN) :: x0, can
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, NE), fixed(6), e, es
    REAL(wp) :: q0(3*(NE + 1)), v0(3*(NE + 1)), f(3*(NE + 1)), l0(NE), ea(NE), rho_a(NE), wl(NE + 1)
    CHARACTER(240) :: em
    DO e = 1, NE
      conn(:, e) = [e, e + 1]
    END DO
    l0 = 1.0_wp
    ea = EA_LINE
    rho_a = RHOA
    q0 = 0.0_wp
    DO e = 0, NE
      q0(3*e + 1) = x0 + (1.0_wp + STRAIN)*REAL(e, wp)
    END DO
    v0 = 0.0_wp
    f = 0.0_wp
    wl = 1.0e6_wp
    fixed = [1, 2, 3, 3*NE + 1, 3*NE + 2, 3*NE + 3]
    IF (can > 0.0_wp) THEN
      CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .TRUE., f, fixed, cfg, es, em, &
                         added_mass_waterline_z=wl, added_mass_rho=RHO, added_mass_diameter=DIAM, &
                         added_mass_can=can, added_mass_cat=0.0_wp)
    ELSE
      CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .TRUE., f, fixed, cfg, es, em)
    END IF
    IF (es /= CD_MODEL_OK) THEN
      WRITE (*, '(A)') 'model init failed: '//TRIM(em)
      ERROR STOP 2
    END IF
  END SUBROUTINE init_line

  SUBROUTINE require(cond, msg, can, dt)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    REAL(wp), INTENT(IN) :: can, dt
    IF (cond) RETURN
    failures = failures + 1
    WRITE (*, '(A,ES10.3,A,ES9.2,A)') 'FAIL: '//msg//' (param=', can, ', dt=', dt, ')'
  END SUBROUTINE require
END PROGRAM test_point_added_mass
