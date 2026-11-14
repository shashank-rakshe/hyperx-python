! File: tests/test_clamped_cable_ends.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Gates of finite-EI cables clamped (Rigid) or elastically connected to Rigid6 bodies and rods
!> (END CONNECTIONS on a Body<N> point or a rod end, the monolithic body step and the static
!> solve):
!>  1. cantilever: a cable clamped at 30 deg below horizontal to a (massive, pitched) body, its
!>     other end pinned where a planar elastica under a horizontal tip load and its own weight
!>     puts the tip: end force and clamp moment within 0.5 % of the elastica (shooting, RK4);
!>     the same with an elastic connection of 1e5 N m/rad;
!>  2. moment return: the body's net wrench equals the cable end force and its moment about the
!>     reference point plus the connection moment (to the output precision);
!>  3. energy: a free body swinging on a clamped cable (neutral, no drag or added mass,
!>     rhoInf 1) keeps body plus cable energy within 0.5 % over 10 s and stays bounded;
!>  4. statics: a buoyant, moored body with a clamped cable reaches its static equilibrium
!>     (bodyIC static) and stays at rest in the dynamics, and its pitch differs from the pinned
!>     case by the connection moment;
!>  5. fail-closed: bodyScheme staggered and a rod-end direction off the rod axis are rejected.
PROGRAM test_clamped_cable_ends
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Conventions, ONLY: CD_Body_Rotation
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_Multibody_Probe_Arm, CD_Multibody_Probe_Get
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, G = 9.80665_wp, RHOW = 1025.0_wp
  REAL(wp), PARAMETER :: DIAM = 0.2_wp, EI = 1.0e5_wp, EA = 1.0e9_wp, LEN = 20.0_wp, Q = 50.0_wp
  INTEGER :: n_fail = 0

  CALL check_cantilever('rigid', 0.0_wp)
  CALL check_cantilever('rigid', 20.0_wp)
  CALL check_cantilever('elastic', 20.0_wp)
  CALL check_energy()
  CALL check_statics()
  CALL check_rod()
  CALL check_rejections()
  CALL check_staggered_probe()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' clamped-end gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI cables clamped to bodies and rods (cantilever, moment return, energy, statics)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE run_deck(path, root, ok, em_out)
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT), OPTIONAL :: em_out
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    IF (PRESENT(em_out)) THEN
      em_out = em
    ELSE
      CALL require(ok, 'deck '//TRIM(path)//' converged: '//TRIM(em))
    END IF
  END SUBROUTINE run_deck

  ! ------------------------------------------------------------------------------------------
  ! Planar elastica reference (x-z plane, theta from +x, arc length s from the clamped end A):
  ! the part [s, L] exerts the force V(s) = (Px, Pz - q (L - s)) and the moment
  ! m(s) = EI theta'(s) on the part [0, s]; m' = -(r' x V) gives
  ! EI theta'' = -x' Vz + z' Vx, with x' = (1 + N/EA) cos theta, z' = (1 + N/EA) sin theta,
  ! N = V . t. The tip is pinned (theta'(L) = 0). Rigid: theta(0) = theta_d, shoot on theta'(0);
  ! elastic: EI theta'(0) = k (theta(0) - theta_d), shoot on theta(0).
  SUBROUTINE elastica(elastic, theta_d, kspring, px, pz, m0, tip)
    LOGICAL, INTENT(IN) :: elastic
    REAL(wp), INTENT(IN) :: theta_d, kspring, px, pz
    REAL(wp), INTENT(OUT) :: m0, tip(2)
    REAL(wp) :: pa, pb, fa, fb, pc, y(4)
    INTEGER :: it
    pa = 0.0_wp
    pb = 0.1_wp
    IF (elastic) THEN
      pa = theta_d
      pb = theta_d + 0.05_wp
    END IF
    CALL shoot(pa, elastic, theta_d, kspring, px, pz, y)
    fa = y(4)
    CALL shoot(pb, elastic, theta_d, kspring, px, pz, y)
    fb = y(4)
    DO it = 1, 60
      IF (ABS(fb) < 1.0e-15_wp) EXIT
      pc = pb - fb*(pb - pa)/(fb - fa)
      pa = pb
      fa = fb
      pb = pc
      CALL shoot(pb, elastic, theta_d, kspring, px, pz, y)
      fb = y(4)
    END DO
    CALL shoot(pb, elastic, theta_d, kspring, px, pz, y)
    tip = y(1:2)
    IF (elastic) THEN
      m0 = kspring*(pb - theta_d)
    ELSE
      m0 = EI*pb
    END IF
  END SUBROUTINE elastica

  SUBROUTINE shoot(p, elastic, theta_d, kspring, px, pz, yend)
    REAL(wp), INTENT(IN) :: p, theta_d, kspring, px, pz
    LOGICAL, INTENT(IN) :: elastic
    REAL(wp), INTENT(OUT) :: yend(4)
    INTEGER, PARAMETER :: NS = 4000
    REAL(wp) :: h, s, k1(4), k2(4), k3(4), k4(4)
    INTEGER :: i
    IF (elastic) THEN
      yend = [0.0_wp, 0.0_wp, p, kspring*(p - theta_d)/EI]
    ELSE
      yend = [0.0_wp, 0.0_wp, theta_d, p]
    END IF
    h = LEN/REAL(NS, wp)
    s = 0.0_wp
    DO i = 1, NS
      k1 = f(s, yend, px, pz)
      k2 = f(s + 0.5_wp*h, yend + 0.5_wp*h*k1, px, pz)
      k3 = f(s + 0.5_wp*h, yend + 0.5_wp*h*k2, px, pz)
      k4 = f(s + h, yend + h*k3, px, pz)
      yend = yend + h*(k1 + 2.0_wp*k2 + 2.0_wp*k3 + k4)/6.0_wp
      s = s + h
    END DO
  END SUBROUTINE shoot
  FUNCTION f(s, yy, px, pz) RESULT(d)
    REAL(wp), INTENT(IN) :: s, yy(4), px, pz
    REAL(wp) :: d(4), vx, vz, e
    vx = px
    vz = pz - Q*(LEN - s)
    e = 1.0_wp + (vx*COS(yy(3)) + vz*SIN(yy(3)))/EA
    d = [e*COS(yy(3)), e*SIN(yy(3)), yy(4), (-e*COS(yy(3))*vz + e*SIN(yy(3))*vx)/EI]
  END FUNCTION f

  SUBROUTINE write_cable_deck(path, body_row, off, anchor, conn, ez, opts_extra, outs, seg)
    !! One Rigid6 body carrying a finite-EI cable (the cantilever line type) at body point off,
    !! End B fixed at anchor, End A connection conn with direction ez (body frame).
    CHARACTER(*), INTENT(IN) :: path, body_row, conn, opts_extra(:), outs(:)
    REAL(wp), INTENT(IN) :: off(3), anchor(3), ez(3)
    INTEGER, INTENT(IN) :: seg
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'clamped cable gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A,ES24.16,A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*DIAM**2 + Q/G, ' ', EA, ' 0.0 ', EI, &
      ' 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') body_row
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A,3ES24.16,A)') '1 Body1 ', off, ' 0 0 0 0'
    WRITE (u, '(A,3ES24.16,A)') '2 Fixed ', anchor, ' 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A,ES24.16,A,I0)') '1 cab ', LEN, ' ', seg
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A,A,3ES24.16)') '1 A ', conn, ez
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') 'moordyn bodyWetting'
    DO i = 1, SIZE(opts_extra)
      WRITE (u, '(A)') TRIM(opts_extra(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    DO i = 1, SIZE(outs)
      WRITE (u, '(A)') TRIM(outs(i))
    END DO
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_cable_deck

  SUBROUTINE read_row(path, row, vals, ok)
    !! Data row `row` (0 = first) of a driver .out file.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: row
    REAL(wp), INTENT(OUT) :: vals(:)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: u, ios, i
    CHARACTER(2048) :: buf
    ok = .FALSE.
    vals = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO i = 0, row
      READ (u, *, IOSTAT=ios) vals
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ok = ALL(IEEE_IS_FINITE(vals))
  END SUBROUTINE read_row

  FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_cantilever(mode, pitch)
    !! The massive body (1e9 kg, neutral, fully wet) holds the clamp; its pose over the two
    !! 0.01 s steps is fixed to 1e-8 m. The static state (row 0) is scored.
    CHARACTER(*), INTENT(IN) :: mode
    REAL(wp), INTENT(IN) :: pitch
    REAL(wp), PARAMETER :: PX = 5000.0_wp, KSPR = 1.0e5_wp, THD = -PI/6.0_wp
    REAL(wp), PARAMETER :: MB = 1.0e9_wp
    REAL(wp) :: m0, tip(2), rot(3, 3), dglob(3), dbody(3), off(3), ra(3), anchor(3), fa_ref(3), ma_ref(3)
    REAL(wp) :: fa(3), ma(3), wrench(7), mnet_ref(3), ef, em_rel, ew
    REAL(wp), ALLOCATABLE :: rec(:, :)
    CHARACTER(64) :: root, conn
    CHARACTER(160) :: row
    LOGICAL :: ok
    CALL elastica(mode == 'elastic', THD, KSPR, PX, 0.0_wp, m0, tip)
    rot = CD_Body_Rotation(0.0_wp, pitch, 0.0_wp)
    dglob = [COS(THD), 0.0_wp, SIN(THD)]
    dbody = MATMUL(TRANSPOSE(rot), dglob)
    off = [1.5_wp, 0.0_wp, -0.5_wp]
    ra = [0.0_wp, 0.0_wp, -60.0_wp] + MATMUL(rot, off)
    anchor = ra + [tip(1), 0.0_wp, tip(2)]
    ! the cable's end force and connection moment on the body (global)
    fa_ref = [PX, 0.0_wp, -Q*LEN]
    ma_ref = [0.0_wp, -m0, 0.0_wp]
    WRITE (row, '(A,F6.2,A,ES24.16,A,ES24.16,A)') '1 Rigid6 0 0 -60 0 ', pitch, ' 0 ', MB, ' ', MB/RHOW, &
      ' 0 0 0 0 0 1.0e12 1.0e12 1.0e12'
    conn = 'Rigid'
    IF (mode == 'elastic') WRITE (conn, '(ES12.5)') KSPR
    WRITE (root, '(A,A,I0)') 'clamp_cantilever_', mode, NINT(pitch)
    CALL write_cable_deck(TRIM(root)//'.dat', TRIM(row), off, anchor, TRIM(conn), dbody, &
                          [CHARACTER(24) :: '0.01 dtM', '0.02 TMax', 'deck bodyIC'], &
                          [CHARACTER(12) :: 'Body1Fx', 'Body1Fy', 'Body1Fz', 'Body1Mx', 'Body1My', 'Body1Mz'], 40)
    CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp])
    CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
    CALL CD_Multibody_Probe_Get(rec)
    ok = ok .AND. ALLOCATED(rec)
    CALL require(ok, TRIM(root)//': probed run completes')
    IF (.NOT. ok) RETURN
    ma = rec(24:26, 0)
    fa = rec(27:29, 0)
    ef = NORM2(fa - fa_ref)/NORM2(fa_ref)
    em_rel = NORM2(ma - ma_ref)/ABS(m0)
    WRITE (*, '(A,A,A,F5.1,A,ES10.3,A,ES10.3,A,ES12.5,A)') 'cantilever gate (', mode, ', pitch ', pitch, &
      ' deg): end-force error ', ef, ', clamp-moment error ', em_rel, ' (elastica M = ', m0, ' N m)'
    CALL require(ef <= 5.0e-3_wp, TRIM(root)//': end force within 0.5 % of the elastica')
    CALL require(em_rel <= 5.0e-3_wp, TRIM(root)//': clamp moment within 0.5 % of the elastica')
    CALL require(nan_max_abs(rec(2:4, UBOUND(rec, 2)) - rec(2:4, 0)) <= 1.0e-8_wp, &
                 TRIM(root)//': the massive body holds the clamp')
    ! moment return: the body's net wrench is the cable end force and its moment about the
    ! reference point plus the connection moment
    CALL read_row(TRIM(root)//'.out', 0, wrench, ok)
    CALL require(ok, TRIM(root)//': output row 0 readable')
    IF (.NOT. ok) RETURN
    mnet_ref = cross(MATMUL(rot, off), fa) + ma
    ew = MAX(NORM2(wrench(2:4) - fa)/NORM2(fa), NORM2(wrench(5:7) - mnet_ref)/NORM2(mnet_ref))
    WRITE (*, '(A,A,A,ES10.3)') 'moment-return gate (', mode, '): body net wrench vs cable end loads ', ew
    CALL require(ew <= 1.0e-6_wp, TRIM(root)//': body wrench equals cable force and moment (1e-6, output precision)')
  END SUBROUTINE check_cantilever

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_energy()
    !! A free neutral body (5 t) swinging on a taut clamped cable (EA 1e6 N), launched with
    !! v = (0.05, 0, 0.05) m/s and omega = (0, 0.03, 0.02) rad/s: body kinetic energy plus cable
    !! kinetic and elastic energy (neutral cable: no weight work; no drag, no added mass; Rigid
    !! connection: no work) is conserved by the rhoInf = 1 monolithic step.
    REAL(wp), PARAMETER :: MB = 5.0e3_wp, IB(3) = [2.0e3_wp, 3.0e3_wp, 4.0e3_wp]
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: e0, e, dev, rot(3, 3), w(3), wb(3), amp
    INTEGER :: u, i
    LOGICAL :: ok
    CHARACTER(*), PARAMETER :: root = 'clamp_energy'
    OPEN (NEWUNIT=u, FILE=root//'.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'clamped cable energy gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*DIAM**2, ' 1.0e6 0.0 1.0e4 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A,ES24.16,A)') '1 Rigid6 0 0 -50 0 0 0 5.0e3 ', MB/RHOW, ' 0 0 0 0 0 2.0e3 3.0e3 4.0e3'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.0 0 0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 21.1 0 -50 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 20.0 20'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A)') '1 A Rigid 1.0 0.0 0.0'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') 'moordyn bodyWetting'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    WRITE (u, '(A)') '1.0 rhoInf'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL CD_Multibody_Probe_Arm([0.05_wp, 0.0_wp, 0.05_wp], [0.0_wp, 0.03_wp, 0.02_wp])
    CALL run_deck(root//'.dat', root, ok)
    CALL CD_Multibody_Probe_Get(rec)
    ok = ok .AND. ALLOCATED(rec)
    CALL require(ok, 'clamped energy run completes')
    IF (.NOT. ok) RETURN
    dev = 0.0_wp
    amp = 0.0_wp
    DO i = 0, UBOUND(rec, 2)
      rot = RESHAPE(rec(8:16, i), [3, 3])
      w = rec(17:19, i)
      wb = MATMUL(TRANSPOSE(rot), w)
      e = 0.5_wp*MB*DOT_PRODUCT(rec(5:7, i), rec(5:7, i)) + 0.5_wp*DOT_PRODUCT(wb, IB*wb) + rec(23, i)
      IF (i == 0) e0 = e
      dev = MAX(dev, ABS(e - e0)/e0)
      amp = MAX(amp, NORM2(rec(2:4, i) - rec(2:4, 0)))
    END DO
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'energy gate: clamped cable on a free body, rhoInf 1, dtM 0.02 s, 10 s: '// &
      'max |E - E0|/E0 = ', dev, ' (body excursion ', amp, ' m)'
    CALL require(dev <= 5.0e-3_wp, 'clamped energy conserved to 0.5 %')
    CALL require(amp < 5.0_wp, 'clamped body motion stays bounded')
  END SUBROUTINE check_energy

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_moored_deck(path, conn, scheme, ic, tmax)
    !! A buoyant body (hydrostatic C44 = C55 = 2e6 N m/rad) on three EI=0 legs, with a finite-EI
    !! cable leaving its keel point at 45 deg towards a fixed anchor, End A connection conn.
    CHARACTER(*), INTENT(IN) :: path, conn, scheme, ic
    REAL(wp), INTENT(IN) :: tmax
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'clamped cable statics gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cab 0.2 60.0 5.0e8 -1.0 2.0e4 1.2 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0 0 -20 0 0 0 2.0e4 40.0 0.0 2.0e6 2.0e6 8.0 0.5 3.5e4 3.5e4 3.5e4'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '7 Body1 0.0 0.0 -3.0 0 0 0 0'
    WRITE (u, '(A)') '8 Fixed -40.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 4 -'
    WRITE (u, '(A)') '2 2 5 -'
    WRITE (u, '(A)') '3 3 6 -'
    WRITE (u, '(A)') '4 7 8 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 86.85 20'
    WRITE (u, '(A)') '2 poly 86.85 20'
    WRITE (u, '(A)') '3 poly 86.85 20'
    WRITE (u, '(A)') '4 cab 100.0 50'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A,A,A)') '4 A ', conn, ' -0.7071067811865476 0.0 -0.7071067811865476'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(ES12.5,A)') tmax, ' TMax'
    WRITE (u, '(A)') ic//' bodyIC'
    WRITE (u, '(A)') scheme//' bodyScheme'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px'
    WRITE (u, '(A)') 'Body1Pz'
    WRITE (u, '(A)') 'Body1Ry'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_moored_deck

  SUBROUTINE check_statics()
    REAL(wp) :: v0(4), v1(4), vp(4), drift, dpitch
    LOGICAL :: ok, okp
    CALL write_moored_deck('clamp_static.dat', 'Rigid', 'monolithic', 'static', 5.0_wp)
    CALL run_deck('clamp_static.dat', 'clamp_static', ok)
    IF (.NOT. ok) RETURN
    CALL read_row('clamp_static.out', 0, v0, ok)
    CALL read_row('clamp_static.out', 100, v1, okp)
    ok = ok .AND. okp
    CALL require(ok, 'clamped statics output readable')
    IF (.NOT. ok) RETURN
    drift = nan_max_abs(v1(2:3) - v0(2:3))
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'statics gate: clamped cable on a moored body, drift over 5 s ', drift, &
      ' m, pitch drift ', ABS(v1(4) - v0(4)), ' deg'
    CALL require(drift <= 1.0e-3_wp, 'clamped static equilibrium: body at rest in the dynamics (1 mm)')
    CALL require(ABS(v1(4) - v0(4)) <= 1.0e-3_wp, 'clamped static equilibrium: pitch at rest (1e-3 deg)')
    CALL write_moored_deck('clamp_static_pin.dat', 'Pinned', 'monolithic', 'static', 0.05_wp)
    CALL run_deck('clamp_static_pin.dat', 'clamp_static_pin', ok)
    IF (.NOT. ok) RETURN
    CALL read_row('clamp_static_pin.out', 0, vp, ok)
    IF (.NOT. ok) RETURN
    dpitch = v0(4) - vp(4)
    WRITE (*, '(A,F10.5,A,F10.5,A)') 'statics gate: pitch clamped ', v0(4), ' deg, pinned ', vp(4), ' deg'
    CALL require(ABS(dpitch) > 1.0e-3_wp, 'the clamp moment turns the body in statics')
  END SUBROUTINE check_statics

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_rod_deck(path, ez, ic, tmax)
    !! The moored rod spar (examples/rod_moored_spar.dat) with a finite-EI cable leaving its lower
    !! end (Rod1A) along the rod axis, clamped there, towards an anchor on the seabed.
    CHARACTER(*), INTENT(IN) :: path, ez, ic
    REAL(wp), INTENT(IN) :: tmax
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'clamped cable on a rod end'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cab 0.15 40.0 1.0e8 -1.0 5.0e3 1.2 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'spar 1.0 300.0 0.8 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 spar Free 0.2 0 -30 0.2 0 -20 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.2 0 -30 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 0.2 0 -20 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed 25.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -25.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed 0.0 30.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed 0.0 -30.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '7 Fixed 12.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 1 4 -'
    WRITE (u, '(A)') '3 2 5 -'
    WRITE (u, '(A)') '4 2 6 -'
    WRITE (u, '(A)') '5 1 7 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 31.95 16'
    WRITE (u, '(A)') '2 poly 31.95 16'
    WRITE (u, '(A)') '3 poly 42.40 20'
    WRITE (u, '(A)') '4 poly 42.40 20'
    WRITE (u, '(A)') '5 cab 30.0 30'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A,A)') '5 A Rigid ', ez
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.025 dtM'
    WRITE (u, '(ES12.5,A)') tmax, ' TMax'
    WRITE (u, '(A)') ic//' bodyIC'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1Px'
    WRITE (u, '(A)') 'Rod1Pz'
    WRITE (u, '(A)') 'Rod1Ry'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_rod_deck

  SUBROUTINE check_rod()
    !! A cable clamped to the lower end of a free rod: the static solve balances the connection
    !! moment, so the rod stays at rest in the dynamics.
    REAL(wp) :: v0(4), v1(4), drift
    LOGICAL :: ok, okp
    CALL write_rod_deck('clamp_rod.dat', '0.0 0.0 -1.0', 'static', 2.0_wp)
    CALL run_deck('clamp_rod.dat', 'clamp_rod', ok)
    IF (.NOT. ok) RETURN
    CALL read_row('clamp_rod.out', 0, v0, ok)
    CALL read_row('clamp_rod.out', 80, v1, okp)
    ok = ok .AND. okp
    CALL require(ok, 'clamped rod output readable')
    IF (.NOT. ok) RETURN
    drift = nan_max_abs(v1(2:3) - v0(2:3))
    WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'rod gate: cable clamped to a free rod end, drift over 2 s ', drift, &
      ' m, tilt drift ', ABS(v1(4) - v0(4)), ' deg'
    CALL require(drift <= 1.0e-3_wp .AND. ABS(v1(4) - v0(4)) <= 1.0e-3_wp, &
                 'clamped rod: at rest after its static solve')
  END SUBROUTINE check_rod

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_staggered_probe()
    !! The staggered scheme (pinned cable) refreshes the committed cable end force every step:
    !! the probe's end-force columns follow the moving body instead of keeping their t = 0 value.
    REAL(wp), ALLOCATABLE :: rec(:, :)
    LOGICAL :: ok
    INTEGER :: nlast
    CALL write_moored_deck('clamp_stag_pin.dat', 'Pinned', 'staggered', 'deck', 0.5_wp)
    CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp])
    CALL run_deck('clamp_stag_pin.dat', 'clamp_stag_pin', ok)
    CALL CD_Multibody_Probe_Get(rec)
    IF (.NOT. ok) RETURN
    CALL require(ALLOCATED(rec), 'staggered pinned-cable probe record')
    IF (.NOT. ALLOCATED(rec)) RETURN
    nlast = UBOUND(rec, 2)
    CALL require(ALL(IEEE_IS_FINITE(rec(27:29, :))), 'staggered probe end force is finite')
    CALL require(NORM2(rec(27:29, nlast) - rec(27:29, 0)) > 1.0e-6_wp*NORM2(rec(27:29, 0)), &
                 'staggered scheme: committed cable end force is refreshed after t = 0')
  END SUBROUTINE check_staggered_probe

  SUBROUTINE check_rejections()
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_moored_deck('clamp_staggered.dat', 'Rigid', 'staggered', 'deck', 0.1_wp)
    CALL run_deck('clamp_staggered.dat', 'clamp_staggered', ok, em)
    CALL require(.NOT. ok .AND. INDEX(em, 'needs bodyScheme monolithic') > 0, &
                 'staggered scheme with a clamped body end is rejected by name: '//TRIM(em))
    CALL write_rod_deck('clamp_rod_skew.dat', '0.6 0.0 -0.8', 'deck', 0.025_wp)
    CALL run_deck('clamp_rod_skew.dat', 'clamp_rod_skew', ok, em)
    CALL require(.NOT. ok .AND. INDEX(em, 'parallel to the rod axis') > 0, &
                 'a rod-end connection direction off the rod axis is rejected by name: '//TRIM(em))
  END SUBROUTINE check_rejections
END PROGRAM test_clamped_cable_ends
