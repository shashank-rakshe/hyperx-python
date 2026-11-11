! File: tests/test_body_hydro.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_body_hydro
  !! Analytic gates for the Rigid6 hydrostatic model (rigid6_hydrostatics via
  !! CD_Rigid6_Hydrostatics_Probe, still water at z = 0):
  !!   1. waterplane restoring in the heading frame: a body heeled by delta about its own x (y)
  !!      axis carries -C44 delta (-C55 delta) about that axis at yaw 0, 90, 180 and 270 deg,
  !!      with C44 /= C55;
  !!   2. equivalent-sphere wetting: a dry body carries exactly -m g, a submerged one
  !!      rhoW g V - m g, and in between rhoW g pi h^2 (3 r_e - h)/3, continuously; bodyWetting
  !!      moordyn keeps the full buoyancy;
  !!   3. the weight acts at the centre of gravity: moment c x (-m g e3) about the reference;
  !!   4. the Morison force on a submerged body is rhoW CdA |u - v| (u - v)/2 + rhoW V (1 + Ca) du
  !!      (bodyHydro morison) or the drag alone (bodyHydro moordyn), with the added mass
  !!      rhoW V Ca in the effective mass either way.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Rigid6_Hydrostatics_Probe, CD_Rigid6_Fluid_Probe, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: RHO_W = 1025.0_wp, GRAV = 9.80665_wp
  INTEGER :: nfail

  nfail = 0
  CALL check_heading_frame()
  CALL check_wetting()
  CALL check_cg_moment()
  CALL check_fluid_inertia()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' body hydrostatics check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Rigid6 hydrostatics (heading-frame restoring, sphere wetting, CG moment)'

