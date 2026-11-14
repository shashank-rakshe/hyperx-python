! File: tests/test_section_curvature.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_section_curvature
  !! The section-frame curvature components (CurvX<L>N<J>, CurvY<L>N<J>) of a lazy-wave cable at
  !! its static start (CD_HFMF_Section_Curvature):
  !!   1. on a planar line (End A clamped, no current) the curvature lies on the section axis x
  !!      (CurvY is zero) and sqrt(CurvX^2 + CurvY^2) is Curv<L>N<J>;
  !!   2. in a cross current the line leaves its plane, both components appear and their norm is
  !!      still the curvature;
  !!   3. the same deck turned 30 degrees about the vertical gives the same components (the
  !!      section frame turns with the line);
  !!   4. turning the hang-off 30 degrees about the End A tangent turns the section axes with it
  !!      (End A clamped): the components rotate by -30 degrees at every node;
  !!   5. on a line restrained in torsion with a 90 degree pretwist at End B, the section axis x
  !!      leaves End A on its torsion normal Nx and reaches End B turned 90 degrees about the
  !!      tangent, onto End B's own pretwisted normal;
  !!   6. with End A bending-pinned and restrained in torsion, turning the host about the End A
  !!      tangent turns the torsion frames only; the next evaluation is not the cached one but the
  !!      same as a fresh evaluation.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_HermiteCable, CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_Curvature, CD_HFMF_Section_Curvature, &
                                          CD_HFMF_SetCoupledKinematics, CD_HFMF_End, CD_HFMF_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Dyn_Section_Curvature, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  ! the nodes 1, 9, ..., 129 the driver cases write (End A to End B)
  INTEGER, PARAMETER :: NSAMPLE = 17
  INTEGER :: nfail = 0
  REAL(wp), ALLOCATABLE :: k1(:), x1(:), y1(:), k2(:), x2(:), y2(:), k3(:), x3(:), y3(:)

  ! 1. planar
  CALL static_components('sc_planar.dat', 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], .FALSE., 0.0_wp, k1, x1, y1)
  IF (ALLOCATED(k1)) THEN
    CALL require(MAXVAL(ABS(y1)) <= 1.0e-9_wp*MAXVAL(k1), 'planar line: CurvY is zero')
    CALL require(MAXVAL(ABS(SQRT(x1**2 + y1**2) - k1)) <= 1.0e-10_wp*MAXVAL(k1), &
                 'planar line: sqrt(CurvX^2 + CurvY^2) = Curv')
  END IF
  ! 2. cross current (the standalone driver: the single-cable entry takes no deck current)
  CALL driver_components('sc_cross', 0.0_wp, [0.0_wp, 0.4_wp, 0.0_wp], k2, x2, y2)
  IF (ALLOCATED(k2)) THEN
    CALL require(MAXVAL(ABS(y2)) > 1.0e-3_wp*MAXVAL(k2), 'cross current: the line bends out of its plane')
    ! the driver prints eight significant digits
    CALL require(MAXVAL(ABS(SQRT(x2**2 + y2**2) - k2)) <= 1.0e-7_wp*MAXVAL(k2), &
                 'cross current: sqrt(CurvX^2 + CurvY^2) = Curv')
  END IF
  ! 3. the cross-current deck turned 30 degrees about the vertical
  CALL driver_components('sc_turned', 30.0_wp, [0.0_wp, 0.4_wp, 0.0_wp], k3, x3, y3)
  IF (ALLOCATED(k2) .AND. ALLOCATED(k3)) THEN
    WRITE (*, '(A,2ES10.3)') 'turned deck: largest CurvX, CurvY change / largest curvature ', &
      MAXVAL(ABS(x3 - x2))/MAXVAL(k2), MAXVAL(ABS(y3 - y2))/MAXVAL(k2)
    CALL require(MAXVAL(ABS(x3 - x2)) <= 1.0e-6_wp*MAXVAL(k2) .AND. MAXVAL(ABS(y3 - y2)) <= 1.0e-6_wp*MAXVAL(k2), &
                 'the components do not depend on the heading of the line')
  END IF
  ! 4. the hang-off turned about its tangent
  CALL parent_roll()
  ! 5. torsion
  CALL torsion_frame()
  ! 6. the torsion frames turned by the host, End A pinned in bending
  CALL torsion_pinned_rotation()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: section-frame curvature components'

