! File: tests/test_core_solver_regressions.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_core_solver_regressions
  !! Contracts of the solver core that sit on rarely exercised paths:
  !!   1. A failed replacement of the Hermite seabed contact restores the complete friction
  !!      configuration of the previous one (stiffness, anchors, anisotropy).
  !!   2. Friction setters keep the snapshot, the cached committed force and the
  !!      anisotropy flag consistent with the installed law.
  !!   3. The Hermite end force includes a discrete attachment on the end node, and
  !!      internal waves are refused once attachments are installed.
  !!   4. A restored snapshot also restores the step-rotation diagnostic.
  !!   5. The EI = 0 element tension includes the axial Kelvin-Voigt damping share.
  !!   6. EI = 0 seabed damping on a sloped floor acts along the floor normal, at the
  !!      normal penetration and normal velocity.
  !!   7. The pseudo-arclength helpers trace a load path around a limit point with a
  !!      strongly weighted position metric.
  !!   8. The Hermite static tangent of the scalar-stiffness seabed with friction on a sloped
  !!      bathymetry matches finite differences of the residual.
  !!   9. A moved added-mass waterline refreshes the cached EI = 0 acceleration derivative.
  !!  10. Restart reloads of the viscoelastic state also set its rollback and recovery twins.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Init_Bathymetry, CD_BATHY_OK
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_End_Model, CD_Get_Model_Tension, &
                            CD_Get_Model_EndForces, CD_Calc_Model_CoupledAccelDerivative, &
                            CD_Update_Model_Hydro_Fields, CD_Set_Model_VE_Dl1, CD_MODEL_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Contact, CD_HermiteCable_Dyn_Set_Friction_Axial, &
                                          CD_HermiteCable_Dyn_Set_Friction_Anchors, CD_HermiteCable_Dyn_Snapshot, &
                                          CD_HermiteCable_Dyn_Restore, CD_HermiteCable_Dyn_Set_Attachments, &
                                          CD_HermiteCable_Dyn_Set_Waves, CD_HermiteCable_Dyn_End_Force, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Max_Step_Rotation, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK, CD_HCDYN_BADINPUT
  USE CableDyn_HermiteCableStatic, ONLY: CD_Arclength_Dot, CD_Arclength_Unit_Tangent, &
                                         CD_Arclength_Bordered_Update, CD_HermiteCable_Static_Solve, &
                                         CD_HermiteStaticFrictionType, CD_HCSTAT_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NE = 10
  REAL(wp), PARAMETER :: LB = 10.0_wp
  INTEGER :: nfail

  nfail = 0
  CALL case_contact_rollback()
  CALL case_friction_setters()
  CALL case_end_force_attachment()
  CALL case_rotation_diagnostic_restore()
  CALL case_ei0_damping_tension()
  CALL case_ei0_sloped_seabed_damping()
  CALL case_arclength_limit_point()
  CALL case_slope_friction_tangent()
  CALL case_added_mass_waterline_cache()
  CALL case_ve_reload_twins()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: core solver regressions'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE beam(z0, amp, l0, EAv, EIv, rhoAv, wv, seed, fixed)
    !! Straight (or mode-1 bowed) planar beam along x at height z0, ends pinned.
    REAL(wp), INTENT(IN) :: z0, amp
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed(:)
    REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
    INTEGER :: i, k, nn
    REAL(wp) :: h, x
    nn = NE + 1
    h = LB/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), rhoAv(NE), wv(NE), seed(6*nn), fixed(2*nn + 4))
    l0 = h; EAv = 1.0e5_wp; EIv = 100.0_wp; rhoAv = 1.0_wp; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      x = REAL(i - 1, wp)*h
      seed(6*i - 5) = x
      seed(6*i - 3) = z0 + amp*SIN(PI*x/LB)
      seed(6*i - 2) = 1.0_wp
      seed(6*i) = amp*(PI/LB)*COS(PI*x/LB)
    END DO
    k = 0
    DO i = 1, nn
      fixed(k + 1) = 6*i - 4
      fixed(k + 2) = 6*i - 1
      k = k + 2
    END DO
    fixed(k + 1:k + 4) = [1, 3, 6*nn - 5, 6*nn - 3]
  END SUBROUTINE beam

  SUBROUTINE case_contact_rollback()
    !! A second Set_Contact whose acceleration refresh fails (an overflowing contact force)
    !! must leave the previous frictional configuration exactly in place.
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:), kn(:), cn(:)
    REAL(wp), ALLOCATABLE :: a0(:), anchor0(:, :), frk0(:)
    INTEGER, ALLOCATABLE :: fx(:)
    INTEGER :: es
    CHARACTER(300) :: em
    CALL beam(-10.0_wp, 0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'rollback: init: '//TRIM(em))
    ALLOCATE (kn(NE + 1), cn(NE + 1))
    kn = 1.0e4_wp; cn = 10.0_wp
    CALL CD_HermiteCable_Dyn_Set_Contact(m, kn, cn, 0.2_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'rollback: first contact: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Friction_Axial(m, 0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'rollback: anisotropic friction: '//TRIM(em))
    a0 = m%a
    anchor0 = m%fr_anchor
    frk0 = m%fr_k
    kn = 0.9_wp*HUGE(1.0_wp)
    CALL CD_HermiteCable_Dyn_Set_Contact(m, kn, cn, 0.3_wp, es, em)
    CALL require(es == CD_HCDYN_BADINPUT, 'rollback: overflowing contact replacement is rejected')
    CALL require(ALLOCATED(m%fr_k), 'rollback: friction stiffness stays allocated')
    IF (ALLOCATED(m%fr_k)) THEN
      CALL require(SIZE(m%fr_k) == NE + 1, 'rollback: friction stiffness keeps its size')
      IF (SIZE(m%fr_k) == NE + 1) CALL require(nan_max_abs(m%fr_k - frk0) <= 0.0_wp, &
                                               'rollback: friction stiffness restored')
    END IF
    CALL require(nan_max_abs(m%contact_kn - 1.0e4_wp) <= 0.0_wp, 'rollback: contact stiffness restored')
    CALL require(nan_max_abs(m%fr_anchor - anchor0) <= 0.0_wp, 'rollback: friction anchors restored')
    CALL require(nan_max_abs(m%a - a0) <= 0.0_wp, 'rollback: acceleration restored')
    CALL require(ABS(m%contact_mu - 0.2_wp) <= 0.0_wp, 'rollback: friction coefficient restored')
    CALL require(m%contact_fr_aniso .AND. ABS(m%contact_mu_axial - 0.5_wp) <= 0.0_wp, 'rollback: anisotropy restored')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE case_contact_rollback

  SUBROUTINE case_friction_setters()
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:), kn(:), cn(:), anchors(:, :)
    INTEGER, ALLOCATABLE :: fx(:)
    INTEGER :: es, i
    CHARACTER(300) :: em
    CALL beam(-0.01_wp, 0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, 0.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'setters: init: '//TRIM(em))
    ALLOCATE (kn(NE + 1), cn(NE + 1))
    kn = 1.0e4_wp; cn = 10.0_wp
    CALL CD_HermiteCable_Dyn_Set_Contact(m, kn, cn, 0.2_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'setters: contact: '//TRIM(em))
    ! A friction-law change invalidates the cached committed force.
    m%fc_valid = .TRUE.
    m%tr_valid = .TRUE.
    CALL CD_HermiteCable_Dyn_Set_Friction_Axial(m, 0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'setters: axial friction: '//TRIM(em))
    CALL require(.NOT. m%fc_valid .AND. .NOT. m%tr_valid, 'setters: axial friction clears the force cache')
    CALL require(m%contact_fr_aniso, 'setters: axial friction is anisotropic')
    ! A new contact law resets the friction to isotropic against its own coefficient.
    CALL CD_HermiteCable_Dyn_Set_Contact(m, kn, cn, 0.3_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'setters: contact replacement: '//TRIM(em))
    CALL require(.NOT. m%contact_fr_aniso, 'setters: contact replacement resets the anisotropy')
    CALL require(ABS(m%contact_mu_axial - 0.3_wp) <= 0.0_wp, &
                 'setters: contact replacement resets the axial coefficient')
    ! Anchors installed after a snapshot survive a Restore.
    CALL CD_HermiteCable_Dyn_Snapshot(m, es, em)
    CALL require(es == CD_HCDYN_OK, 'setters: snapshot: '//TRIM(em))
    ALLOCATE (anchors(2, NE + 1))
    DO i = 1, NE + 1
      anchors(:, i) = m%q(6*i - 5:6*i - 4) + [0.001_wp, 0.0_wp]
    END DO
    CALL CD_HermiteCable_Dyn_Set_Friction_Anchors(m, anchors, es, em)
    CALL require(es == CD_HCDYN_OK, 'setters: anchors: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Restore(m, es, em)
    CALL require(es == CD_HCDYN_OK, 'setters: restore: '//TRIM(em))
    CALL require(nan_max_abs(m%fr_anchor - anchors) <= 0.0_wp, 'setters: restore keeps the installed anchors')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE case_friction_setters

  SUBROUTINE case_end_force_attachment()
    TYPE(CD_HermiteCableDynType) :: ma, mb
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    REAL(wp), PARAMETER :: MASS = 100.0_wp, VOL = 0.01_wp, RHO = 1025.0_wp, G = 9.81_wp
    REAL(wp) :: fa(3), fb(3), w_net
    INTEGER :: es
    CHARACTER(300) :: em
    CALL beam(-5.0_wp, 0.0_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(ma, l0, EAv, EIv, rhoAv, wv, seed, fx, -100.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'attachment: init A: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Init(mb, l0, EAv, EIv, rhoAv, wv, seed, fx, -100.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'attachment: init B: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Set_Attachments(mb, [NE + 1], [MASS], [VOL], [0.0_wp], [0.0_wp], [1.0_wp], &
                                             RHO, G, es, em)
    CALL require(es == CD_HCDYN_OK, 'attachment: install: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_End_Force(ma, NE + 1, fa, es, em)
    CALL require(es == CD_HCDYN_OK, 'attachment: end force A: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_End_Force(mb, NE + 1, fb, es, em)
    CALL require(es == CD_HCDYN_OK, 'attachment: end force B: '//TRIM(em))
    w_net = (MASS - RHO*VOL)*G
    CALL require(ABS((fb(3) - fa(3)) + w_net) <= 1.0e-9_wp*w_net, &
                 'attachment: the end force carries the net weight of a clump on the end node')
    CALL require(ALL(ABS(fb(1:2) - fa(1:2)) <= 1.0e-12_wp), 'attachment: still water adds no horizontal load')
    CALL CD_HermiteCable_Dyn_End_Force(mb, 1, fb, es, em)
    CALL CD_HermiteCable_Dyn_End_Force(ma, 1, fa, es, em)
    CALL require(ALL(ABS(fb - fa) <= 1.0e-12_wp), 'attachment: the other end is unaffected')
    CALL CD_HermiteCable_Dyn_Set_Waves(mb, 1.0_wp, 8.0_wp, 0.0_wp, 100.0_wp, G, es, em)
    CALL require(es == CD_HCDYN_BADINPUT .AND. INDEX(em, 'attachments') > 0, &
                 'attachment: internal waves are refused on a model with attachments')
    CALL CD_HermiteCable_Dyn_End(ma)
    CALL CD_HermiteCable_Dyn_End(mb)
  END SUBROUTINE case_end_force_attachment

  SUBROUTINE case_rotation_diagnostic_restore()
    TYPE(CD_HermiteCableDynType) :: m
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), rhoAv(:), wv(:), seed(:)
    INTEGER, ALLOCATABLE :: fx(:)
    INTEGER :: es, s
    CHARACTER(300) :: em
    CALL beam(0.0_wp, 0.05_wp, l0, EAv, EIv, rhoAv, wv, seed, fx)
    CALL CD_HermiteCable_Dyn_Init(m, l0, EAv, EIv, rhoAv, wv, seed, fx, -100.0_wp, 0.0_wp, 0.9_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'rotation: init: '//TRIM(em))
    CALL CD_HermiteCable_Dyn_Snapshot(m, es, em)
    CALL require(es == CD_HCDYN_OK, 'rotation: snapshot: '//TRIM(em))
    DO s = 1, 10
      CALL CD_HermiteCable_Dyn_Step(m, 0.05_wp, 30, 1.0e-8_wp, es, em)
      IF (es /= CD_HCDYN_OK) EXIT
    END DO
    CALL require(es == CD_HCDYN_OK, 'rotation: steps: '//TRIM(em))
    CALL require(CD_HermiteCable_Dyn_Max_Step_Rotation(m) > 0.0_wp, 'rotation: the vibrating beam turns')
    CALL CD_HermiteCable_Dyn_Restore(m, es, em)
    CALL require(es == CD_HCDYN_OK, 'rotation: restore: '//TRIM(em))
    CALL require(ABS(CD_HermiteCable_Dyn_Max_Step_Rotation(m)) <= 0.0_wp, &
                 'rotation: restore rewinds the step-rotation diagnostic')
    CALL CD_HermiteCable_Dyn_End(m)
  END SUBROUTINE case_rotation_diagnostic_restore

  SUBROUTINE case_ei0_damping_tension()
    !! Two elements along x, strain 1 %, middle node moving +x at 1 m/s: the reported
    !! element tensions are EA*strain +/- BA*(strain rate).
    TYPE(CD_ModelType) :: m
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp), PARAMETER :: EA = 1.0e6_wp, BA = 1.0e3_wp, L0E = 10.0_wp
    REAL(wp) :: q0(9), v0(9), f_ext(9), ten(2), expect(2)
    INTEGER :: conn(2, 2), es
    CHARACTER(300) :: em
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    q0 = [0.0_wp, 0.0_wp, 0.0_wp, 1.01_wp*L0E, 0.0_wp, 0.0_wp, 2.02_wp*L0E, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    v0(4) = 1.0_wp
    f_ext = 0.0_wp
    CALL CD_Init_Model(m, q0, v0, conn, [L0E, L0E], [EA, EA], [1.0_wp, 1.0_wp], .TRUE., f_ext, &
                       [1, 2, 3, 7, 8, 9], cfg, es, em, ba=[BA, BA])
    CALL require(es == CD_MODEL_OK, 'damping tension: init: '//TRIM(em))
    CALL CD_Get_Model_Tension(m, ten, es, em)
    CALL require(es == CD_MODEL_OK, 'damping tension: query: '//TRIM(em))
    expect = [EA*0.01_wp + BA/L0E, EA*0.01_wp - BA/L0E]
    CALL require(ALL(ABS(ten - expect) <= 1.0e-9_wp*EA*0.01_wp), &
                 'damping tension: the reported tension includes the axial damping share')
    CALL CD_End_Model(m, es, em)
  END SUBROUTINE case_ei0_damping_tension

  SUBROUTINE case_ei0_sloped_seabed_damping()
    !! First node penetrating a floor of slope 0.4 along x and moving straight down: the
    !! seabed damping is -c_n*(v.n) along n, at the normal penetration.
    TYPE(CD_ModelType) :: ma, mb
    TYPE(GenAlphaConfig) :: cfg
    TYPE(CD_BathymetryType) :: bathy
    REAL(wp), PARAMETER :: SLOPE = 0.4_wp, CN = 100.0_wp, KN = 1.0e4_wp
    REAL(wp) :: q0(9), v0(9), f_ext(9), depth(2, 2), fa1(3), fa3(3), fb1(3), fb3(3), nvec(3), vn, df(3)
    INTEGER :: conn(2, 2), es
    CHARACTER(300) :: em
    ! floor z = -50 + SLOPE*x
    depth(1, :) = 50.0_wp + SLOPE*100.0_wp
    depth(2, :) = 50.0_wp - SLOPE*100.0_wp
    CALL CD_Init_Bathymetry(bathy, [-100.0_wp, 100.0_wp], [-100.0_wp, 100.0_wp], depth, es, em)
    CALL require(es == CD_BATHY_OK, 'sloped damping: bathymetry: '//TRIM(em))
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    q0 = [0.0_wp, 0.0_wp, -50.2_wp, 10.0_wp, 0.0_wp, -44.0_wp, 20.0_wp, 0.0_wp, -35.0_wp]
    v0 = 0.0_wp
    v0(3) = -1.0_wp
    f_ext = 0.0_wp
    CALL CD_Init_Model(ma, q0, v0, conn, [12.0_wp, 12.0_wp], [1.0e6_wp, 1.0e6_wp], [1.0_wp, 1.0_wp], .TRUE., &
                       f_ext, [7, 8, 9], cfg, es, em, seabed_kn=[KN, KN, KN], &
                       seabed_cn=[CN, CN, CN], bathymetry=bathy)
    CALL require(es == CD_MODEL_OK, 'sloped damping: init with damping: '//TRIM(em))
    CALL CD_Init_Model(mb, q0, v0, conn, [12.0_wp, 12.0_wp], [1.0e6_wp, 1.0e6_wp], [1.0_wp, 1.0_wp], .TRUE., &
                       f_ext, [7, 8, 9], cfg, es, em, seabed_kn=[KN, KN, KN], &
                       bathymetry=bathy)
    CALL require(es == CD_MODEL_OK, 'sloped damping: init without damping: '//TRIM(em))
    CALL CD_Get_Model_EndForces(ma, fa1, fa3, es, em)
    CALL require(es == CD_MODEL_OK, 'sloped damping: end forces A: '//TRIM(em))
    CALL CD_Get_Model_EndForces(mb, fb1, fb3, es, em)
    CALL require(es == CD_MODEL_OK, 'sloped damping: end forces B: '//TRIM(em))
    nvec = [-SLOPE, 0.0_wp, 1.0_wp]/SQRT(1.0_wp + SLOPE*SLOPE)
    vn = DOT_PRODUCT(v0(1:3), nvec)
    df = fa1 - fb1
    CALL require(ALL(ABS(df - (-CN*vn)*nvec) <= 1.0e-9_wp*CN), &
                 'sloped damping: the damping force is -c_n (v.n) n')
    CALL CD_End_Model(ma, es, em)
    CALL CD_End_Model(mb, es, em)
  END SUBROUTINE case_ei0_sloped_seabed_damping

  SUBROUTINE case_arclength_limit_point()
    !! F(q, lambda) = g(q) - lambda with g(x) = 0.2 (x^3 - 3x + 2), x = q/L: from x = -2
    !! the path rises to a limit point lambda = 0.8 at x = -1, turns back to lambda = 0 at
    !! x = 1 and crosses lambda = 1 at x^3 - 3x - 3 = 0. L = 1000 weights the positions
    !! by wq = 1/L, as a line length does in the static drag continuation.
    REAL(wp), PARAMETER :: L = 1000.0_wp
    REAL(wp) :: wq, q(1), tq(1), tq_new(1), qp(1), qc(1), z1(1), z2(1)
    REAL(wp) :: lam, tl, tl_new, lam_p, lamc, ds, g, k, x_cross
    INTEGER :: step, corr, es, n_corr
    LOGICAL :: conv, turned, crossed
    wq = 1.0_wp/L
    q = -2.0_wp*L
    lam = 0.0_wp
    tq = 1.0_wp/dgdq(q(1))
    CALL CD_Arclength_Unit_Tangent(wq, tq, tl)
    ds = 0.05_wp
    turned = .FALSE.
    crossed = .FALSE.
    DO step = 1, 400
      qp = q + ds*tq
      lam_p = lam + ds*tl
      qc = qp
      lamc = lam_p
      conv = .FALSE.
      n_corr = 0
      DO corr = 1, 15
        n_corr = corr
        g = CD_Arclength_Dot(wq, tq, tl, qc - qp, lamc - lam_p)
        IF (ABS(gfun(qc(1)) - lamc) < 1.0e-13_wp .AND. ABS(g) < 1.0e-13_wp) THEN
          conv = .TRUE.
          EXIT
        END IF
        k = dgdq(qc(1))
        z1 = -(gfun(qc(1)) - lamc)/k
        z2 = 1.0_wp/k
        CALL CD_Arclength_Bordered_Update(wq, tq, tl, g, z1, z2, qc, lamc, es)
        IF (es /= 0) EXIT
      END DO
      IF (.NOT. conv) THEN
        ds = 0.5_wp*ds
        IF (ds < 1.0e-6_wp) EXIT
        CYCLE
      END IF
      IF (lamc >= 1.0_wp) THEN
        crossed = .TRUE.
        q = qc
        lam = lamc
        EXIT
      END IF
      IF (lamc < lam) turned = .TRUE.
      tq_new = 1.0_wp/dgdq(qc(1))
      CALL CD_Arclength_Unit_Tangent(wq, tq_new, tl_new)
      IF (CD_Arclength_Dot(wq, tq_new, tl_new, tq, tl) < 0.0_wp) THEN
        tq_new = -tq_new; tl_new = -tl_new
      END IF
      q = qc
      lam = lamc
      tq = tq_new
      tl = tl_new
      IF (n_corr <= 4) ds = MIN(0.2_wp, 1.5_wp*ds)
    END DO
    x_cross = 2.103803402735536_wp   ! the real root of x^3 - 3x - 3
    CALL require(crossed, 'arclength: the path reaches the full load')
    CALL require(turned, 'arclength: the path passes the limit point (the load fraction decreases)')
    CALL require(step < 200, 'arclength: the limit point is passed in a bounded number of steps')
    CALL require(q(1)/L > 1.0_wp .AND. q(1)/L < x_cross + 0.5_wp, 'arclength: the crossing lies on the far branch')
  END SUBROUTINE case_arclength_limit_point

  SUBROUTINE case_slope_friction_tangent()
    !! One Hermite element pressed 0.1 m into a floor of slope 0.4, the scalar seabed
    !! stiffness, and seabed friction sliding against a reference 3 m aside: the x/y rows of
    !! the tangent (which carry the capacity's dependence on the normal force) against
    !! central differences of the residual in the two z DOFs.
    INTEGER, PARAMETER :: KL = 11, KU = 11, LDAB = 2*KL + KU + 1
    TYPE(CD_BathymetryType) :: bathy
    TYPE(CD_HermiteStaticFrictionType) :: fr
    REAL(wp) :: depth(2, 2), seed(12), qp(12), qm(12), rp(12), rm(12), r0(12)
    REAL(wp) :: kb(LDAB, 12), kdum(LDAB, 12), l0(1), fd, an, worst, scale
    INTEGER :: es, col, row, jc
    CHARACTER(300) :: em
    depth(1, :) = 50.0_wp + 0.4_wp*100.0_wp
    depth(2, :) = 50.0_wp - 0.4_wp*100.0_wp
    CALL CD_Init_Bathymetry(bathy, [-100.0_wp, 100.0_wp], [-100.0_wp, 100.0_wp], depth, es, em)
    CALL require(es == CD_BATHY_OK, 'slope friction: bathymetry: '//TRIM(em))
    l0 = SQRT(100.0_wp + 16.0_wp)
    seed = 0.0_wp
    seed(1:3) = [0.0_wp, 0.0_wp, -50.1_wp]
    seed(4:6) = [10.0_wp, 0.0_wp, 4.0_wp]/l0(1)
    seed(7:9) = [10.0_wp, 0.0_wp, -46.1_wp]
    seed(10:12) = seed(4:6)
    fr%mu = 0.5_wp
    ALLOCATE (fr%ref_s(2), fr%ref_xy(2, 2))
    fr%ref_s = [0.0_wp, l0(1)]
    fr%ref_xy = RESHAPE([0.0_wp, 3.0_wp, 10.0_wp, 3.0_wp], [2, 2])
    CALL slope_eval(seed, r0, kb, l0, bathy, fr)
    worst = 0.0_wp
    scale = nan_max_abs(r0)
    DO jc = 1, 2
      col = 6*(jc - 1) + 3
      qp = seed
      qm = seed
      qp(col) = qp(col) + 1.0e-6_wp
      qm(col) = qm(col) - 1.0e-6_wp
      CALL slope_eval(qp, rp, kdum, l0, bathy, fr)
      CALL slope_eval(qm, rm, kdum, l0, bathy, fr)
      DO row = 1, 12
        IF (MOD(row - 1, 6) > 1) CYCLE          ! the x and y rows of both nodes
        IF (ABS(row - col) > KL) CYCLE
        fd = (rp(row) - rm(row))/2.0e-6_wp
        an = kb(KL + KU + 1 + row - col, col)
        worst = MAX(worst, ABS(fd - an)/MAX(ABS(fd), 1.0e-6_wp*scale/1.0e-1_wp))
      END DO
    END DO
    CALL require(worst < 1.0e-4_wp, 'slope friction: the tangent matches central differences')
  END SUBROUTINE case_slope_friction_tangent

  SUBROUTINE slope_eval(q, r, k, l0, bathy, fr)
    !! Residual and banded tangent of the static solve at state q (no Newton update).
    REAL(wp), INTENT(IN) :: q(12), l0(1)
    REAL(wp), INTENT(OUT) :: r(12), k(:, :)
    TYPE(CD_BathymetryType), INTENT(IN) :: bathy
    TYPE(CD_HermiteStaticFrictionType), INTENT(IN) :: fr
    REAL(wp) :: q_out(12), curv(2), res
    INTEGER :: it, es
    CHARACTER(300) :: em
    CALL CD_HermiteCable_Static_Solve(l0, [1.0e7_wp], [1.0e3_wp], [100.0_wp], q, [2], -60.0_wp, 1.0e5_wp, &
                                      1, 1, HUGE(1.0_wp), 1.0_wp, q_out, curv, res, it, es, em, &
                                      bathymetry=bathy, friction=fr, residual_out=r, tangent_out=k)
    CALL require(es == CD_HCSTAT_OK, 'slope friction: evaluation: '//TRIM(em))
  END SUBROUTINE slope_eval

  SUBROUTINE case_added_mass_waterline_cache()
    !! Two elements, the second crossing the added-mass waterline: after the waterline moves,
    !! the acceleration derivative equals that of a model built with the new waterline.
    TYPE(CD_ModelType) :: m, fresh
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: q0(9), v0(9), f_ext(9), d1(6, 6), d2(6, 6), d3(6, 6)
    INTEGER :: conn(2, 2), es
    CHARACTER(300) :: em
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    q0 = [0.0_wp, 0.0_wp, -10.0_wp, 1.0_wp, 0.0_wp, -5.0_wp, 2.0_wp, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    f_ext = 0.0_wp
    CALL CD_Init_Model(m, q0, v0, conn, [5.0_wp, 5.0_wp], [1.0e6_wp, 1.0e6_wp], [50.0_wp, 50.0_wp], .TRUE., &
                       f_ext, [1, 2, 3, 7, 8, 9], cfg, es, em, added_mass_waterline_z=[-2.0_wp, -2.0_wp, -2.0_wp], &
                       added_mass_rho=1025.0_wp, added_mass_diameter=0.3_wp, added_mass_can=1.0_wp, &
                       added_mass_cat=0.0_wp)
    CALL require(es == CD_MODEL_OK, 'added-mass cache: init: '//TRIM(em))
    CALL CD_Calc_Model_CoupledAccelDerivative(m, d1, es, em)
    CALL require(es == CD_MODEL_OK, 'added-mass cache: first derivative: '//TRIM(em))
    CALL CD_Update_Model_Hydro_Fields(m, es, em, added_mass_waterline_z=[-3.0_wp, -3.0_wp, -3.0_wp])
    CALL require(es == CD_MODEL_OK, 'added-mass cache: waterline update: '//TRIM(em))
    CALL CD_Calc_Model_CoupledAccelDerivative(m, d2, es, em)
    CALL CD_Init_Model(fresh, q0, v0, conn, [5.0_wp, 5.0_wp], [1.0e6_wp, 1.0e6_wp], [50.0_wp, 50.0_wp], .TRUE., &
                       f_ext, [1, 2, 3, 7, 8, 9], cfg, es, em, added_mass_waterline_z=[-3.0_wp, -3.0_wp, -3.0_wp], &
                       added_mass_rho=1025.0_wp, added_mass_diameter=0.3_wp, added_mass_can=1.0_wp, &
                       added_mass_cat=0.0_wp)
    CALL CD_Calc_Model_CoupledAccelDerivative(fresh, d3, es, em)
    CALL require(nan_max_abs(d1 - d3) > 0.0_wp, 'added-mass cache: the waterline changes the derivative')
    CALL require(nan_max_abs(d2 - d3) <= 1.0e-12_wp*nan_max_abs(d3), &
                 'added-mass cache: a moved waterline refreshes the cached derivative')
    CALL CD_End_Model(m, es, em)
    CALL CD_End_Model(fresh, es, em)
  END SUBROUTINE case_added_mass_waterline_cache

  SUBROUTINE case_ve_reload_twins()
    TYPE(CD_ModelType) :: m
    TYPE(GenAlphaConfig) :: cfg
    REAL(wp) :: q0(9), v0(9), f_ext(9)
    INTEGER :: conn(2, 2), es
    CHARACTER(300) :: em
    conn = RESHAPE([1, 2, 2, 3], [2, 2])
    q0 = [0.0_wp, 0.0_wp, 0.0_wp, 10.1_wp, 0.0_wp, 0.0_wp, 20.2_wp, 0.0_wp, 0.0_wp]
    v0 = 0.0_wp
    f_ext = 0.0_wp
    CALL CD_Init_Model(m, q0, v0, conn, [10.0_wp, 10.0_wp], [1.0e6_wp, 1.0e6_wp], [1.0_wp, 1.0_wp], .TRUE., &
                       f_ext, [1, 2, 3, 7, 8, 9], cfg, es, em, ve_ea_d=[2.0e6_wp, 2.0e6_wp], &
                       ve_ba=[1.0e3_wp, 1.0e3_wp], ve_ba_d=[1.0e3_wp, 1.0e3_wp])
    CALL require(es == CD_MODEL_OK, 'viscoelastic reload: init: '//TRIM(em))
    IF (es /= CD_MODEL_OK) RETURN
    CALL CD_Set_Model_VE_Dl1(m, [0.01_wp, 0.02_wp], es, em)
    CALL require(es == CD_MODEL_OK, 'viscoelastic reload: set: '//TRIM(em))
    CALL require(nan_max_abs(m%ve_dl_1_rollback - [0.01_wp, 0.02_wp]) <= 0.0_wp .AND. &
                 nan_max_abs(m%recovery_ve_dl_1 - [0.01_wp, 0.02_wp]) <= 0.0_wp, &
                 'viscoelastic reload: the rollback and recovery twins follow the reload')
    CALL CD_End_Model(m, es, em)
  END SUBROUTINE case_ve_reload_twins

  PURE REAL(wp) FUNCTION gfun(q) RESULT(g)
    REAL(wp), INTENT(IN) :: q
    REAL(wp) :: x
    x = q/1000.0_wp
    g = 0.2_wp*(x**3 - 3.0_wp*x + 2.0_wp)
  END FUNCTION gfun

  PURE REAL(wp) FUNCTION dgdq(q) RESULT(d)
    REAL(wp), INTENT(IN) :: q
    REAL(wp) :: x
    x = q/1000.0_wp
    d = 0.2_wp*(3.0_wp*x*x - 3.0_wp)/1000.0_wp
  END FUNCTION dgdq

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_core_solver_regressions