CONTAINS

  SUBROUTINE check_fluid_inertia()
    REAL(wp), PARAMETER :: M = 4.0e4_wp, V = 30.0_wp, CDA = 12.0_wp, CA = 0.8_wp
    REAL(wp), PARAMETER :: VB(3) = [0.3_wp, -0.1_wp, 0.05_wp], U(3) = [1.2_wp, 0.4_wp, -0.2_wp]
    REAL(wp), PARAMETER :: DU(3) = [0.5_wp, -0.3_wp, 0.2_wp]
    REAL(wp) :: f_mor(3), f_md(3), m_mor, m_md, drag(3), inertia(3), rel(3)
    INTEGER :: es
    CHARACTER(256) :: em
    rel = U - VB
    drag = 0.5_wp*RHO_W*CDA*NORM2(rel)*rel
    inertia = RHO_W*V*(1.0_wp + CA)*DU
    CALL CD_Rigid6_Fluid_Probe(M, V, CDA, CA, [0.0_wp, 0.0_wp, -100.0_wp], VB, U, DU, .FALSE., f_mor, m_mor, es, em)
    CALL require(es == CD_DECKDRV_OK, 'Rigid6 fluid probe (morison): '//TRIM(em))
    CALL CD_Rigid6_Fluid_Probe(M, V, CDA, CA, [0.0_wp, 0.0_wp, -100.0_wp], VB, U, DU, .TRUE., f_md, m_md, es, em)
    CALL require(es == CD_DECKDRV_OK, 'Rigid6 fluid probe (moordyn): '//TRIM(em))
    CALL require(NORM2(f_mor - (drag + inertia)) <= 1.0e-12_wp*NORM2(drag + inertia), &
                 'bodyHydro morison: drag plus fluid inertia rhoW V (1 + Ca) du')
    CALL require(NORM2(f_md - drag) <= 1.0e-12_wp*NORM2(drag), 'bodyHydro moordyn: drag only, no fluid inertia')
    CALL require(ABS(m_mor - (M + RHO_W*V*CA)) <= 1.0e-12_wp*M .AND. ABS(m_md - m_mor) <= 0.0_wp, &
                 'added mass rhoW V Ca in the effective mass under both models')
  END SUBROUTINE check_fluid_inertia

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  PURE FUNCTION rot_axis(k, ang) RESULT(r)
    INTEGER, INTENT(IN) :: k
    REAL(wp), INTENT(IN) :: ang
    REAL(wp) :: r(3, 3), c, s
    c = COS(ang)
    s = SIN(ang)
    r = 0.0_wp
    SELECT CASE (k)
    CASE (1)
      r = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, c, s, 0.0_wp, -s, c], [3, 3])
    CASE (2)
      r = RESHAPE([c, 0.0_wp, -s, 0.0_wp, 1.0_wp, 0.0_wp, s, 0.0_wp, c], [3, 3])
    CASE DEFAULT
      r = RESHAPE([c, s, 0.0_wp, -s, c, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp], [3, 3])
    END SELECT
  END FUNCTION rot_axis

  SUBROUTINE check_heading_frame()
    REAL(wp), PARAMETER :: C44 = 2.0e6_wp, C55 = 5.0e6_wp, DELTA = 0.05_wp
    REAL(wp) :: r_ref(3, 3), r_tilt(3, 3), f(3), m(3), phi, expect(3), worst
    INTEGER :: iy, ax, es
    CHARACTER(256) :: em

    worst = 0.0_wp
    DO iy = 0, 3
      r_ref = rot_axis(3, REAL(iy, wp)*0.5_wp*PI)
      DO ax = 1, 2
        r_tilt = rot_axis(ax, DELTA)
        r_tilt = MATMUL(r_ref, r_tilt)
        CALL CD_Rigid6_Hydrostatics_Probe(0.0_wp, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, C44, C55], r_ref, &
                                          [0.0_wp, 0.0_wp, -5.0_wp], r_tilt, .FALSE., f, m, phi, es, em)
        CALL require(es == CD_DECKDRV_OK, 'probe: '//TRIM(em))
        IF (ax == 1) expect = -C44*DELTA*r_ref(:, 1)
        IF (ax == 2) expect = -C55*DELTA*r_ref(:, 2)
        worst = MAX(worst, NORM2(m - expect)/NORM2(expect))
        IF (NORM2(m - expect) > 1.0e-9_wp*NORM2(expect)) WRITE (*, '(A,2I3,6ES12.4)') ' yaw/axis ', iy, ax, m, expect
      END DO
    END DO
    WRITE (*, '(A,ES10.2)') 'heading-frame restoring, yaw 0/90/180/270 deg: worst relative error ', worst
    CALL require(worst <= 1.0e-12_wp, 'roll/pitch restoring C44/C55 about the body axes at any heading')
  END SUBROUTINE check_heading_frame

  SUBROUTINE check_wetting()
    REAL(wp), PARAMETER :: MASS = 5.0e3_wp, VOL = 8.0_wp
    REAL(wp) :: f(3), m(3), phi, re, z, h, fz_ref, fprev, jump
    INTEGER :: k, es
    CHARACTER(256) :: em
    REAL(wp) :: eye(3, 3)

    eye = rot_axis(3, 0.0_wp)
    re = (3.0_wp*VOL/(4.0_wp*PI))**(1.0_wp/3.0_wp)
    fprev = 0.0_wp
    jump = 0.0_wp
    DO k = -40, 40
      z = REAL(k, wp)*0.05_wp
      CALL CD_Rigid6_Hydrostatics_Probe(MASS, VOL, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], eye, &
                                        [0.0_wp, 0.0_wp, z], eye, .FALSE., f, m, phi, es, em)
      h = MIN(2.0_wp*re, MAX(0.0_wp, -(z - re)))
      fz_ref = RHO_W*GRAV*PI*h*h*(3.0_wp*re - h)/3.0_wp - MASS*GRAV
      CALL require(ABS(f(3) - fz_ref) <= 1.0e-9_wp*RHO_W*GRAV*VOL, 'equivalent-sphere buoyancy')
      IF (k > -40) jump = MAX(jump, ABS(f(3) - fprev))
      fprev = f(3)
    END DO
    CALL CD_Rigid6_Hydrostatics_Probe(MASS, VOL, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], eye, &
                                      [0.0_wp, 0.0_wp, 10.0_wp], eye, .FALSE., f, m, phi, es, em)
    CALL require(ABS(f(3) + MASS*GRAV) <= 0.0_wp, 'a dry body carries exactly -m g')
    WRITE (*, '(A,ES12.4,A)') 'dry body vertical force ', f(3), ' N'
    CALL require(jump <= 1.001_wp*RHO_W*GRAV*PI*re*re*0.05_wp, 'buoyancy continuous through the surface')
    CALL CD_Rigid6_Hydrostatics_Probe(MASS, VOL, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], eye, &
                                      [0.0_wp, 0.0_wp, 10.0_wp], eye, .TRUE., f, m, phi, es, em)
    CALL require(ABS(f(3) - (RHO_W*VOL - MASS)*GRAV) <= 1.0e-9_wp*RHO_W*GRAV*VOL, &
                 'bodyWetting moordyn keeps the full buoyancy')
  END SUBROUTINE check_wetting

  SUBROUTINE check_cg_moment()
    REAL(wp), PARAMETER :: MASS = 2.0e3_wp
    REAL(wp) :: f(3), m(3), phi, rot(3, 3), ra(3, 3), rb(3, 3), c(3), expect(3)
    INTEGER :: es
    CHARACTER(256) :: em

    ra = rot_axis(3, 0.7_wp)
    rb = rot_axis(2, 0.3_wp)
    rot = MATMUL(ra, rb)
    ra = rot_axis(3, 0.0_wp)
    CALL CD_Rigid6_Hydrostatics_Probe(MASS, 0.0_wp, [1.0_wp, 0.5_wp, -2.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], &
                                      ra, [0.0_wp, 0.0_wp, 5.0_wp], rot, .FALSE., f, m, phi, es, em)
    c = MATMUL(rot, [1.0_wp, 0.5_wp, -2.0_wp])
    expect = [c(2)*(-MASS*GRAV), -c(1)*(-MASS*GRAV), 0.0_wp]
    CALL require(NORM2(m - expect) <= 1.0e-12_wp*MASS*GRAV*NORM2(c), 'weight moment about the reference from the CG')
  END SUBROUTINE check_cg_moment
END PROGRAM test_body_hydro