CONTAINS

  SUBROUTINE static_components(path, heading_deg, current, torsion, pretwist_b, k, kx, ky)
    !! Build the deck (write_deck) and return Curv, CurvX and CurvY of every node (internal order).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: heading_deg, current(3), pretwist_b
    LOGICAL, INTENT(IN) :: torsion
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: k(:), kx(:), ky(:)
    TYPE(CD_HFMF_ModuleType) :: cable
    INTEGER :: es, cn, nn
    CHARACTER(1024) :: em
    CALL write_deck(path, heading_deg, current, torsion, pretwist_b)
    CALL CD_Init_Deck_HermiteCable(path, 0.1_wp, cable, cn, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, TRIM(path)//': build: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    nn = cable%line%nn
    ALLOCATE (k(nn), kx(nn), ky(nn))
    CALL CD_HFMF_Curvature(cable, k, es, em)
    CALL require(es == CD_HFMF_OK, TRIM(path)//': curvature: '//TRIM(em))
    CALL CD_HFMF_Section_Curvature(cable, kx, ky, es, em)
    CALL require(es == CD_HFMF_OK, TRIM(path)//': section curvature: '//TRIM(em))
    CALL CD_HFMF_End(cable)
  END SUBROUTINE static_components

  SUBROUTINE driver_components(root, heading_deg, current, k, kx, ky)
    !! Curv, CurvX and CurvY of every eighth node at t = 0 (TMax = 0) from the standalone driver.
    CHARACTER(*), INTENT(IN) :: root
    REAL(wp), INTENT(IN) :: heading_deg, current(3)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: k(:), kx(:), ky(:)
    REAL(wp) :: row(1 + 3*NSAMPLE)
    INTEGER :: es, u, ios, j
    LOGICAL :: conv
    CHARACTER(1024) :: em, line
    CALL write_deck(root//'.dat', heading_deg, current, .FALSE., 0.0_wp, node_channels=.TRUE.)
    CALL CD_Run_Deck_Driver(root//'.dat', root, conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, root//': run: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='OLD', ACTION='READ')
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, 'Time') == 1) EXIT
    END DO
    READ (u, *, IOSTAT=ios) row
    CLOSE (u)
    CALL require(ios == 0, root//': read the t = 0 row')
    IF (ios /= 0) RETURN
    ALLOCATE (k(NSAMPLE), kx(NSAMPLE), ky(NSAMPLE))
    DO j = 1, NSAMPLE
      k(j) = row(1 + 3*j - 2)
      kx(j) = row(1 + 3*j - 1)
      ky(j) = row(1 + 3*j)
    END DO
  END SUBROUTINE driver_components

  SUBROUTINE parent_roll()
    TYPE(CD_HFMF_ModuleType) :: cable
    REAL(wp), ALLOCATABLE :: kx0(:), ky0(:), kx1(:), ky1(:)
    REAL(wp) :: t(3), r(3, 3), ca, sa, kmax
    INTEGER :: es, cn, nn, i, j
    CHARACTER(1024) :: em
    CALL write_deck('sc_roll.dat', 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], .FALSE., 0.0_wp)
    CALL CD_Init_Deck_HermiteCable('sc_roll.dat', 0.1_wp, cable, cn, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'roll: build: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL require(cable%has_parent_endconn, 'roll: the clamped End A has a parent frame')
    nn = cable%line%nn
    ALLOCATE (kx0(nn), ky0(nn), kx1(nn), ky1(nn))
    CALL CD_HFMF_Section_Curvature(cable, kx0, ky0, es, em)
    ! turn the parent 30 degrees about the End A -> End B tangent (global = solve frame here):
    ! global-to-parent DCM P' = P R^T, R the rotation by +30 degrees about t
    t = -cable%line%q(6*(nn - 1) + 4:6*(nn - 1) + 6)
    t = t/NORM2(t)
    ca = COS(PI/6.0_wp)
    sa = SIN(PI/6.0_wp)
    DO i = 1, 3
      DO j = 1, 3
        r(i, j) = ca*MERGE(1.0_wp, 0.0_wp, i == j) + (1.0_wp - ca)*t(i)*t(j)
      END DO
    END DO
    r(1, 2) = r(1, 2) - sa*t(3); r(2, 1) = r(2, 1) + sa*t(3)
    r(1, 3) = r(1, 3) + sa*t(2); r(3, 1) = r(3, 1) - sa*t(2)
    r(2, 3) = r(2, 3) - sa*t(1); r(3, 2) = r(3, 2) + sa*t(1)
    cable%parent_dcm = MATMUL(cable%parent_dcm, TRANSPOSE(r))
    CALL CD_HFMF_Section_Curvature(cable, kx1, ky1, es, em)
    CALL require(es == CD_HFMF_OK, 'roll: section curvature: '//TRIM(em))
    kmax = MAXVAL(SQRT(kx0**2 + ky0**2))
    WRITE (*, '(A,ES10.3)') 'roll: largest departure from the axes turned by 30 degrees / largest curvature ', &
      MAX(MAXVAL(ABS(kx1 - (ca*kx0 + sa*ky0))), MAXVAL(ABS(ky1 - (-sa*kx0 + ca*ky0))))/kmax
    CALL require(MAXVAL(ABS(kx1 - (ca*kx0 + sa*ky0))) <= 1.0e-9_wp*kmax .AND. &
                 MAXVAL(ABS(ky1 - (-sa*kx0 + ca*ky0))) <= 1.0e-9_wp*kmax, &
                 'roll: the section axes turn with the clamped hang-off')
    CALL CD_HFMF_End(cable)
  END SUBROUTINE parent_roll

  SUBROUTINE torsion_pinned_rotation()
    TYPE(CD_HFMF_ModuleType) :: cable
    REAL(wp), ALLOCATABLE :: kx0(:), ky0(:), kx1(:), ky1(:), kx2(:), ky2(:)
    REAL(wp) :: t(3), r(3, 3), ca, sa, pos(3), zero3(3)
    INTEGER :: es, cn, nn, i, j
    CHARACTER(1024) :: em
    CALL write_deck('sc_tpin.dat', 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], .TRUE., 90.0_wp, pinned_a=.TRUE.)
    CALL CD_Init_Deck_HermiteCable('sc_tpin.dat', 0.1_wp, cable, cn, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'pinned torsion: build: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL require(.NOT. cable%has_parent_endconn, 'pinned torsion: End A carries no bending connection')
    nn = cable%line%nn
    ALLOCATE (kx0(nn), ky0(nn), kx1(nn), ky1(nn), kx2(nn), ky2(nn))
    CALL CD_HFMF_Section_Curvature(cable, kx0, ky0, es, em)
    CALL require(es == CD_HFMF_OK, 'pinned torsion: section curvature: '//TRIM(em))
    ! the host turned 30 degrees about the End A -> End B tangent: global-to-parent DCM R^T
    t = -cable%line%q(6*(nn - 1) + 4:6*(nn - 1) + 6)
    t = t/NORM2(t)
    ca = COS(PI/6.0_wp)
    sa = SIN(PI/6.0_wp)
    DO i = 1, 3
      DO j = 1, 3
        r(i, j) = ca*MERGE(1.0_wp, 0.0_wp, i == j) + (1.0_wp - ca)*t(i)*t(j)
      END DO
    END DO
    r(1, 2) = r(1, 2) - sa*t(3); r(2, 1) = r(2, 1) + sa*t(3)
    r(1, 3) = r(1, 3) + sa*t(2); r(3, 1) = r(3, 1) - sa*t(2)
    r(2, 3) = r(2, 3) - sa*t(1); r(3, 2) = r(3, 2) + sa*t(1)
    pos = cable%line%q(6*(nn - 1) + 1:6*(nn - 1) + 3)
    zero3 = 0.0_wp
    CALL CD_HFMF_SetCoupledKinematics(cable, pos, zero3, zero3, es, em, TRANSPOSE(r), zero3, zero3)
    CALL require(es == CD_HFMF_OK, 'pinned torsion: host rotation: '//TRIM(em))
    CALL CD_HFMF_Section_Curvature(cable, kx1, ky1, es, em)
    cable%sc_valid = .FALSE.
    CALL CD_HFMF_Section_Curvature(cable, kx2, ky2, es, em)
    CALL require(MAXVAL(ABS(kx1 - kx0)) + MAXVAL(ABS(ky1 - ky0)) > 0.0_wp, &
                 'pinned torsion: the turned torsion frames turn the components')
    CALL require(MAXVAL(ABS(kx1 - kx2)) <= 0.0_wp .AND. MAXVAL(ABS(ky1 - ky2)) <= 0.0_wp, &
                 'pinned torsion: the evaluation after the host rotation is the fresh one, not the cached one')
    CALL CD_HFMF_End(cable)
  END SUBROUTINE torsion_pinned_rotation

  SUBROUTINE torsion_frame()
    TYPE(CD_HFMF_ModuleType) :: cable
    REAL(wp), ALLOCATABLE :: kx(:), ky(:), fr(:, :), k(:)
    REAL(wp) :: tb(3), ny(3), expect(3), ang_a, ang_b
    INTEGER :: es, cn, nn
    CHARACTER(1024) :: em
    CALL write_deck('sc_torsion.dat', 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], .TRUE., 90.0_wp)
    CALL CD_Init_Deck_HermiteCable('sc_torsion.dat', 0.1_wp, cable, cn, es, em, host_orientation=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'torsion: build: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    nn = cable%line%nn
    ALLOCATE (kx(nn), ky(nn), fr(3, nn), k(nn))
    CALL CD_HermiteCable_Dyn_Section_Curvature(cable%line, [0.0_wp, 0.0_wp, 1.0_wp], kx, ky, es, em, frame=fr)
    CALL require(es == CD_HCDYN_OK, 'torsion: section curvature: '//TRIM(em))
    CALL CD_HFMF_Curvature(cable, k, es, em)
    CALL require(MAXVAL(ABS(SQRT(kx**2 + ky**2) - k)) <= 1.0e-10_wp*MAXVAL(k), &
                 'torsion: sqrt(CurvX^2 + CurvY^2) = Curv')
    ny = [0.0_wp, 1.0_wp, 0.0_wp]
    ! End A (the last internal node) starts on its torsion normal Nx = +y
    ang_a = ACOS(MAX(-1.0_wp, MIN(1.0_wp, DOT_PRODUCT(fr(:, nn), ny))))
    ! End B (internal node 1): Nx = +y turned 90 degrees about the End A -> End B tangent
    tb = -cable%line%q(4:6)/NORM2(cable%line%q(4:6))
    expect = cross(tb, ny)
    ang_b = ACOS(MAX(-1.0_wp, MIN(1.0_wp, DOT_PRODUCT(fr(:, 1), expect))))
    WRITE (*, '(A,2ES10.3,A)') 'torsion: section axis x off Nx at End A, off the pretwisted normal at End B ', &
      ang_a, ang_b, ' rad'
    CALL require(ang_a <= 1.0e-9_wp, 'torsion: the section axis x starts on End A''s Nx')
    CALL require(ang_b <= 2.0e-3_wp, 'torsion: the section axis x arrives on End B''s pretwisted normal')
    CALL CD_HFMF_End(cable)
  END SUBROUTINE torsion_frame

  SUBROUTINE write_deck(path, heading_deg, current, torsion, pretwist_b, node_channels, pinned_a)
    !! A 170 m lazy-wave cable from a hang-off at 14 m depth to an anchor at 80 m, clamped at End A,
    !! turned by heading_deg about the vertical through the origin, in the uniform current
    !! (given before the turn). torsion: both ends restrained in torsion, Nx along +y, Pretwist
    !! pretwist_b at End B.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: heading_deg, current(3), pretwist_b
    LOGICAL, INTENT(IN) :: torsion
    ! node_channels: write Curv, CurvX, CurvY of every eighth node, and run to TMax = 0
    LOGICAL, INTENT(IN), OPTIONAL :: node_channels
    ! pinned_a: End A pinned in bending (still restrained in torsion)
    LOGICAL, INTENT(IN), OPTIONAL :: pinned_a
    CHARACTER(8) :: stiff_a
    REAL(wp) :: c, s, pa(3), pb(3), eza(3), ezb(3), nx(3), cu(3)
    INTEGER :: u, j
    LOGICAL :: nodes
    nodes = .FALSE.
    IF (PRESENT(node_channels)) nodes = node_channels
    c = COS(heading_deg*PI/180.0_wp)
    s = SIN(heading_deg*PI/180.0_wp)
    pa = turn(c, s, [5.0_wp, 0.0_wp, -14.0_wp])
    pb = turn(c, s, [125.0_wp, 0.0_wp, -80.0_wp])
    eza = turn(c, s, [0.14641_wp, 0.0_wp, -0.98922_wp])
    ezb = turn(c, s, [0.99999_wp, 0.0_wp, 0.00503_wp])
    nx = turn(c, s, [0.0_wp, 1.0_wp, 0.0_wp])
    cu = turn(c, s, current)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'section-frame curvature test cable'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    WRITE (u, '(A)') 'TypeName  Diam   MassDenInAir  EA       BA   EI       GAs      GJ      Irt     Irn     '// &
      'Cd_n Cd_t Ca_n Ca_t'
    WRITE (u, '(A)') '(-)       (m)    (kg/m)        (N)      (-)  (N-m2)   (N)      (N-m2)  (kg-m)  (kg-m)  '// &
      '(-)  (-)  (-)  (-)'
    WRITE (u, '(A)') 'bare      0.160  36.70         4.69e8   0.0  1.99e4   9.02e7   5.0e4   0.0587  0.1174  '// &
      '1.2  0.1  1.0  0.0'
    WRITE (u, '(A)') 'buoy      0.290  59.53         4.69e8   0.0  1.99e4   9.02e7   5.0e4   0.3129  0.6258  '// &
      '1.2  0.1  1.0  0.0'
    WRITE (u, '(A)') '--------------------- POINTS ------------------------------------------------'
    WRITE (u, '(A)') 'ID  Type     X       Y    Z'
    WRITE (u, '(A)') '(-) (-)      (m)     (m)  (m)'
    WRITE (u, '(A,3F14.8)') '1   Coupled ', pa
    WRITE (u, '(A,3F14.8)') '2   Fixed   ', pb
    WRITE (u, '(A)') '--------------------- LINES -------------------------------------------------'
    WRITE (u, '(A)') 'ID  NodeA  NodeB  Outputs'
    WRITE (u, '(A)') '(-) (-)    (-)    (-)'
    WRITE (u, '(A)') '1   1      2      -'
    WRITE (u, '(A)') '--------------------- SECTIONS ----------------------------------------------'
    WRITE (u, '(A)') 'LineID  LineType  Length   NumSegs'
    WRITE (u, '(A)') '(-)     (-)       (m)      (-)'
    WRITE (u, '(A)') '1       bare      68.114   56'
    WRITE (u, '(A)') '1       buoy      50.000   40'
    WRITE (u, '(A)') '1       bare      52.101   32'
    WRITE (u, '(A)') '--------------------- END CONNECTIONS ---------------------------------------'
    IF (torsion) THEN
      WRITE (u, '(A)') 'LineID  End  Stiffness  EzX      EzY  EzZ       TorsStiffness  NxX  NxY  NxZ  Pretwist'
      WRITE (u, '(A)') '(-)     (-)  (N-m/rad)  (-)      (-)  (-)       (N-m/rad)      (-)  (-)  (-)  (deg)'
      stiff_a = 'Rigid'
      IF (PRESENT(pinned_a)) THEN
        IF (pinned_a) stiff_a = 'Pinned'
      END IF
      WRITE (u, '(A,3F12.8,A,3F12.8,A)') '1  A  '//TRIM(stiff_a)//' ', eza, '  Rigid ', nx, '  0.0'
      WRITE (u, '(A,3F12.8,A,3F12.8,F8.2)') '1  B  Rigid ', ezb, '  Rigid ', nx, pretwist_b
    ELSE
      WRITE (u, '(A)') 'LineID  End  Stiffness  EzX      EzY  EzZ'
      WRITE (u, '(A)') '(-)     (-)  (N-m/rad)  (-)      (-)  (-)'
      WRITE (u, '(A,3F12.8)') '1  A  Rigid ', eza
    END IF
    WRITE (u, '(A)') '--------------------- OPTIONS -----------------------------------------------'
    WRITE (u, '(A)') '80.0     WtrDpth'
    WRITE (u, '(A)') '0.1      dtM'
    WRITE (u, '(A)') MERGE('0.0      TMax', '1.0      TMax', nodes)
    IF (NORM2(cu) > 0.0_wp) WRITE (u, '(A,3F12.8,A)') 'uniform ', cu, ' current'
    WRITE (u, '(A)') '--------------------- OUTPUTS -----------------------------------------------'
    IF (nodes) THEN
      DO j = 1, NSAMPLE
        WRITE (u, '(A,I0,A,I0,A,I0)') 'Curv1N', 8*j - 7, ' CurvX1N', 8*j - 7, ' CurvY1N', 8*j - 7
      END DO
    ELSE
      WRITE (u, '(A)') '"FairTen1"'
    END IF
    WRITE (u, '(A)') '--------------------- need this line ----------------------------------------'
    CLOSE (u)
  END SUBROUTINE write_deck

  PURE FUNCTION turn(c, s, v) RESULT(w)
    !! v turned about the vertical by the angle of cosine c and sine s.
    REAL(wp), INTENT(IN) :: c, s, v(3)
    REAL(wp) :: w(3)
    w = [c*v(1) - s*v(2), s*v(1) + c*v(2), v(3)]
  END FUNCTION turn

  PURE FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require
END PROGRAM test_section_curvature
