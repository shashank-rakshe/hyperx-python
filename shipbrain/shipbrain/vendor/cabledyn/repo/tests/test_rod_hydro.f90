! File: tests/test_rod_hydro.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_rod_hydro
  !! Analytic gates for the rigid-rod hydrostatic and Morison model (rod_environment_force via
  !! CD_Rod_Hydro_Probe, still water, free surface at z = 0):
  !!   1. rotational drag: a submerged rod spinning about its centre carries the moment
  !!      rhoW Cd d |w| w L^4/64; exact for an even NumSegs, converging with NumSegs otherwise;
  !!   2. a submerged rod carries the buoyancy rhoW g V and no moment at any tilt;
  !!   3. a tilted surface-piercing rod carries the buoyancy and moment of the exact displaced
  !!      volume of a cylinder cut by the waterplane (wall-sided: V = A l_w, centroid shifted by
  !!      tan(phi) I/(A l_w) across and tan(phi)^2 I/(2 A l_w) along the axis, I = pi d^4/64);
  !!   4. the righting moment of a floating spar heeled about its waterline at constant
  !!      displacement is rhoW g V GZ, GZ = sin(phi) (GM + BM tan(phi)^2/2), BM = I/V;
  !!   5. a horizontal rod crossing the surface carries the buoyancy of the circular-segment
  !!      area, continuously in heave;
  !!   6. the wave dynamic pressure (end caps) is g a cosh(k(z+h))/cosh(kh) cos(theta) per unit
  !!      density, and the component sum equals the sum of its single components.
  !!   7. a host field held at the segment stations converges to the directly evaluated wave
  !!      loads at second order in 1/NumSegs (see check_held_stations);
  !!   8. rodHydro moordyn adds MoorDyn's rho g (pi d^4/32) sin(phi) cos(phi) pitch moment to a
  !!      surface-piercing rod (End A wet, End B dry) and leaves a submerged rod unchanged.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Hydro, ONLY: CD_Airy_Wave_Kinematics_Precomputed, CD_Component_Wave_Kinematics
  USE CableDyn_DeckDriver, ONLY: CD_Rod_Hydro_Probe, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: RHO_W = 1025.0_wp, GRAV = 9.80665_wp
  INTEGER :: nfail

  nfail = 0
  CALL check_rotational_drag()
  CALL check_submerged_buoyancy()
  CALL check_piercing_cut()
  CALL check_righting_arm()
  CALL check_horizontal_crossing()
  CALL check_dynamic_pressure()
  CALL check_held_stations()
  CALL check_moordyn_rod_hydro()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' rod hydro check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: rod hydro (rotational drag, buoyancy, waterplane cut, righting arm, crossing)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE probe(diam, length, nsegs, coef, centre, axis, omega, f, m)
    REAL(wp), INTENT(IN) :: diam, length, coef(6), centre(3), axis(3), omega(3)
    INTEGER, INTENT(IN) :: nsegs
    REAL(wp), INTENT(OUT) :: f(3), m(3)
    REAL(wp) :: am(6, 6)
    INTEGER :: es
    CHARACTER(256) :: em
    CALL CD_Rod_Hydro_Probe(diam, length, nsegs, coef, centre, axis, [0.0_wp, 0.0_wp, 0.0_wp], omega, f, m, am, &
                            es, em)
    CALL require(es == CD_DECKDRV_OK, 'probe: '//TRIM(em))
  END SUBROUTINE probe

  PURE FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  SUBROUTINE check_rotational_drag()
    REAL(wp), PARAMETER :: D = 0.5_wp, L = 10.0_wp, CD = 1.2_wp, W = 0.8_wp
    INTEGER, PARAMETER :: NS(6) = [1, 2, 3, 9, 10, 27]
    REAL(wp) :: f(3), m(3), m_ref, err(6)
    INTEGER :: k
    CHARACTER(120) :: lab

    m_ref = RHO_W*CD*D*W*W*L**4/64.0_wp
    DO k = 1, 6
      CALL probe(D, L, NS(k), [CD, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, -20.0_wp], &
                 [1.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, W, 0.0_wp], f, m)
      err(k) = ABS(-m(2) - m_ref)/m_ref
      WRITE (*, '(A,I3,A,ES12.4,A,ES10.2)') 'rotational drag NumSegs', NS(k), ': moment ', -m(2), &
        ' N m, rel. error ', err(k)
      CALL require(ABS(m(1)) + ABS(m(3)) <= 1.0e-9_wp*m_ref, 'rotational drag moment is about the spin axis')
    END DO
    WRITE (lab, '(A,ES12.4)') 'rotational drag analytic moment ', m_ref
    CALL require(err(2) <= 1.0e-12_wp .AND. err(5) <= 1.0e-12_wp, 'even NumSegs: exact '//TRIM(lab))
    CALL require(err(1) > err(3) .AND. err(3) > err(4) .AND. err(4) > err(6) .AND. err(6) <= 1.0e-4_wp, &
                 'odd NumSegs: converges to '//TRIM(lab))
  END SUBROUTINE check_rotational_drag

  SUBROUTINE check_submerged_buoyancy()
    REAL(wp), PARAMETER :: D = 1.0_wp, L = 8.0_wp
    REAL(wp) :: f(3), m(3), phi, b_ref
    INTEGER :: k

    b_ref = RHO_W*GRAV*0.25_wp*PI*D*D*L
    DO k = 0, 6
      phi = REAL(k, wp)*15.0_wp*PI/180.0_wp
      CALL probe(D, L, 3, [1.0_wp, 1.0_wp, 0.6_wp, 0.6_wp, 0.0_wp, 0.0_wp], [1.0_wp, 2.0_wp, -30.0_wp], &
                 [SIN(phi), 0.0_wp, COS(phi)], [0.0_wp, 0.0_wp, 0.0_wp], f, m)
      CALL require(ABS(f(3) - b_ref) <= 1.0e-12_wp*b_ref .AND. ABS(f(1)) + ABS(f(2)) <= 1.0e-9_wp*b_ref .AND. &
                   NORM2(m) <= 1.0e-9_wp*b_ref*L, 'submerged rod buoyancy rhoW g V without moment at any tilt')
    END DO
  END SUBROUTINE check_submerged_buoyancy

  SUBROUTINE cut_reference(diam, length, lw, phi, f_ref, m_ref)
    !! Buoyancy and its moment about the rod centre for a rod whose axis (in the x-z plane, End A
    !! down, tilted by phi toward +x) crosses the surface at axial distance lw from End A, with
    !! End A at the origin-referenced position below: wall-sided cut of the cylinder.
    REAL(wp), INTENT(IN) :: diam, length, lw, phi
    REAL(wp), INTENT(OUT) :: f_ref(3), m_ref(3)
    REAL(wp) :: a, ii, t, q(3), p(3), end_a(3), centre(3), xi_c, u_c, pc(3)
    a = 0.25_wp*PI*diam**2
    ii = PI*diam**4/64.0_wp
    t = TAN(phi)
    q = [SIN(phi), 0.0_wp, COS(phi)]
    p = [-COS(phi), 0.0_wp, SIN(phi)]
    end_a = -lw*q
    centre = end_a + 0.5_wp*length*q
    xi_c = 0.5_wp*lw + t*t*ii/(2.0_wp*a*lw)
    u_c = -t*ii/(a*lw)
    pc = end_a + xi_c*q + u_c*p
    f_ref = [0.0_wp, 0.0_wp, RHO_W*GRAV*a*lw]
    m_ref = cross(pc - centre, f_ref)
  END SUBROUTINE cut_reference

  SUBROUTINE check_piercing_cut()
    REAL(wp), PARAMETER :: D = 2.0_wp, L = 20.0_wp, LW = 14.0_wp
    INTEGER, PARAMETER :: NS(2) = [1, 5]
    REAL(wp) :: f(3), m(3), f_ref(3), m_ref(3), phi, q(3), err_f, err_m, worst
    INTEGER :: k, j

    worst = 0.0_wp
    DO j = 1, 2
      DO k = 1, 4
        phi = REAL(k, wp)*10.0_wp*PI/180.0_wp
        q = [SIN(phi), 0.0_wp, COS(phi)]
        CALL cut_reference(D, L, LW, phi, f_ref, m_ref)
        CALL probe(D, L, NS(j), [0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], (0.5_wp*L - LW)*q, q, &
                   [0.0_wp, 0.0_wp, 0.0_wp], f, m)
        err_f = NORM2(f - f_ref)/f_ref(3)
        err_m = NORM2(m - m_ref)/(f_ref(3)*D)
        worst = MAX(worst, err_f, err_m)
      END DO
    END DO
    WRITE (*, '(A,ES10.2)') 'surface-piercing cut, tilt 10-40 deg: worst relative error ', worst
    CALL require(worst <= 1.0e-8_wp, 'surface-piercing rod buoyancy and waterplane moment of the cut cylinder')
  END SUBROUTINE check_piercing_cut

  SUBROUTINE check_moordyn_rod_hydro()
    REAL(wp), PARAMETER :: D = 2.0_wp, L = 20.0_wp, LW = 14.0_wp
    REAL(wp) :: f0(3), m0(3), f1(3), m1(3), am(6, 6), phi, q(3), dm_ref(3), worst
    INTEGER :: k, es
    CHARACTER(256) :: em
    worst = 0.0_wp
    DO k = 1, 4
      phi = REAL(k, wp)*10.0_wp*PI/180.0_wp
      q = [SIN(phi), 0.0_wp, COS(phi)]
      CALL CD_Rod_Hydro_Probe(D, L, 5, [0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], (0.5_wp*L - LW)*q, q, &
                              [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], f0, m0, am, es, em)
      CALL require(es == CD_DECKDRV_OK, 'exact rod hydro probe: '//TRIM(em))
      CALL CD_Rod_Hydro_Probe(D, L, 5, [0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], (0.5_wp*L - LW)*q, q, &
                              [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], f1, m1, am, es, em, &
                              moordyn_hydro=.TRUE.)
      CALL require(es == CD_DECKDRV_OK, 'moordyn rod hydro probe: '//TRIM(em))
      ! (axis x e3) = (0, -sin(phi), 0) for the axis (sin(phi), 0, cos(phi))
      dm_ref = [0.0_wp, -RHO_W*GRAV*(PI*D**4/32.0_wp)*SIN(phi)*COS(phi), 0.0_wp]
      worst = MAX(worst, NORM2(f1 - f0)/NORM2(f0), NORM2((m1 - m0) - dm_ref)/NORM2(dm_ref))
    END DO
    WRITE (*, '(A,ES10.2)') 'rodHydro moordyn pitch moment vs rho g (pi d^4/32) sin cos: worst relative error ', worst
    CALL require(worst <= 1.0e-12_wp, 'rodHydro moordyn adds rho g (pi d^4/32) sin(phi) cos(phi) and no force')
    ! a fully submerged rod: the two models agree
    q = [SIN(0.3_wp), 0.0_wp, COS(0.3_wp)]
    CALL CD_Rod_Hydro_Probe(D, L, 5, [0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, -50.0_wp], &
                            q, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], f0, m0, am, es, em)
    CALL CD_Rod_Hydro_Probe(D, L, 5, [0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, -50.0_wp], &
                            q, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], f1, m1, am, es, em, &
                            moordyn_hydro=.TRUE.)
    CALL require(NORM2(f1 - f0) + NORM2(m1 - m0) <= 1.0e-12_wp*NORM2(f0), 'rodHydro moordyn leaves a submerged rod')
  END SUBROUTINE check_moordyn_rod_hydro

  SUBROUTINE check_righting_arm()
    !! Uniform spar: L = 20 m, d = 2 m, draft 14 m (G at mid-length); heel about the waterline.
    REAL(wp), PARAMETER :: D = 2.0_wp, L = 20.0_wp, LW = 14.0_wp
    REAL(wp) :: f(3), m(3), a, v, bm, gm, gz, phi, q(3), m_ref
    INTEGER :: k

    a = 0.25_wp*PI*D*D
    v = a*LW
    bm = (PI*D**4/64.0_wp)/v
    gm = 0.5_wp*LW + bm - 0.5_wp*L
    WRITE (*, '(A,3F10.5)') 'spar KB, BM, GM [m]: ', 0.5_wp*LW, bm, gm
    DO k = 1, 3
      phi = REAL(k, wp)*5.0_wp*PI/180.0_wp
      q = [SIN(phi), 0.0_wp, COS(phi)]
      CALL probe(D, L, 10, [0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], (0.5_wp*L - LW)*q, q, &
                 [0.0_wp, 0.0_wp, 0.0_wp], f, m)
      gz = SIN(phi)*(gm + 0.5_wp*bm*TAN(phi)**2)
      m_ref = RHO_W*GRAV*v*gz
      WRITE (*, '(A,F5.1,A,2ES14.6)') 'righting moment at ', phi*180.0_wp/PI, ' deg got/analytic [N m]: ', &
        -m(2), m_ref
      CALL require(ABS(f(3) - RHO_W*GRAV*v) <= 1.0e-9_wp*RHO_W*GRAV*v, 'heel at constant displacement')
      CALL require(ABS(-m(2) - m_ref) <= 1.0e-7_wp*ABS(m_ref), 'spar righting moment rhoW g V GZ (GM, BM = I/V)')
    END DO
  END SUBROUTINE check_righting_arm

  SUBROUTINE check_horizontal_crossing()
    REAL(wp), PARAMETER :: D = 1.0_wp, L = 6.0_wp
    REAL(wp) :: f(3), m(3), z, dd, aw, r, f_prev, jump
    INTEGER :: k

    r = 0.5_wp*D
    f_prev = -1.0_wp
    jump = 0.0_wp
    DO k = -60, 60
      z = REAL(k, wp)*0.01_wp
      CALL probe(D, L, 4, [1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, z], &
                 [1.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], f, m)
      dd = MIN(r, MAX(-r, -z))
      aw = r*r*ACOS(-dd/r) + dd*SQRT(MAX(0.0_wp, r*r - dd*dd))
      CALL require(ABS(f(3) - RHO_W*GRAV*aw*L) <= 1.0e-9_wp*RHO_W*GRAV*L*r*r, &
                   'horizontal rod buoyancy of the circular-segment area')
      IF (f_prev >= 0.0_wp) jump = MAX(jump, ABS(f(3) - f_prev))
      f_prev = f(3)
    END DO
    ! a 1 cm heave step changes the force by at most the waterplane stiffness times the step
    CALL require(jump <= 1.001_wp*RHO_W*GRAV*D*L*0.01_wp, 'horizontal rod buoyancy continuous through the surface')
  END SUBROUTINE check_horizontal_crossing
  SUBROUTINE check_dynamic_pressure()
    REAL(wp), PARAMETER :: H = 200.0_wp, T1 = 9.0_wp, T2 = 14.0_wp, A1 = 1.3_wp, A2 = 0.7_wp
    REAL(wp) :: k(2), w(2), eta, u(3), du(3), pd, pd1, pd2, ref, theta, z
    INTEGER :: es, j
    CHARACTER(256) :: em

    w = 2.0_wp*PI/[T1, T2]
    DO j = 1, 2
      k(j) = wavenumber(w(j))
    END DO
    z = -35.0_wp
    CALL CD_Airy_Wave_Kinematics_Precomputed(12.0_wp, 3.0_wp, z, 4.1_wp, 2.0_wp*A1, w(1), k(1), H, 20.0_wp, &
                                             .FALSE., eta, u, du, es, em, pdyn=pd1)
    theta = k(1)*(12.0_wp*COS(20.0_wp*PI/180.0_wp) + 3.0_wp*SIN(20.0_wp*PI/180.0_wp)) - w(1)*4.1_wp
    ref = GRAV*A1*COSH(k(1)*(z + H))/COSH(k(1)*H)*COS(theta)
    CALL require(es == 0 .AND. ABS(pd1 - ref) <= 1.0e-10_wp*GRAV*A1, 'Airy dynamic pressure g a cosh/cosh cos')
    CALL CD_Airy_Wave_Kinematics_Precomputed(12.0_wp, 3.0_wp, z, 4.1_wp, 2.0_wp*A2, w(2), k(2), H, 20.0_wp, &
                                             .FALSE., eta, u, du, es, em, pdyn=pd2)
    CALL CD_Component_Wave_Kinematics(12.0_wp, 3.0_wp, z, 4.1_wp, H, 20.0_wp, .FALSE., w, k, [A1, A2], &
                                      [0.0_wp, 0.0_wp], eta, u, du, es, em, pdyn=pd)
    CALL require(es == 0 .AND. ABS(pd - pd1 - pd2) <= 1.0e-10_wp*GRAV, 'component dynamic pressure is the sum')
  END SUBROUTINE check_dynamic_pressure

  SUBROUTINE check_held_stations()
    !! 7. a host field held at the NumSegs + 1 segment stations (the coupled rods' SeaState
    !!    sampling, with the dynamic pressure on the end caps) converges to the loads computed
    !!    from the same Airy wave evaluated at every quadrature point, at second order in
    !!    1/NumSegs; with a vertical rod (all stations on one depth line) the end-cap pressure
    !!    is sampled at the ends exactly, so held and direct differ only through the side terms.
    REAL(wp), PARAMETER :: D = 2.0_wp, L = 30.0_wp, WAV(3) = [6.0_wp, 9.0_wp, 2.3_wp]
    REAL(wp), PARAMETER :: COEF(6) = [1.0_wp, 1.0_wp, 0.6_wp, 0.6_wp, 0.3_wp, 0.2_wp]
    REAL(wp), PARAMETER :: COEF_V(6) = [1.0_wp, 1.0_wp, 0.6_wp, 0.6_wp, 0.0_wp, 0.0_wp]
    INTEGER, PARAMETER :: NS(3) = [4, 8, 16]
    REAL(wp) :: axis(3), centre(3), vel(3), f_d(3), m_d(3), f_h(3), m_h(3), am(6, 6), err(3), scale
    INTEGER :: k, es
    CHARACTER(256) :: em
    CHARACTER(120) :: lab

    axis = [0.6_wp, 0.0_wp, 0.8_wp]
    centre = [3.0_wp, 1.0_wp, -25.0_wp]
    vel = [0.2_wp, -0.1_wp, 0.05_wp]
    DO k = 1, 3
      CALL CD_Rod_Hydro_Probe(D, L, NS(k), COEF, centre, axis, vel, [0.0_wp, 0.0_wp, 0.0_wp], f_d, m_d, am, &
                              es, em, wave=WAV)
      CALL require(es == CD_DECKDRV_OK, 'held: direct probe: '//TRIM(em))
      CALL CD_Rod_Hydro_Probe(D, L, NS(k), COEF, centre, axis, vel, [0.0_wp, 0.0_wp, 0.0_wp], f_h, m_h, am, &
                              es, em, wave=WAV, held=.TRUE.)
      CALL require(es == CD_DECKDRV_OK, 'held: held probe: '//TRIM(em))
      scale = MAX(NORM2(f_d - [0.0_wp, 0.0_wp, RHO_W*GRAV*0.25_wp*PI*D*D*L]), 1.0_wp)
      err(k) = MAX(NORM2(f_h - f_d), NORM2(m_h - m_d)/L)/scale
    END DO
    WRITE (lab, '(A,3ES10.2)') 'held: relative error at NumSegs 4/8/16 =', err
    WRITE (*, '(A)') TRIM(lab)
    CALL require(err(3) < 2.0e-3_wp, TRIM(lab)//' (16 segments within 0.2 %)')
    CALL require(err(1)/err(2) > 3.0_wp .AND. err(2)/err(3) > 3.0_wp, TRIM(lab)//' (second-order convergence)')
    ! vertical rod without side axial coefficients: every axial load (end-cap pressure, CdEnd/CaEnd
    ! terms, buoyancy) is taken at the ends, where the stations sit, so held equals direct
    axis = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL CD_Rod_Hydro_Probe(D, L, 64, COEF_V, centre, axis, vel, [0.0_wp, 0.0_wp, 0.0_wp], f_d, m_d, am, &
                            es, em, wave=WAV)
    CALL CD_Rod_Hydro_Probe(D, L, 64, COEF_V, centre, axis, vel, [0.0_wp, 0.0_wp, 0.0_wp], f_h, m_h, am, &
                            es, em, wave=WAV, held=.TRUE.)
    WRITE (lab, '(A,ES10.2)') 'held: vertical rod axial force difference (N) =', ABS(f_h(3) - f_d(3))
    WRITE (*, '(A)') TRIM(lab)
    CALL require(ABS(f_h(3) - f_d(3)) < 1.0e-9_wp*RHO_W*GRAV*0.25_wp*PI*D*D*L, TRIM(lab))
  END SUBROUTINE check_held_stations

  REAL(wp) FUNCTION wavenumber(omega) RESULT(k)
    REAL(wp), INTENT(IN) :: omega
    INTEGER :: it
    k = omega*omega/GRAV
    DO it = 1, 100
      k = omega*omega/(GRAV*TANH(k*200.0_wp))
    END DO
  END FUNCTION wavenumber
END PROGRAM test_rod_hydro
