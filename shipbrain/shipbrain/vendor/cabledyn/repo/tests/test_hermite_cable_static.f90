! File: tests/test_hermite_cable_static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_cable_static
  !! Static-equilibrium gates for the finite-EI cubic-Hermite bending-cable line.
  !!   A  suspended heavy line converges to the closed-form catenary (axial + gravity
  !!      + assembly + banded Newton), matching z(s) = sqrt(a^2 + s^2) to the discrete
  !!      vs continuum floor -- the L1-7-class shape gate;
  !!   B  a small-deflection cantilever under self-weight matches the linear-beam tip
  !!      deflection w L^4 / (8 EI) -- the closed-form bending gate that the finite-EI
  !!      curvature differentiator rests on;
  !!   C  a heavier line drapes onto a penalty seabed with FINITE touchdown curvature
  !!      (the EI=0 catenary has a slope discontinuity there) and rests near the bed;
  !!   D  degenerate inputs fail closed.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HermiteCable_Trivial_Seed, CD_HCSTAT_OK, &
                                         CD_HermiteCable_Sequence_Coarse_Max_Length, CD_HermiteStaticCurrentType
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Reaction, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK, CD_HermiteCable_Dyn_End_Force, &
                                          CD_HermiteCable_Drag_Element, CD_HermiteCable_Dyn_Step, &
                                          CD_HermiteCable_Dyn_Node_Recovery
  USE CableDyn_SeabedContact, ONLY: CD_HermiteCable_Friction_Spring => CD_Seabed_Friction_Spring, &
                                    CD_Seabed_End_Element_Share, CD_Seabed_Normal_Law
  USE CableDyn_Line, ONLY: CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Init_Bathymetry
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG, &
                                                                              IEEE_GET_FLAG, IEEE_DIVIDE_BY_ZERO
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  INTEGER :: nfail
  nfail = 0
  CALL check_catenary()
  CALL check_cantilever()
  CALL check_touchdown()
  CALL check_double_touchdown_seed()
  CALL check_mesh_length_independence()
  CALL check_pinned_span_sag()
  CALL check_input_rejection()
  CALL check_dry_buoyancy_static()
  CALL check_seabed_mesh_jump()
  CALL check_scalar_contact_on_slope()
  CALL check_taut_line_anchored_on_floor()
  CALL check_weightless_taut_line()
  CALL check_laid_line_node_recovery()
  CALL check_end_support_energy_gradient()
  CALL check_frictionless_slope_run()
  CALL check_long_sequence_hierarchy()
  CALL check_current_static()
  CALL check_friction_spring()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI Hermite bending-cable static solve is correct'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE check_friction_spring()
    !! Static seabed friction spring f = k d / sqrt(1 + (k|d|/C)^2): linear k d for a small
    !! stretch, bounded by the capacity C, and its Jacobians df/dd and df/dC match central
    !! differences.
    REAL(wp), PARAMETER :: K = 8.0e5_wp, CAP = 650.0_wp
    REAL(wp) :: d(2), f(2), dfd(2, 2), dfc(2), fp(2), fm(2), dd(2, 2), dc(2), h, jd(2, 2), jc(2), err
    INTEGER :: j, trial
    CALL CD_HermiteCable_Friction_Spring([1.0e-7_wp, -2.0e-7_wp], K, CAP, f, dfd, dfc)
    CALL require(nan_max_abs(f - K*[1.0e-7_wp, -2.0e-7_wp]) < 1.0e-6_wp*K*2.0e-7_wp, 'friction spring: linear')
    CALL CD_HermiteCable_Friction_Spring([3.0_wp, 4.0_wp], K, CAP, f, dfd, dfc)
    CALL require(NORM2(f) < CAP .AND. NORM2(f) > 0.9999_wp*CAP, 'friction spring: capped at mu N')
    CALL CD_HermiteCable_Friction_Spring([3.0_wp, 4.0_wp], K, 0.0_wp, f, dfd, dfc)
    CALL require(nan_max_abs(f) <= 0.0_wp, 'friction spring: no contact, no force')
    DO trial = 1, 3
      d = [4.0e-4_wp, -2.5e-4_wp]*REAL(trial*trial, wp)
      CALL CD_HermiteCable_Friction_Spring(d, K, CAP, f, dfd, dfc)
      h = 1.0e-8_wp
      DO j = 1, 2
        dd = 0.0_wp
        dd(j, j) = h
        CALL CD_HermiteCable_Friction_Spring(d + dd(:, j), K, CAP, fp, jd, jc)
        CALL CD_HermiteCable_Friction_Spring(d - dd(:, j), K, CAP, fm, jd, jc)
        err = nan_max_abs((fp - fm)/(2.0_wp*h) - dfd(:, j))
        CALL require(err < 1.0e-6_wp*K, 'friction spring: df/dd')
      END DO
      h = 1.0e-4_wp*CAP
      CALL CD_HermiteCable_Friction_Spring(d, K, CAP + h, fp, jd, jc)
      CALL CD_HermiteCable_Friction_Spring(d, K, CAP - h, fm, jd, jc)
      dc = (fp - fm)/(2.0_wp*h)
      CALL require(nan_max_abs(dc - dfc) < 1.0e-6_wp*MAX(1.0_wp, nan_max_abs(dfc)), 'friction spring: df/dC')
    END DO
  END SUBROUTINE check_friction_spring

  SUBROUTINE check_current_static()
    !! Steady-current drag in the static equilibrium. A 100 m line from a hang-off 5 m under
    !! water to a point 60 m below and 80 m across, in a current across its plane (3D solve,
    !! only the endpoint positions held) and along it (planar solve):
    !!   (a) the line is pushed downstream (out of plane for the cross current);
    !!   (b) global force balance: the two end forces the line exerts equal its total weight
    !!       plus the total drag (independent sum of the element drag loads at the solution);
    !!   (c) the dynamic path started from the static state in the same current stays at
    !!       rest (end force unchanged over 40 steps).
    INTEGER, PARAMETER :: NE = 20
    REAL(wp), PARAMETER :: L = 100.0_wp, G = 9.80665_wp, RHOW = 1025.0_wp, D = 0.2_wp, MPL = 80.0_wp
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(6*(NE + 1)), q(6*(NE + 1)), curv(NE + 1), res
    REAL(wp) :: rho_a(NE), diam(NE), cdn(NE), cdt(NE), u(3), fa(3), fb(3), fa1(3), fb1(3), fd(12), load(3)
    REAL(wp) :: chord(3), ve(12), qe(12), a3(3), b3(3)
    TYPE(CD_HermiteStaticCurrentType) :: cur
    TYPE(CD_HermiteCableDynType) :: dyn
    INTEGER :: e, i, iters, es, k, icase
    INTEGER, ALLOCATABLE :: fixed(:)
    CHARACTER(300) :: em
    l0 = L/NE
    EA = 1.0e8_wp
    EI = 1.0e4_wp
    w = (MPL - RHOW*0.25_wp*3.14159265358979324_wp*D*D)*G
    rho_a = MPL
    diam = D
    cdn = 1.2_wp
    cdt = 0.1_wp
    a3 = [0.0_wp, 0.0_wp, -65.0_wp]
    b3 = [80.0_wp, 0.0_wp, -5.0_wp]
    chord = (b3 - a3)/NORM2(b3 - a3)
    DO i = 1, NE + 1
      seed(6*(i - 1) + 1:6*(i - 1) + 3) = a3 + (b3 - a3)*REAL(i - 1, wp)/REAL(NE, wp)
      seed(6*(i - 1) + 4:6*i) = chord
    END DO
    ALLOCATE (cur%arc_end(NE), cur%diam(NE), cur%cdn(NE), cur%cdt(NE))
    DO e = 1, NE
      cur%arc_end(e) = SUM(l0(1:e))
    END DO
    cur%diam = diam; cur%cdn = cdn; cur%cdt = cdt
    cur%rho = RHOW
    cur%waterline_z = 0.0_wp
    DO icase = 1, 2
      IF (icase == 1) THEN
        u = [0.0_wp, 1.5_wp, 0.0_wp]
        fixed = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
      ELSE
        u = [1.5_wp, 0.0_wp, 0.0_wp]
        ALLOCATE (fixed(0))
        fixed = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
        DO i = 1, NE + 1
          fixed = [fixed, 6*(i - 1) + 2, 6*(i - 1) + 5]
        END DO
      END IF
      cur%velocity = u
      CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, -1.0e4_wp, 0.0_wp, 4, 200, 1.0e-10_wp, &
                                        1.0_wp, q, curv, res, iters, es, em, current=cur)
      CALL require(es == CD_HCSTAT_OK, 'current static solve converges: '//TRIM(em))
      IF (es /= CD_HCSTAT_OK) CYCLE
      IF (icase == 1) THEN
        CALL require(q(6*(NE/2) + 2) > 1.0_wp, 'cross current pushes the line out of its plane')
      ELSE
        CALL require(q(6*(NE/2) + 1) > seed(6*(NE/2) + 1) + 0.5_wp, 'in-plane current pushes the line downstream')
      END IF
      CALL CD_HermiteCable_Dyn_Init(dyn, l0, EA, EI, rho_a, w, q, fixed, -1.0e4_wp, 0.0_wp, 0.8_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'current dynamic init: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_Set_Drag(dyn, RHOW, diam, cdn, cdt, 0.0_wp, u, es, em, gravity=G)
      CALL require(es == CD_HCDYN_OK, 'current dynamic drag: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_End_Force(dyn, 1, fa, es, em)
      CALL CD_HermiteCable_Dyn_End_Force(dyn, NE + 1, fb, es, em)
      ! Independent balance: weight plus the element drag loads summed over the r-slots.
      load = [0.0_wp, 0.0_wp, -SUM(w*l0)]
      ve = 0.0_wp
      DO e = 1, NE
        qe(1:6) = q(6*(e - 1) + 1:6*e)
        qe(7:12) = q(6*e + 1:6*e + 6)
        CALL CD_HermiteCable_Drag_Element(qe, ve, l0(e), u, 0.0_wp, RHOW, D, cdn(e), cdt(e), fd, &
                                          ErrStat=es, ErrMsg=em)
        load = load + fd(1:3) + fd(7:9)
      END DO
      CALL require(NORM2(fa + fb - load) < 1.0e-6_wp*NORM2(load), 'end forces balance weight plus current drag')
      CALL require(NORM2([load(1), load(2)]) > 0.1_wp*SUM(w*l0), 'the current drag is a significant load')
      DO k = 1, 40
        CALL CD_HermiteCable_Dyn_Step(dyn, 0.05_wp, 30, 1.0e-9_wp, es, em)
        IF (es /= CD_HCDYN_OK) EXIT
      END DO
      CALL require(es == CD_HCDYN_OK, 'dynamic march in the current: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_End_Force(dyn, 1, fa1, es, em)
      CALL CD_HermiteCable_Dyn_End_Force(dyn, NE + 1, fb1, es, em)
      CALL require(NORM2(fa1 - fa) < 1.0e-5_wp*NORM2(fa) .AND. NORM2(fb1 - fb) < 1.0e-5_wp*NORM2(fb), &
                   'the static state in current is at rest in the dynamics')
      CALL CD_HermiteCable_Dyn_End(dyn)
      DEALLOCATE (fixed)
    END DO
  END SUBROUTINE check_current_static

  SUBROUTINE check_dry_buoyancy_static()
    !! A vertical line hanging from a support 18 m above the free surface: its submerged
    !! weight w is completed above the surface by the missing buoyancy b = rho g A. The
    !! top tension is then the exact integral w L + b * (dry reference length), where the
    !! dry length follows from the stretched geometry. Checked (i) through the node heights
    !! against the closed form, (ii) through the support reaction of the dynamic model
    !! initialised on the static state with the same free surface (static/dynamic
    !! consistency), whose free DOFs must also start at rest.
    INTEGER, PARAMETER :: NE = 25, NN = NE + 1, NDOF = 6*NN
    REAL(wp), PARAMETER :: G = 9.80665_wp, RHOW = 1025.0_wp, D = 0.2_wp, MPL = 80.0_wp
    REAL(wp), PARAMETER :: EAX = 1.0e6_wp, LTOT = 100.0_wp, ZTOP = 18.0_wp, PI_L = 3.14159265358979324_wp
    TYPE(CD_HermiteCableDynType), ALLOCATABLE :: dyn   ! see DEVELOPMENT.md (gfortran 16 -Wuninitialized)
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), bvec(NE), rho_a(NE), diam(NE), cd0(NE)
    REAL(wp) :: seed(NDOF), q(NDOF), curv(NN), res, area, wsub, buoy, lo, hi, sd, t0, zex, sig, err, fr(3)
    REAL(wp) :: amax, zend
    INTEGER :: fixed(4*NN + 1), nfix, i, es, iters, k
    CHARACTER(300) :: em

    ALLOCATE (dyn)
    area = 0.25_wp*PI_L*D*D
    wsub = (MPL - RHOW*area)*G
    buoy = RHOW*G*area
    l0 = LTOT/REAL(NE, wp); EA = EAX; EI = 1.0e3_wp; w = wsub; bvec = buoy
    seed = 0.0_wp
    nfix = 0
    DO i = 1, NN
      seed(6*i - 3) = ZTOP - REAL(i - 1, wp)*l0(1)
      seed(6*i) = -1.0_wp
      fixed(nfix + 1:nfix + 4) = [6*i - 5, 6*i - 4, 6*i - 2, 6*i - 1]
      nfix = nfix + 4
    END DO
    nfix = nfix + 1
    fixed(nfix) = 3
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1.0e4_wp, 0.0_wp, 1, 100, 1.0e-12_wp, &
                                      1.0_wp, q, curv, res, iters, es, em, waterline_z=0.0_wp, dry_buoyancy=bvec, &
                                      water_weight=RHOW*G)
    CALL require(es == CD_HCSTAT_OK, 'dry-buoyancy static solve converges: '//TRIM(em))
    ! The section law (water_weight: radius D/2) spreads the crossing over the immersion band
    ! symmetrically about the waterline, so the dry length and top tension of this vertical
    ! line equal the centreline closed form below; the dynamic free surface uses the same law.
    ! Closed form: dry reference length sd from ZTOP = sd + (w L sd + (b - w) sd^2/2)/EA.
    lo = 0.0_wp; hi = ZTOP
    DO k = 1, 200
      sd = 0.5_wp*(lo + hi)
      IF (sd + (wsub*LTOT*sd + 0.5_wp*(buoy - wsub)*sd*sd)/EAX > ZTOP) THEN
        hi = sd
      ELSE
        lo = sd
      END IF
    END DO
    t0 = wsub*LTOT + buoy*sd
    err = 0.0_wp
    DO i = 1, NN
      sig = REAL(i - 1, wp)*l0(1)
      IF (sig <= sd) THEN
        zex = ZTOP - sig - (t0*sig - 0.5_wp*(wsub + buoy)*sig*sig)/EAX
      ELSE
        zex = -(sig - sd) - ((t0 - (wsub + buoy)*sd)*(sig - sd) - 0.5_wp*wsub*(sig - sd)**2)/EAX
      END IF
      err = MAX(err, ABS(q(6*i - 3) - zex))
    END DO
    ! The load kink at the waterline inside an element limits the cubic interpolant to
    ! ~1e-5 m on a 6 m stretch; the exact generalized load itself is checked below.
    CALL require(err < 1.0e-4_wp, 'dry-buoyancy static node heights match the closed form')
    rho_a = MPL; diam = D; cd0 = 0.0_wp
    CALL CD_HermiteCable_Dyn_Init(dyn, l0, EA, EI, rho_a, w, q, fixed(1:nfix), -1.0e4_wp, 0.0_wp, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'dry-buoyancy dynamic init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Drag(dyn, RHOW, diam, cd0, cd0, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em, gravity=G)
    CALL require(es == CD_HCDYN_OK, 'dry-buoyancy dynamic free surface: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Reaction(dyn, 1, fr, es, em)
    CALL require(es == CD_HCDYN_OK .AND. ABS(fr(3) + t0) < 1.0e-6_wp*t0, &
                 'top tension = w L + b * dry length (exact integral)')
    amax = nan_max_abs(dyn%a)
    CALL require(amax < 1.0e-6_wp, 'static state is at rest under the dynamic free-surface loads')
    CALL CD_HermiteCable_Dyn_End(dyn)
    zend = q(6*NN - 3)
    ! Without the free surface the same solve carries only the submerged weight.
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1.0e4_wp, 0.0_wp, 1, 100, 1.0e-12_wp, &
                                      1.0_wp, q, curv, res, iters, es, em)
    CALL require(es == CD_HCSTAT_OK .AND. q(6*NN - 3) > zend + 0.02_wp, &
                 'submerged-only line stretches less (reference without dry recovery)')
    ! Argument pairing is enforced.
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1.0e4_wp, 0.0_wp, 1, 100, 1.0e-12_wp, &
                                      1.0_wp, q, curv, res, iters, es, em, waterline_z=0.0_wp)
    CALL require(es /= CD_HCSTAT_OK, 'waterline without dry_buoyancy is rejected')
  END SUBROUTINE check_dry_buoyancy_static

  SUBROUTINE check_seabed_mesh_jump()
    !! A line resting on a flat bed across a change of element length. The tributary nodal
    !! stiffness supports every node with the load it carries, so the penetration stays
    !! near the uniform value w/(kBot d) through the jump, and the bed carries the whole
    !! weight: sum(kn*pen) = w L.
    INTEGER, PARAMETER :: NE = 30, NN = NE + 1
    REAL(wp), PARAMETER :: KBOT = 1.0e5_wp, WS = 800.0_wp, D = 0.2_wp
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), dv(NE), seed(6*NN), q(6*NN), curv(NN), res, x, pen0, dev
    REAL(wp), ALLOCATABLE :: kn(:)
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, iters
    CHARACTER(300) :: em
    l0(1:15) = 2.0_wp; l0(16:30) = 0.5_wp
    EA = 5.0e8_wp; EI = 1.0e4_wp; w = WS; dv = D
    CALL CD_Nodal_Seabed_Stiffness(KBOT, dv, l0, kn, es, em)
    CALL require(es == CD_LINE_OK, 'mesh-jump stiffness')
    seed = 0.0_wp
    DO i = 1, NN
      x = SUM(l0(1:i - 1))
      seed(6*i - 5) = x; seed(6*i - 3) = -100.0_wp; seed(6*i - 2) = 1.0_wp
    END DO
    fixed(1:6) = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    nfix = 6
    DO i = 1, NN
      fixed(nfix + 1:nfix + 2) = [6*i - 4, 6*i - 1]
      nfix = nfix + 2
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -100.0_wp, 0.0_wp, 4, 100, 1.0e-8_wp, &
                                      1.0_wp, q, curv, res, iters, es, em, contact_kn=kn)
    CALL require(es == CD_HCSTAT_OK, 'mesh-jump static solve: '//TRIM(em))
    ! Away from the two pinned (unpenetrated) ends. The element-length-proportional
    ! mapping sank the first fine-mesh node by w*trib/(kBot*d*l_right) = 2.5 pen0; the
    ! remaining few-percent ripple is the consistent Hermite tangent-moment load.
    pen0 = WS/(KBOT*D)
    dev = 0.0_wp
    DO i = 6, NE - 5
      dev = MAX(dev, ABS((-100.0_wp - q(6*i - 3)) - pen0))
    END DO
    CALL require(dev < 0.1_wp*pen0, 'mesh-jump penetration stays near w/(kBot d)')
  END SUBROUTINE check_seabed_mesh_jump

  SUBROUTINE check_weightless_taut_line()
    !! A weightless taut line converges. The relative residual took its force scale from the
    !! line's weight alone (1 N floor), far below the round-off of the 61 kN axial force of a
    !! stiff line (EA 5e8 N), and Newton stagnated at ||R|| ~ 1e-4 N of an equilibrium it had
    !! reached. A 60 m line stretched over a 60.0073 m chord on 212 elements (0.05 m over its
    !! first 8 m) must converge straight, with the axial strain of the chord, C/L - 1.
    INTEGER, PARAMETER :: NA = 160, NB = 52, NE = NA + NB, NN = NE + 1
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(6*NN), q(6*NN), curv(NN), res, chord(3), s, stretch
    LOGICAL :: divided
    INTEGER :: fixed(6), i, es, it
    CHARACTER(512) :: em
    l0(1:NA) = 8.0_wp/NA; l0(NA + 1:) = 1.0_wp
    EA = 5.0e8_wp; EI = 2.0e4_wp; w = 0.0_wp
    chord = [51.97_wp, 0.0_wp, -30.0_wp]
    ! a straight seed along the chord, unit tangents
    s = 0.0_wp
    DO i = 1, NN
      IF (i > 1) s = s + l0(i - 1)
      seed(6*(i - 1) + 1:6*(i - 1) + 3) = chord*s/60.0_wp
      seed(6*(i - 1) + 4:6*(i - 1) + 6) = chord/NORM2(chord)
    END DO
    fixed = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, -1.0e4_wp, 0.0_wp, 4, 200, 1.0e-6_wp, &
                                      1.0_wp, q, curv, res, it, es, em)
    CALL require(es == CD_HCSTAT_OK, 'weightless taut line converges: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    stretch = NORM2(q(6*(NE/2) + 4:6*(NE/2) + 6))
    CALL require(ABS(stretch - NORM2(chord)/60.0_wp) <= 1.0e-9_wp, 'weightless taut line takes the chord strain')
    CALL require(MAXVAL(ABS(curv)) <= 1.0e-8_wp, 'weightless taut line stays straight')
    CALL check_free_end_preload()
    ! An element with EA = 0 (a valid input) leaves the series stiffness at zero: the bound is
    ! skipped, not computed as l0/EA (no division by zero on a held taut seed).
    EA(NA + 1) = 0.0_wp
    CALL IEEE_SET_FLAG(IEEE_DIVIDE_BY_ZERO, .FALSE.)
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, -1.0e4_wp, 0.0_wp, 1, 1, 1.0e-6_wp, &
                                      1.0_wp, q, curv, res, it, es, em)
    CALL IEEE_GET_FLAG(IEEE_DIVIDE_BY_ZERO, divided)
    CALL require(.NOT. divided, 'a held taut line with an EA = 0 element raises no division by zero')
  END SUBROUTINE check_weightless_taut_line

  SUBROUTINE check_free_end_preload()
    !! The taut-chord tension enters the force scale only while both end positions are held. A
    !! cantilever (clamped End A, free End B; EA 1e12 N, EI 1e8 N m^2, 100 N/m over 10 m) seeded
    !! 1 % overstretched would otherwise take a 1e10 N scale from its seed, and its 1000 N weight
    !! would read as converged before the line bent; it must reach the beam deflection
    !! w L^4/(8 EI) = 1.25 mm, as from an unstretched seed.
    INTEGER, PARAMETER :: NE = 10, NN = NE + 1
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed_a(6*NN), seed_b(6*NN), qa(6*NN), qb(6*NN), curv(NN), res
    REAL(wp) :: tip
    INTEGER :: i, es, it
    CHARACTER(512) :: em
    l0 = 1.0_wp; EA = 1.0e12_wp; EI = 1.0e8_wp; w = 100.0_wp
    tip = 100.0_wp*10.0_wp**4/(8.0_wp*1.0e8_wp)
    seed_a = 0.0_wp; seed_b = 0.0_wp
    DO i = 1, NN
      seed_a(6*(i - 1) + 1) = REAL(i - 1, wp)
      seed_b(6*(i - 1) + 1) = 1.01_wp*REAL(i - 1, wp)
      seed_a(6*(i - 1) + 4) = 1.0_wp
      seed_b(6*(i - 1) + 4) = 1.0_wp
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed_a, [1, 2, 3, 4, 5, 6], -1.0e4_wp, 0.0_wp, 4, 200, &
                                      1.0e-6_wp, 1.0_wp, qa, curv, res, it, es, em)
    CALL require(es == CD_HCSTAT_OK, 'cantilever from an unstretched seed converges: '//TRIM(em))
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed_b, [1, 2, 3, 4, 5, 6], -1.0e4_wp, 0.0_wp, 4, 200, &
                                      1.0e-6_wp, 1.0_wp, qb, curv, res, it, es, em)
    CALL require(es == CD_HCSTAT_OK, 'cantilever from an overstretched seed converges: '//TRIM(em))
    CALL require(ABS(-qa(6*NE + 3) - tip) <= 1.0e-3_wp*tip, 'cantilever from an unstretched seed: w L^4/(8 EI)')
    CALL require(ABS(-qb(6*NE + 3) - tip) <= 1.0e-3_wp*tip, &
                 'cantilever from an overstretched seed: w L^4/(8 EI) (no seed preload in the force scale)')
  END SUBROUTINE check_free_end_preload

  SUBROUTINE check_taut_line_anchored_on_floor()
    !! The floor carries the end element's weight moment only where the element lies on it.
    !! A taut line anchored on the floor rises into the water from its anchor: its end element
    !! is clear of the floor beyond the anchor node, the seabed supports none of it, and the
    !! line takes the bending of the same line without a seabed. Its static state (with the
    !! curvature at the pinned anchor) and its held dynamic march must equal those of the
    !! line with no seabed bit for bit. With the floor support decided by the anchor alone,
    !! the cancelled end moment w l0^2/12 moved the line by 7 mm and raised the anchor
    !! curvature by half (2.9e-3 to 4.3e-3 1/m). The element share itself is zero clear of
    !! the floor, one laid, and C1 through touchdown.
    INTEGER, PARAMETER :: NE = 20, NN = NE + 1
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), rho_a(NE), seed(6*NN), qa(6*NN), qb(6*NN), ca(NN), cb(NN), res
    REAL(wp) :: trib(NN), kn, share, dshare, share_p, share_m, dsh_p, dsh_m, r
    REAL(wp), PARAMETER :: RATIOS(3) = [1.0e-3_wp, 0.5_wp, 0.999_wp]
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, it, k
    TYPE(CD_HermiteCableDynType) :: dyn_a, dyn_b
    CHARACTER(512) :: em
    l0 = 100.2_wp/NE; EA = 5.0e8_wp; EI = 2.0e4_wp; w = 800.0_wp; rho_a = 120.0_wp; kn = 2.0e5_wp
    trib = 0.0_wp
    DO i = 1, NE
      trib(i) = trib(i) + 0.5_wp*l0(i); trib(i + 1) = trib(i + 1) + 0.5_wp*l0(i)
    END DO
    ! anchor on the 100 m floor, fairlead 60 m away and 80 m up: chord 100 m, length 100.2 m
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, -100.0_wp], [60.0_wp, 0.0_wp, -20.0_wp], l0, -100.0_wp, &
                                      seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'taut anchored seed: '//TRIM(em))
    fixed(1:6) = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    nfix = 6
    DO i = 1, NN
      fixed(nfix + 1:nfix + 2) = [6*i - 4, 6*i - 1]
      nfix = nfix + 2
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -100.0_wp, 0.0_wp, 4, 200, 1.0e-10_wp, &
                                      1.0_wp, qa, ca, res, it, es, em, contact_kn=kn*trib)
    CALL require(es == CD_HCSTAT_OK, 'taut anchored line on the floor: '//TRIM(em))
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1.0e4_wp, 0.0_wp, 4, 200, 1.0e-10_wp, &
                                      1.0_wp, qb, cb, res, it, es, em)
    CALL require(es == CD_HCSTAT_OK, 'taut anchored line without seabed: '//TRIM(em))
    CALL require(qa(6*2 - 3) + 100.0_wp > 1.0_wp, 'taut anchored line rises from its anchor')
    CALL require(ALL(qa == qb), 'taut anchored line: the floor carries none of the rising end element')
    CALL require(ALL(ca == cb), 'taut anchored line keeps the bending of the line without seabed')
    ! The held dynamics with the scalar floor at the anchor height equal those without a floor.
    CALL CD_HermiteCable_Dyn_Init(dyn_a, l0, EA, EI, rho_a, w, qa, fixed(1:nfix), -100.0_wp, kn, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'taut anchored dynamics with floor: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(dyn_b, l0, EA, EI, rho_a, w, qa, fixed(1:nfix), -1.0e4_wp, 0.0_wp, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'taut anchored dynamics without floor: '//TRIM(em))
    DO k = 1, 5
      CALL CD_HermiteCable_Dyn_Step(dyn_a, 0.05_wp, 30, 1.0e-9_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'taut anchored step with floor: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_Step(dyn_b, 0.05_wp, 30, 1.0e-9_wp, es, em)
      CALL require(es == CD_HCDYN_OK, 'taut anchored step without floor: '//TRIM(em))
    END DO
    CALL require(ALL(dyn_a%q == dyn_b%q) .AND. ALL(dyn_a%v == dyn_b%v), &
                 'taut anchored dynamics: the floor carries none of the rising end element')
    CALL CD_HermiteCable_Dyn_End(dyn_a)
    CALL CD_HermiteCable_Dyn_End(dyn_b)
    ! the element share: ratio r of the inner node's normal force to half the element weight
    CALL CD_Seabed_End_Element_Share(0.0_wp, 0.0_wp, 100.0_wp, share, dshare)
    CALL require(share == 0.0_wp .AND. dshare == 0.0_wp, 'end element share: clear of the floor')
    CALL CD_Seabed_End_Element_Share(200.0_wp, 1.0e4_wp, 100.0_wp, share, dshare)
    CALL require(share == 1.0_wp .AND. dshare == 0.0_wp, 'end element share: laid')
    DO k = 1, 3
      r = RATIOS(k)
      ! normal = 100 r with d(normal)/d(gap) = 1e4: central difference of the share in the gap
      CALL CD_Seabed_End_Element_Share(100.0_wp*r, 1.0e4_wp, 100.0_wp, share, dshare)
      CALL CD_Seabed_End_Element_Share(100.0_wp*r + 1.0e-4_wp, 1.0e4_wp, 100.0_wp, share_p, dsh_p)
      CALL CD_Seabed_End_Element_Share(100.0_wp*r - 1.0e-4_wp, 1.0e4_wp, 100.0_wp, share_m, dsh_m)
      CALL require(ABS((share_p - share_m)/2.0e-8_wp - dshare) <= 1.0e-5_wp*MAX(1.0_wp, ABS(dshare)), &
                   'end element share: derivative matches its difference quotient')
      CALL require(ABS(share - r*r*(3.0_wp - 2.0_wp*r)) <= 1.0e-15_wp, 'end element share: smoothstep')
    END DO
  END SUBROUTINE check_taut_line_anchored_on_floor

  SUBROUTINE check_laid_line_node_recovery()
    !! A straight line laid on the scalar penalty floor of CD_HermiteCable_Dyn_Init (no contact
    !! model), both ends held exactly on the floor: the floor carries the weight, so the
    !! recovered bend moment is only that of the line settling into the floor, at the held
    !! ends too. An end node on the
    !! floor has no contact force of its own; its laid end element is still grounded (the
    !! held-end floor support), so the reaction of the next node stays shared with it. Counted
    !! as suspended, the end element lost that share and the anchor and its neighbour showed a
    !! weight moment of order w l0^2/12 (521 N.m on this line, 31 %; the bending of the line
    !! settling 4 mm into the penalty floor next to its held ends is 4.6 N.m, 0.3 %).
    INTEGER, PARAMETER :: NE = 20, NN = NE + 1
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), rho_a(NE), seed(6*NN), q(6*NN), curv(NN), res, kn
    REAL(wp) :: trib(NN), tension(NN), bend(NN), scale
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, it
    TYPE(CD_HermiteCableDynType) :: dyn
    CHARACTER(512) :: em
    l0 = 5.0_wp; EA = 5.0e8_wp; EI = 2.0e4_wp; w = 800.0_wp; rho_a = 120.0_wp; kn = 2.0e5_wp
    trib = 0.0_wp
    DO i = 1, NE
      trib(i) = trib(i) + 0.5_wp*l0(i); trib(i + 1) = trib(i + 1) + 0.5_wp*l0(i)
    END DO
    ! both ends on the 100 m floor, 100 m apart: a 100 m line laid straight
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, -100.0_wp], [100.0_wp, 0.0_wp, -100.0_wp], l0, -100.0_wp, &
                                      seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'laid line seed: '//TRIM(em))
    fixed(1:6) = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    nfix = 6
    DO i = 1, NN
      fixed(nfix + 1:nfix + 2) = [6*i - 4, 6*i - 1]
      nfix = nfix + 2
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -100.0_wp, 0.0_wp, 4, 200, 1.0e-10_wp, &
                                      1.0_wp, q, curv, res, it, es, em, contact_kn=kn*trib)
    CALL require(es == CD_HCSTAT_OK, 'laid line on the floor: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL CD_HermiteCable_Dyn_Init(dyn, l0, EA, EI, rho_a, w, q, fixed(1:nfix), -100.0_wp, kn, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'laid line dynamics: '//TRIM(em))
    IF (es /= CD_HCDYN_OK) RETURN
    CALL CD_HermiteCable_Dyn_Node_Recovery(dyn, es, em, tension=tension, bend_moment=bend)
    CALL require(es == CD_HCDYN_OK, 'laid line node recovery: '//TRIM(em))
    scale = w(1)*l0(1)**2/12.0_wp
    WRITE (*, '(A,ES10.3,A,I0,A,ES10.3,A)') '  laid line: max |bend moment| ', MAXVAL(ABS(bend)), &
      ' N.m at node ', MAXLOC(ABS(bend)), &
      ' (w l0^2/12 = ', scale, ' N.m)'
    CALL require(MAXVAL(ABS(bend)) <= 0.02_wp*scale, &
                 'laid line: no weight moment at the held ends or along the line')
    CALL CD_HermiteCable_Dyn_End(dyn)
  END SUBROUTINE check_laid_line_node_recovery

  SUBROUTINE check_end_support_energy_gradient()
    !! The energy line search (energy_minimization) tests the potential against R.dq, so the
    !! residual must be the gradient of the potential it evaluates. With the end element's
    !! inner node half way through its touchdown (share S = 1/2), the floor-carried end
    !! moment depends on that node's height; the potential then takes the share held at the
    !! search's start (end_share_hold), and central differences of it along several
    !! directions reproduce R.d. With the share left to follow the trial states, the
    !! difference along the inner node's height misses the end-support term by about
    !! (w l0^2/12) (dS/dgap) m_z, here near 1 MN: no potential of R.
    INTEGER, PARAMETER :: NE = 20, NN = NE + 1, NDIR = 4
    REAL(wp), PARAMETER :: H = 1.0e-5_wp
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(6*NN), qa(6*NN), c(NN), res, r0(6*NN)
    REAL(wp) :: trib(NN), kn, floor_z, gap, normal, normal_gap, share, dshare, ep, em_, rd, fd, fd_free, d(6*NN)
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, it, k
    CHARACTER(512) :: em
    l0 = 100.2_wp/NE; EA = 5.0e8_wp; EI = 2.0e4_wp; w = 800.0_wp; kn = 2.0e5_wp
    trib = 0.0_wp
    DO i = 1, NE
      trib(i) = trib(i) + 0.5_wp*l0(i); trib(i + 1) = trib(i + 1) + 0.5_wp*l0(i)
    END DO
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, -100.0_wp], [60.0_wp, 0.0_wp, -20.0_wp], l0, -100.0_wp, &
                                      seed, es, em)
    fixed(1:6) = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    nfix = 6
    DO i = 1, NN
      fixed(nfix + 1:nfix + 2) = [6*i - 4, 6*i - 1]
      nfix = nfix + 2
    END DO
    ! the taut line without a seabed, then a floor placed just above its node 2 (the anchor
    ! is held below it): node 2 carries a quarter of its share, r = 1/2 of half the element
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1.0e4_wp, 0.0_wp, 4, 200, 1.0e-10_wp, &
                                      1.0_wp, qa, c, res, it, es, em)
    CALL require(es == CD_HCSTAT_OK, 'energy-gradient line: '//TRIM(em))
    floor_z = qa(9) + 0.5_wp*(0.5_wp*w(1)*l0(1))/(kn*trib(2))
    gap = floor_z - qa(9)
    CALL CD_Seabed_Normal_Law(gap, kn*trib(2), normal, normal_gap)
    CALL CD_Seabed_End_Element_Share(normal, normal_gap, 0.5_wp*w(1)*l0(1), share, dshare)
    CALL require(share > 0.4_wp .AND. share < 0.6_wp, 'energy-gradient: inner node inside the touchdown')
    CALL end_support_evaluation(l0, EA, EI, w, fixed(1:nfix), floor_z, kn*trib, qa, ep, [share, 0.0_wp], r0)
    DO k = 1, NDIR
      d = 0.0_wp
      SELECT CASE (k)
      CASE (1)
        d(9) = 1.0_wp                                   ! the inner node's height
      CASE (2)
        d(4) = 0.6_wp; d(6) = -0.8_wp                   ! the anchor's end tangent
      CASE (3)
        d(7) = 0.3_wp; d(9) = -0.5_wp; d(4) = 0.2_wp; d(15) = 0.4_wp
      CASE (4)
        DO i = 2, NE
          d(6*i - 5) = 0.1_wp*SIN(REAL(i, wp)); d(6*i - 3) = 0.1_wp*COS(REAL(i, wp))
          d(6*i - 2) = 0.01_wp*SIN(2.0_wp*i); d(6*i) = 0.01_wp*COS(2.0_wp*i)
        END DO
        d(4) = 0.01_wp; d(6) = 0.01_wp
      END SELECT
      rd = DOT_PRODUCT(r0, d)
      CALL end_support_evaluation(l0, EA, EI, w, fixed(1:nfix), floor_z, kn*trib, qa + H*d, ep, [share, 0.0_wp])
      CALL end_support_evaluation(l0, EA, EI, w, fixed(1:nfix), floor_z, kn*trib, qa - H*d, em_, [share, 0.0_wp])
      fd = (ep - em_)/(2.0_wp*H)
      CALL require(ABS(fd - rd) <= 1.0e-5_wp*MAX(ABS(rd), 1.0e3_wp), &
                   'energy-gradient: the held-share potential differentiates to R')
      IF (ABS(fd - rd) > 1.0e-5_wp*MAX(ABS(rd), 1.0e3_wp)) WRITE (*, '(A,I2,2ES16.8)') '  direction, FD, R.d', k, fd, rd
      IF (k == 1) THEN
        CALL end_support_evaluation(l0, EA, EI, w, fixed(1:nfix), floor_z, kn*trib, qa + H*d, ep)
        CALL end_support_evaluation(l0, EA, EI, w, fixed(1:nfix), floor_z, kn*trib, qa - H*d, em_)
        fd_free = (ep - em_)/(2.0_wp*H)
        CALL require(ABS(fd_free - rd) > 1.0e5_wp, 'energy-gradient: a share following the state is no potential')
      END IF
    END DO

  END SUBROUTINE check_end_support_energy_gradient

  SUBROUTINE end_support_evaluation(l0, EA, EI, w, fixed, floor_z, contact_kn, qx, energy, hold, residual)
    !! Potential (energy_minimization's) and residual of a Hermite line at qx: an evaluation
    !! only (a tolerance no state misses), with the end element shares held at hold if given.
    REAL(wp), INTENT(IN) :: l0(:), EA(:), EI(:), w(:), floor_z, contact_kn(:), qx(:)
    INTEGER, INTENT(IN) :: fixed(:)
    REAL(wp), INTENT(OUT) :: energy
    REAL(wp), INTENT(IN), OPTIONAL :: hold(2)
    REAL(wp), INTENT(OUT), OPTIONAL :: residual(:)
    REAL(wp) :: qo(SIZE(qx)), co(SIZE(l0) + 1), ro(SIZE(qx)), rs
    INTEGER :: ito, eso
    CHARACTER(512) :: emo
    IF (PRESENT(hold)) THEN
      CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qx, fixed, floor_z, 0.0_wp, 1, 1, HUGE(1.0_wp), &
                                        1.0_wp, qo, co, rs, ito, eso, emo, contact_kn=contact_kn, &
                                        residual_out=ro, energy_out=energy, end_share_hold=hold)
    ELSE
      CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qx, fixed, floor_z, 0.0_wp, 1, 1, HUGE(1.0_wp), &
                                        1.0_wp, qo, co, rs, ito, eso, emo, contact_kn=contact_kn, &
                                        residual_out=ro, energy_out=energy)
    END IF
    CALL require(eso == CD_HCSTAT_OK, 'energy-gradient evaluation: '//TRIM(emo))
    IF (PRESENT(residual)) residual = ro
  END SUBROUTINE end_support_evaluation

  SUBROUTINE check_scalar_contact_on_slope()
    !! The scalar-kn contact path on a structured (sloped) bathymetry includes the slope
    !! terms of the penetration in its tangent: from a perturbed equilibrium it converges
    !! as fast as, and to the same state as, the nodal path with the equivalent stiffness.
    !! The frictionless reaction is normal to the slope, so it couples x and z at every
    !! grounded node of this coarse mesh (elements longer than the bending length). The
    !! layout is chosen so that the problem is well posed on every platform: the line, held
    !! taut by a fairlead 200 m from the anchor, lies on the slope from its anchor
    !! (on the floor) to a touchdown between nodes, every clear node stands at least 0.3 m
    !! above the floor (no node in the contact blend), and the equilibrium is a stable one.
    !! A slacker layout (fairlead at 150 m) touched down at a node and admitted neighbouring
    !! equilibria within 3 cm that the polish reached or not depending on round-off (the
    !! OpenBLAS kernel, the platform). The perturbation (7.5 mm in x, 5 mm in z) is a quarter
    !! of the largest one from which both backtracking polishes return to the reference
    !! under the Prescott, Haswell and SkylakeX kernels and the default one; backtracking
    !! (the same option on both paths) keeps each Newton update a residual decrease.
    INTEGER, PARAMETER :: NE = 20, NN = NE + 1
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(6*NN), q1(6*NN), q2(6*NN), qs(6*NN), qr(6*NN), curv(NN), res
    REAL(wp) :: trib(NN), kn, xg(2), yg(2), dep(2, 2)
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, it1, it2
    LOGICAL :: stable
    TYPE(CD_BathymetryType) :: bed
    CHARACTER(512) :: em
    xg = [-50.0_wp, 300.0_wp]; yg = [-50.0_wp, 50.0_wp]
    dep(1, :) = 90.0_wp; dep(2, :) = 160.0_wp
    CALL CD_Init_Bathymetry(bed, xg, yg, dep, es, em)
    CALL require(es == 0, 'slope bathymetry: '//TRIM(em))
    l0 = 13.0_wp; EA = 5.0e8_wp; EI = 2.0e4_wp; w = 800.0_wp; kn = 2.0e5_wp
    trib = 0.0_wp
    DO i = 1, NE
      trib(i) = trib(i) + 6.5_wp; trib(i + 1) = trib(i + 1) + 6.5_wp
    END DO
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, -100.0_wp], [200.0_wp, 0.0_wp, -20.0_wp], l0, -100.0_wp, &
                                      seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'slope seed: '//TRIM(em))
    fixed(1:6) = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    nfix = 6
    DO i = 1, NN
      fixed(nfix + 1:nfix + 2) = [6*i - 4, 6*i - 1]
      nfix = nfix + 2
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -100.0_wp, 0.0_wp, 8, 200, 1.0e-9_wp, &
                                      0.7_wp, qr, curv, res, it1, es, em, contact_kn=kn*trib, bathymetry=bed, &
                                      stable=stable)
    CALL require(es == CD_HCSTAT_OK, 'slope nodal reference: '//TRIM(em))
    CALL require(stable, 'slope nodal reference is a stable equilibrium')
    qs = qr
    DO i = 2, NE
      qs(6*i - 5) = qs(6*i - 5) + 0.0075_wp*SIN(REAL(i, wp))
      qs(6*i - 3) = qs(6*i - 3) + 0.005_wp*COS(REAL(i, wp))
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qs, fixed(1:nfix), -100.0_wp, 0.0_wp, 1, 60, 1.0e-10_wp, &
                                      1.0_wp, q1, curv, res, it1, es, em, contact_kn=kn*trib, bathymetry=bed, &
                                      backtracking=.TRUE.)
    CALL require(es == CD_HCSTAT_OK, 'slope nodal polish: '//TRIM(em))
    CALL require(nan_max_abs(q1 - qr) < 1.0e-6_wp, 'slope nodal polish returns to the reference')
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qs, fixed(1:nfix), -100.0_wp, kn, 1, 60, 1.0e-10_wp, &
                                      1.0_wp, q2, curv, res, it2, es, em, bathymetry=bed, backtracking=.TRUE.)
    CALL require(es == CD_HCSTAT_OK, 'slope scalar polish converges: '//TRIM(em))
    CALL require(it2 <= it1 + 2, 'slope scalar polish converges as fast as the nodal path')
    CALL require(nan_max_abs(q2 - q1) < 1.0e-5_wp, 'slope scalar and nodal paths reach the same equilibrium')
  END SUBROUTINE check_scalar_contact_on_slope

  SUBROUTINE check_frictionless_slope_run()
    !! A heavy line resting on a planar sloped structured seabed: the frictionless reaction
    !! is normal to the slope, so the axial force of the grounded run changes along it by
    !! the weight component w sin(theta) per unit length, rising toward the anchor uphill
    !! (a vertical reaction would leave it constant, holding the run on the slope like
    !! friction), to 10 % (the contact acts at the nodes). Resolved mesh (elements shorter than
    !! the bending length); the axial force
    !! at a node is EA (|r'| - 1), r' its material tangent.
    INTEGER, PARAMETER :: NE = 75, NN = NE + 1
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(6*NN), q(6*NN), curv(NN), res
    REAL(wp) :: trib(NN), kn, xg(2), yg(2), dep(2, 2), sin_th, t_a, t_b, s_a, s_b, grad, x
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, it, first, last
    TYPE(CD_BathymetryType) :: bed
    CHARACTER(512) :: em
    xg = [-50.0_wp, 300.0_wp]; yg = [-50.0_wp, 50.0_wp]
    dep(1, :) = 90.0_wp; dep(2, :) = 160.0_wp
    CALL CD_Init_Bathymetry(bed, xg, yg, dep, es, em)
    CALL require(es == 0, 'slope run bathymetry: '//TRIM(em))
    l0 = 2.0_wp; EA = 5.0e8_wp; EI = 2.0e4_wp; w = 800.0_wp; kn = 2.0e5_wp
    trib = 0.0_wp
    DO i = 1, NE
      trib(i) = trib(i) + 1.0_wp; trib(i + 1) = trib(i + 1) + 1.0_wp
    END DO
    CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, -100.0_wp], [100.0_wp, 0.0_wp, -40.0_wp], l0, -100.0_wp, &
                                      seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'slope run seed: '//TRIM(em))
    fixed(1:6) = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    nfix = 6
    DO i = 1, NN
      fixed(nfix + 1:nfix + 2) = [6*i - 4, 6*i - 1]
      nfix = nfix + 2
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -100.0_wp, 0.0_wp, 8, 400, 1.0e-9_wp, &
                                      0.7_wp, q, curv, res, it, es, em, contact_kn=kn*trib, bathymetry=bed)
    CALL require(es == CD_HCSTAT_OK, 'slope run solve: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    ! grounded nodes: z on the bed -(90 + 0.2 (x + 50)) within the penalty sink
    first = 0
    last = 0
    DO i = 2, NN - 1
      x = q(6*i - 5)
      IF (ABS(q(6*i - 3) + 90.0_wp + 0.2_wp*(x + 50.0_wp)) < 0.02_wp) THEN
        IF (first == 0) first = i
        last = i
      END IF
    END DO
    CALL require(last - first >= 10, 'slope run: a grounded run of 10+ elements')
    IF (last - first < 10) RETURN
    ! away from the anchor and from the touchdown bend
    first = first + 2
    last = last - 3
    t_a = EA(first)*(NORM2(q(6*first - 2:6*first)) - 1.0_wp)
    t_b = EA(last)*(NORM2(q(6*last - 2:6*last)) - 1.0_wp)
    s_a = SUM(l0(1:first - 1))
    s_b = SUM(l0(1:last - 1))
    grad = (t_a - t_b)/(s_b - s_a)
    sin_th = 0.2_wp/SQRT(1.04_wp)
    CALL require(t_b > 0.0_wp .AND. ABS(grad - w(1)*sin_th) < 0.1_wp*w(1)*sin_th, &
                 'slope run: grounded axial force rises uphill by w sin(theta) per metre (frictionless normal '// &
                 'reaction)')
  END SUBROUTINE check_frictionless_slope_run

  SUBROUTINE check_long_sequence_hierarchy()
    !! The 3:2 hierarchy partition of a 60,000-element line (its index arithmetic exceeds
    !! the default integer range): 40,000 coarse cells of one or two fine elements.
    INTEGER, PARAMETER :: NE = 60000
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:)
    REAL(wp) :: lmax
    INTEGER :: es, nc
    CHARACTER(300) :: em
    ALLOCATE (l0(NE), EA(NE), EI(NE), w(NE))
    l0 = 0.5_wp; EA = 1.0e9_wp; EI = 1.0e4_wp; w = 500.0_wp
    CALL CD_HermiteCable_Sequence_Coarse_Max_Length(l0, EA, EI, w, 2, lmax, es, em, coarse_elements=nc)
    CALL require(es == CD_HCSTAT_OK .AND. nc == 40000, 'long hierarchy has the 3:2 coarse count')
    CALL require(ABS(lmax - 1.0_wp) < 1.0e-12_wp, 'long hierarchy cells are one or two fine elements')
  END SUBROUTINE check_long_sequence_hierarchy

  SUBROUTINE check_double_touchdown_seed()
    !! Both endpoints sit above the bed, while the slack length forces touchdown.
    !! This is the geometry that must remain on the migrated Hermite route.
    INTEGER, PARAMETER :: NE = 40, NN = NE + 1
    REAL(wp) :: l0(NE), seed(6*NN), zmin
    REAL(wp), PARAMETER :: a(3) = [0.0_wp, 0.0_wp, 10.0_wp]
    REAL(wp), PARAMETER :: b(3) = [100.0_wp, 0.0_wp, 10.0_wp]
    INTEGER :: es, i
    CHARACTER(300) :: em

    l0 = 110.0_wp/REAL(NE, wp)
    CALL CD_HermiteCable_Trivial_Seed(a, b, l0, 0.0_wp, seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'two-touchdown moderate-slack seed succeeds: '//TRIM(em))
    CALL require(ALL(IEEE_IS_FINITE(seed)), 'two-touchdown moderate-slack seed is finite')
    zmin = HUGE(1.0_wp)
    DO i = 1, NN
      zmin = MIN(zmin, seed(6*i - 3))
    END DO
    CALL require(zmin >= -1.0e-10_wp .AND. zmin < 0.25_wp, &
                 'two-touchdown moderate-slack seed reaches but never crosses the bed')

    ! Beyond the vertical-leg + straight-ground length, the seed stores surplus
    ! in an above-bed middle bow instead of rejecting the otherwise valid line.
    l0 = 140.0_wp/REAL(NE, wp)
    CALL CD_HermiteCable_Trivial_Seed(a, b, l0, 0.0_wp, seed, es, em)
    CALL require(es == CD_HCSTAT_OK, 'two-touchdown high-slack seed succeeds: '//TRIM(em))
    CALL require(ALL(IEEE_IS_FINITE(seed)), 'two-touchdown high-slack seed is finite')
    zmin = HUGE(1.0_wp)
    DO i = 1, NN
      zmin = MIN(zmin, seed(6*i - 3))
    END DO
    CALL require(zmin >= -1.0e-10_wp .AND. zmin < 0.25_wp, &
                 'two-touchdown high-slack seed reaches but never crosses the bed')

  END SUBROUTINE check_double_touchdown_seed

  SUBROUTINE check_catenary()
    !! Suspended heavy line vs the analytical catenary z(s) = sqrt(a^2 + s^2).
    INTEGER, PARAMETER :: NE = 32, NN = NE + 1, NDOF = 6*NN
    REAL(wp), PARAMETER :: a = 20.0_wp, wgt = 100.0_wp, Stot = 40.0_wp
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF), q(NDOF), curv(NN)
    REAL(wp) :: s, x, z, err2, ref2, znum, zref, res, history(40)
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, iters, history_count
    CHARACTER(300) :: em

    l0 = Stot/NE; EA = 1.0e8_wp; EI = 10.0_wp; w = wgt
    DO i = 1, NN
      s = -0.5_wp*Stot + Stot*REAL(i - 1, wp)/REAL(NE, wp)
      x = a*ASINH(s/a); z = SQRT(a*a + s*s)
      seed(6*i - 5) = x; seed(6*i - 4) = 0.0_wp; seed(6*i - 3) = z
      seed(6*i - 2) = a/z; seed(6*i - 1) = 0.0_wp; seed(6*i) = s/z   ! m = dr/ds (unit)
    END DO
    ! fix: endpoint positions (nodes 1, NN) + all y position/tangent DOFs (planar)
    nfix = 0
    CALL addfix(fixed, nfix, 1); CALL addfix(fixed, nfix, 2); CALL addfix(fixed, nfix, 3)
    CALL addfix(fixed, nfix, 6*NN - 5); CALL addfix(fixed, nfix, 6*NN - 4); CALL addfix(fixed, nfix, 6*NN - 3)
    DO i = 1, NN
      CALL addfix(fixed, nfix, 6*i - 4)   ! r_y
      CALL addfix(fixed, nfix, 6*i - 1)   ! m_y
    END DO

    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1000.0_wp, 0.0_wp, &
                                      1, 40, 1.0e-6_wp, 1.0_wp, q, curv, res, iters, es, em, &
                                      residual_history=history, history_count=history_count)
    CALL require(es == CD_HCSTAT_OK, 'catenary solve converged: '//TRIM(em))
    CALL require(history_count >= 1 .AND. history_count <= 40, 'catenary residual history count is bounded')
    CALL require(history(history_count) < 1.0e-6_wp, 'catenary residual history records convergence')
    CALL require(history(1) >= history(history_count), 'catenary residual history contracts overall')
    err2 = 0.0_wp; ref2 = 0.0_wp
    DO i = 1, NN
      s = -0.5_wp*Stot + Stot*REAL(i - 1, wp)/REAL(NE, wp)
      zref = SQRT(a*a + s*s); znum = q(6*i - 3)
      err2 = err2 + (znum - zref)**2; ref2 = ref2 + zref**2
    END DO
    WRITE (*, '(A,ES10.3,A,I0,A,ES10.3)') '  [catenary] normalised z L2 err=', SQRT(err2/ref2), &
      '  iters=', iters, '  res=', res
    CALL require(SQRT(err2/ref2) < 5.0e-3_wp, 'catenary z profile matches sqrt(a^2+s^2)')

    ! Re-solve from the already-converged q with max_iter=1: the residual at the
    ! seed is below tol, so the solver must report OK (regression for a convergence
    ! test taken before the final Newton update / max_iter=1).
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, q, fixed(1:nfix), -1000.0_wp, 0.0_wp, &
                                      1, 1, 1.0e-4_wp, 1.0_wp, seed, curv, res, iters, es, em)
    CALL require(es == CD_HCSTAT_OK, 'converged seed with max_iter=1 reports OK: '//TRIM(em))
  END SUBROUTINE check_catenary

  SUBROUTINE check_cantilever()
    !! Small-deflection cantilever under self-weight: tip deflection = w L^4 / (8 EI).
    INTEGER, PARAMETER :: NE = 20, NN = NE + 1, NDOF = 6*NN
    REAL(wp), PARAMETER :: Lc = 10.0_wp, EIc = 1.0e4_wp, wc = 1.0_wp
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF), q(NDOF), curv(NN)
    REAL(wp) :: dx, delta_ref, ztip, res
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, iters
    CHARACTER(300) :: em

    dx = Lc/NE
    l0 = dx; EA = 1.0e8_wp; EI = EIc; w = wc
    DO i = 1, NN
      seed(6*i - 5) = dx*REAL(i - 1, wp); seed(6*i - 4) = 0.0_wp; seed(6*i - 3) = 0.0_wp
      seed(6*i - 2) = 1.0_wp; seed(6*i - 1) = 0.0_wp; seed(6*i) = 0.0_wp
    END DO
    ! clamp node 1: fix r AND m (DOFs 1..6); planar: fix all r_y, m_y
    nfix = 0
    DO i = 1, 6; CALL addfix(fixed, nfix, i); END DO
    DO i = 1, NN
      CALL addfix(fixed, nfix, 6*i - 4)   ! r_y
      CALL addfix(fixed, nfix, 6*i - 1)   ! m_y
    END DO

    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1000.0_wp, 0.0_wp, &
                                      1, 60, 1.0e-6_wp, 1.0_wp, q, curv, res, iters, es, em)
    CALL require(es == CD_HCSTAT_OK, 'cantilever solve converged: '//TRIM(em))
    delta_ref = wc*Lc**4/(8.0_wp*EIc)
    ztip = q(6*NN - 3)
    WRITE (*, '(A,F9.6,A,F9.6,A,ES10.3)') '  [cantilever] z_tip=', ztip, '  -wL^4/8EI=', -delta_ref, &
      '  rel=', ABS(ztip + delta_ref)/delta_ref
    CALL require(ABS(ztip + delta_ref)/delta_ref < 2.0e-2_wp, 'cantilever tip deflection = w L^4/(8 EI)')
  END SUBROUTINE check_cantilever

  SUBROUTINE check_touchdown()
    !! A heavy line hung from an elevated end drapes onto a penalty seabed with FINITE
    !! touchdown curvature and the far end resting near the bed.
    INTEGER, PARAMETER :: NE = 40, NN = NE + 1, NDOF = 6*NN
    REAL(wp), PARAMETER :: Stot = 60.0_wp, wgt = 200.0_wp, zbed = 0.0_wp
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF), q(NDOF), curv(NN)
    REAL(wp) :: t, res, kmax, zmin
    INTEGER :: fixed(6 + 2*NN), nfix, i, es, iters
    CHARACTER(300) :: em

    l0 = Stot/NE; EA = 1.0e8_wp; EI = 5.0e3_wp; w = wgt
    ! seed: quarter-cosine drape from (0,0,30) down to (~40,0,0)
    DO i = 1, NN
      t = REAL(i - 1, wp)/REAL(NE, wp)
      seed(6*i - 5) = 40.0_wp*t; seed(6*i - 4) = 0.0_wp
      seed(6*i - 3) = 30.0_wp*COS(1.5707963_wp*t)
      seed(6*i - 2) = 0.8_wp; seed(6*i - 1) = 0.0_wp; seed(6*i) = -0.6_wp
    END DO
    nfix = 0
    ! fix elevated end position (node 1) only; planar y everywhere
    CALL addfix(fixed, nfix, 1); CALL addfix(fixed, nfix, 2); CALL addfix(fixed, nfix, 3)
    DO i = 1, NN
      CALL addfix(fixed, nfix, 6*i - 4)   ! r_y
      CALL addfix(fixed, nfix, 6*i - 1)   ! m_y
    END DO

    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), zbed, 1.0e6_wp, &
                                      6, 80, 1.0e-5_wp, 0.6_wp, q, curv, res, iters, es, em)
    CALL require(es == CD_HCSTAT_OK, 'touchdown solve converged: '//TRIM(em))
    kmax = MAXVAL(curv); zmin = q(6*(NN) - 3)
    WRITE (*, '(A,ES11.4,A,F9.4,A,I0)') '  [touchdown] max curvature=', kmax, '  z_end=', zmin, '  iters=', iters
    CALL require(kmax > 0.0_wp .AND. kmax < 1.0e3_wp, 'touchdown curvature finite and positive')
    CALL require(zmin > zbed - 0.5_wp .AND. zmin < 2.0_wp, 'far end rests near the seabed')
  END SUBROUTINE check_touchdown

  SUBROUTINE check_mesh_length_independence()
    !! The SAME physical cantilever solved at two very different element lengths must
    !! both converge at the same dimensionless tol and agree on the tip deflection.
    !! Regression for the tangent-residual scaling: an element-length-dependent norm
    !! would spuriously fail the coarse (large-l0) mesh or over-accept the fine one.
    REAL(wp) :: d_coarse, d_fine
    d_coarse = cantilever_tip(4)     ! l0 = 5.0
    d_fine = cantilever_tip(40)      ! l0 = 0.5
    WRITE (*, '(A,F10.6,A,F10.6)') '  [mesh-indep] tip(ne=4)=', d_coarse, '  tip(ne=40)=', d_fine
    CALL require(d_coarse < -1.0e-3_wp .AND. d_fine < -1.0e-3_wp, 'both meshes converged to a deflected state')
    CALL require(ABS(d_coarse - d_fine)/ABS(d_fine) < 5.0e-2_wp, 'tip deflection is mesh-length independent')
  END SUBROUTINE check_mesh_length_independence

  FUNCTION cantilever_tip(ne) RESULT(ztip)
    !! Solve an L=20 self-weight cantilever with `ne` elements; return the tip z (or 0 on
    !! non-convergence, which fails the caller's assertion).
    INTEGER, INTENT(IN) :: ne
    REAL(wp) :: ztip
    REAL(wp), PARAMETER :: Lc = 20.0_wp, EIc = 1.0e5_wp, wc = 1.0_wp
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:), q(:), curv(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp) :: dx, res
    INTEGER :: nn, ndof, nfix, i, es, iters
    CHARACTER(300) :: em
    nn = ne + 1; ndof = 6*nn; dx = Lc/ne
    ALLOCATE (l0(ne), EA(ne), EI(ne), w(ne), seed(ndof), q(ndof), curv(nn), fixed(6 + 2*nn))
    l0 = dx; EA = 1.0e9_wp; EI = EIc; w = wc
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*i - 5) = dx*REAL(i - 1, wp); seed(6*i - 2) = 1.0_wp
    END DO
    nfix = 0
    DO i = 1, 6; nfix = nfix + 1; fixed(nfix) = i; END DO
    DO i = 1, nn
      nfix = nfix + 1; fixed(nfix) = 6*i - 4   ! r_y
      nfix = nfix + 1; fixed(nfix) = 6*i - 1   ! m_y
    END DO
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), -1000.0_wp, 0.0_wp, &
                                      1, 80, 1.0e-6_wp, 1.0_wp, q, curv, res, iters, es, em)
    IF (es == CD_HCSTAT_OK) THEN; ztip = q(6*nn - 3); ELSE; ztip = 0.0_wp; END IF
  END FUNCTION cantilever_tip

  SUBROUTINE check_pinned_span_sag()
    !! A SINGLE element pinned at both end positions (both r fixed, planar m_y fixed),
    !! with only the tangent DOFs free. Gravity can load this span ONLY through the
    !! consistent tangent generalized load (+/- w l0^2/12); a lumped translation-only
    !! self-weight would leave every free DOF unloaded and accept the straight shape.
    !! Regression: the span must develop clearly nonzero curvature (it sags).
    REAL(wp) :: l0(1), EA(1), EI(1), wgt(1), seed(12), q(12), curv(2), res
    INTEGER :: fixed(8), es, iters
    CHARACTER(300) :: em
    l0 = 10.0_wp; EA = 1.0e8_wp; EI = 1.0e4_wp; wgt = 100.0_wp
    seed = 0.0_wp
    seed(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]; seed(4:6) = [1.0_wp, 0.0_wp, 0.0_wp]
    seed(7:9) = [10.0_wp, 0.0_wp, 0.0_wp]; seed(10:12) = [1.0_wp, 0.0_wp, 0.0_wp]
    fixed = [1, 2, 3, 5, 7, 8, 9, 11]        ! both r(3) + planar m_y; free: m_x, m_z at each node
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, wgt, seed, fixed, -1000.0_wp, 0.0_wp, &
                                      1, 100, 1.0e-6_wp, 0.8_wp, q, curv, res, iters, es, em)
    WRITE (*, '(A,I0,A,ES11.4,A,F9.4)') '  [pinned-sag] es=', es, '  max curv=', MAXVAL(curv), '  m_z(node1)=', q(6)
    CALL require(es == CD_HCSTAT_OK, 'pinned single-element span converged')
    ! Under a lumped translation-only load both free tangent DOFs stay at their straight
    ! seed (m_z = 0, curv = 0); the consistent tangent load rotates them and bows the span.
    CALL require(ABS(q(6)) > 1.0e-3_wp, 'free tangent DOF is loaded by gravity (not left at seed)')
    CALL require(MAXVAL(curv) > 1.0e-3_wp, 'gravity bends the span via the tangent DOFs (not left straight)')
  END SUBROUTINE check_pinned_span_sag

  SUBROUTINE check_input_rejection()
    USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN, IEEE_POSITIVE_INF
    REAL(wp) :: l0(2), EA(2), EI(2), w(2), seed(18), q(18), curv(3), res, nan, inf
    INTEGER :: fixed(1), es, iters
    CHARACTER(300) :: em
    nan = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN); inf = IEEE_VALUE(1.0_wp, IEEE_POSITIVE_INF)
    l0 = 1.0_wp; EA = 1.0e6_wp; EI = 1.0_wp; w = 1.0_wp; seed = 0.0_wp; fixed = 1
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, -1.0_wp, &
                                      1, 10, 1.0e-6_wp, 1.0_wp, q, curv, res, iters, es, em)
    CALL require(es /= CD_HCSTAT_OK, 'reject negative kn')
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                      1, 10, 1.0e-6_wp, 2.0_wp, q, curv, res, iters, es, em)
    CALL require(es /= CD_HCSTAT_OK, 'reject damping > 1')
    l0(1) = -1.0_wp
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                      1, 10, 1.0e-6_wp, 1.0_wp, q, curv, res, iters, es, em)
    CALL require(es /= CD_HCSTAT_OK, 'reject nonpositive element length')
    l0 = 1.0_wp
    ! Non-finite controls must be rejected: NaN slips past ordered comparisons (all false),
    ! so an unchecked NaN tol could return OK with a large residual.
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                      1, 10, nan, 1.0_wp, q, curv, res, iters, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCSTAT_OK, 'reject NaN tol')
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                      1, 10, inf, 1.0_wp, q, curv, res, iters, es, em)
    CALL require(es /= CD_HCSTAT_OK, 'reject infinite tol')
    ! deliberately non-finite or overflowing input: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                      1, 10, 1.0e-6_wp, nan, q, curv, res, iters, es, em)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es /= CD_HCSTAT_OK, 'reject NaN damping')
    ! The n_buoy_steps argument contract (>= 1) holds regardless of the weight signature:
    ! a net-HEAVY line ignores the value but must still reject a bad one, so input
    ! rejection never depends on the cable weights.
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                      1, 10, 1.0e-6_wp, 1.0_wp, q, curv, res, iters, es, em, &
                                      n_buoy_steps=0)
    CALL require(es /= CD_HCSTAT_OK, 'reject n_buoy_steps < 1 on a net-heavy line')
    w = -1.0_wp
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                      1, 10, 1.0e-6_wp, 1.0_wp, q, curv, res, iters, es, em, &
                                      n_buoy_steps=0)
    CALL require(es /= CD_HCSTAT_OK, 'reject n_buoy_steps < 1 on a net-buoyant line')
    w = 1.0_wp
  END SUBROUTINE check_input_rejection

  SUBROUTINE addfix(list, n, dof)
    INTEGER, INTENT(INOUT) :: list(:), n
    INTEGER, INTENT(IN) :: dof
    n = n + 1
    list(n) = dof
  END SUBROUTINE addfix

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_cable_static
