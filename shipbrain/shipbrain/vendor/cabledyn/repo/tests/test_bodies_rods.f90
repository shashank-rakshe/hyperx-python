! File: tests/test_bodies_rods.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_bodies_rods
  !! Topology gates for rods fixed to bodies, pinned rods, decks without lines and rod-end line
  !! attachments (R<N>A/R<N>B):
  !!   1. a dry rod pinned at End A swings with the compound-pendulum period
  !!      4 sqrt(I_A/(m g L/2)) K(sin(theta0/2)), I_A = m (L^2/3 + d^2/16);
  !!   2. a Free body carrying a fixed surface-piercing rod and no lines floats at the draft
  !!      rhoW A draft = m_total and heaves with 2 pi sqrt(m_total/(rhoW g A)) (CaEnd = 0);
  !!   3. the same spar on a light vertical tether: the tether carries the net buoyancy, and the
  !!      Body<N>/Rod<N> channels report the body and rod on the line-coupled route;
  !!   4. a LINES row written with R1A/R1B equals the same deck with Rod1A/Rod1B POINT rows;
  !!   5. a short pinned rod at a step beyond its explicit swing limit sub-cycles it on a deck
  !!      without lines and on the staggered multibody march without an EI=0 line;
  !!   6. a pinned rod held by a stiff finite-EI cable on the staggered march sub-cycles the cable
  !!      spring, whose end force the march applies explicitly.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: RHO_W = 1025.0_wp, GRAV = 9.80665_wp
  INTEGER :: nfail

  nfail = 0
  CALL check_pinned_pendulum()
  CALL check_floating_spar()
  CALL check_moored_spar()
  CALL check_rod_end_tokens()
  CALL check_external_loads()
  CALL check_external_load_rows()
  CALL check_body_pinned_pendulum()
  CALL check_pinned_rod_with_line()
  CALL check_zero_length_rod()
  CALL check_mixed_rest()
  CALL check_lineless_substep()
  CALL check_cable_rod_substep()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' body/rod topology check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: bodies and rods (pinned rod, floating spar on a body, moored spar, R<N>A/B)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE run(path, root, ncol, dat, ok)
    CHARACTER(*), INTENT(IN) :: path, root
    INTEGER, INTENT(IN) :: ncol
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: dat(:, :)
    LOGICAL, INTENT(OUT) :: ok
    LOGICAL :: conv
    INTEGER :: es, u, ios, nrow, i
    CHARACTER(512) :: em
    CHARACTER(2048) :: buf
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    CALL require(ok, 'deck '//path//' converged: '//TRIM(em))
    IF (.NOT. ok) RETURN
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='OLD', ACTION='READ')
    nrow = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    nrow = nrow - 2
    ALLOCATE (dat(ncol, nrow))
    REWIND (u)
    READ (u, '(A)') buf
    READ (u, '(A)') buf
    DO i = 1, nrow
      READ (u, *) dat(:, i)
    END DO
    CLOSE (u)
    ok = ALL(IEEE_IS_FINITE(dat))
    CALL require(ok, 'finite output of '//path)
  END SUBROUTINE run

  REAL(wp) FUNCTION crossing_period(t, x) RESULT(period)
    REAL(wp), INTENT(IN) :: t(:), x(:)
    REAL(wp) :: xm, t0, t1, tc
    INTEGER :: i, n
    xm = SUM(x)/SIZE(x)
    n = 0
    t0 = 0.0_wp
    t1 = 0.0_wp
    DO i = 1, SIZE(x) - 1
      IF (x(i) - xm < 0.0_wp .AND. x(i + 1) - xm >= 0.0_wp) THEN
        tc = t(i) + (xm - x(i))*(t(i + 1) - t(i))/(x(i + 1) - x(i))
        IF (n == 0) t0 = tc
        t1 = tc
        n = n + 1
      END IF
    END DO
    period = -1.0_wp
    IF (n >= 3) period = (t1 - t0)/REAL(n - 1, wp)
  END FUNCTION crossing_period

  REAL(wp) FUNCTION ellip_k(k) RESULT(kk)
    !! Complete elliptic integral of the first kind by the arithmetic-geometric mean.
    REAL(wp), INTENT(IN) :: k
    REAL(wp) :: a, b, c
    INTEGER :: i
    a = 1.0_wp
    b = SQRT(1.0_wp - k*k)
    DO i = 1, 30
      c = 0.5_wp*(a + b)
      b = SQRT(a*b)
      a = c
    END DO
    kk = PI/(2.0_wp*a)
  END FUNCTION ellip_k

  SUBROUTINE check_pinned_pendulum()
    REAL(wp), PARAMETER :: L = 10.0_wp, D = 0.2_wp, TH0 = 30.0_wp
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: m, ia, t_ref, got, th, dt
    INTEGER :: u
    LOGICAL :: ok

    m = 50.0_wp*L
    ia = m*(L*L/3.0_wp + D*D/16.0_wp)
    th = TH0*PI/180.0_wp
    t_ref = 4.0_wp*SQRT(ia/(m*GRAV*0.5_wp*L))*ellip_k(SIN(0.5_wp*th))
    dt = t_ref/100.0_wp
    OPEN (NEWUNIT=u, FILE='bodrod_pendulum.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Dry rod pendulum pinned at End A'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pend 0.2 50 0 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A,ES22.14,A,ES22.14,A)') '1 pend Pinned 0 0 20 ', L*SIN(th), ' 0 ', 20.0_wp - L*COS(th), ' 4 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '100 WtrDpth'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(ES22.14,A)') dt, ' dtM'
    WRITE (u, '(ES22.14,A)') 5.0_wp*t_ref, ' TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1Px Rod1N4Px Rod1N4Pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL run('bodrod_pendulum.dat', 'bodrod_pendulum', 4, dat, ok)
    IF (.NOT. ok) RETURN
    got = crossing_period(dat(1, :), dat(3, :))
    WRITE (*, '(A,2F12.6)') 'pinned rod pendulum period got/analytic [s]: ', got, t_ref
    CALL require(ABS(got - t_ref) <= 1.0e-3_wp*t_ref, 'pinned rod pendulum period (elliptic integral)')
    CALL require(nan_max_abs(dat(2, :)) <= 1.0e-12_wp, 'pinned End A stays at the pin')
    CALL require(nan_max_abs(SQRT(dat(3, :)**2 + (dat(4, :) - 20.0_wp)**2) - L) <= 1.0e-5_wp, &
                 'pinned rod keeps its length about the pin')
  END SUBROUTINE check_pinned_pendulum

  SUBROUTINE write_spar(path, z0, body_ic, tether, ext)
    !! Free body at the waterline (2000 t, CG 30 m down) carrying a fixed rod d = 8 m from 60 m
    !! below to 10 m above the reference point (1000 kg/m, Ca 1, no end effects).
    CHARACTER(*), INTENT(IN) :: path, body_ic
    REAL(wp), INTENT(IN) :: z0
    LOGICAL, INTENT(IN) :: tether
    CHARACTER(*), INTENT(IN), OPTIONAL :: ext
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Spar: rod fixed to a Free body'
    IF (tether) THEN
      WRITE (u, '(A)') '--- LINE TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'teth 0.01 0.1 1.0e9 0.0 0.0 0.0 0.0 0.0 0.0'
    END IF
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'spar 8 1000 0 1 0 0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*'
    WRITE (u, '(A)') '(#) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)'
    WRITE (u, '(A,ES22.14,A)') '1 Free 0 0 ', z0, ' 0 0 0 2.0e6 0|0|-30 1.0e9|1.0e9|1.0e8 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 spar Body1 0 0 -60 0 0 10 35 -'
    IF (PRESENT(ext)) THEN
      WRITE (u, '(A)') '--- EXTERNAL LOADS ---'
      WRITE (u, '(A)') 'ID Object CSys Force Blin Bquad'
      WRITE (u, '(A)') ext
    END IF
    IF (tether) THEN
      WRITE (u, '(A)') '--- POINTS ---'
      WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A)') '1 Fixed 0 0 -100 0 0 0 0'
      WRITE (u, '(A)') '--- LINES ---'
      WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (-) (m) (-) (-)'
      WRITE (u, '(A)') '1 teth R1A 1 39.9 4 -'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '200 WtrDpth'
    WRITE (u, '(A)') body_ic//' bodyIC'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '40 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    IF (tether) THEN
      WRITE (u, '(A)') 'Body1Pz Rod1Pz Body1Ry FairTen1'
    ELSE
      WRITE (u, '(A)') 'Body1Pz Rod1Pz Body1Ry'
    END IF
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_spar

  SUBROUTINE check_floating_spar()
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: a, mtot, draft, t_ref, got
    LOGICAL :: ok
    a = 0.25_wp*PI*64.0_wp
    mtot = 2.0e6_wp + 70.0_wp*1000.0_wp
    draft = mtot/(RHO_W*a)
    CALL write_spar('bodrod_spar_static.dat', 0.0_wp, 'static', .FALSE.)
    CALL run('bodrod_spar_static.dat', 'bodrod_spar_static', 4, dat, ok)
    IF (ok) THEN
      WRITE (*, '(A,2F14.8)') 'floating spar on a body: rod bottom got/analytic [m]: ', dat(3, 1), -draft
      CALL require(ABS(dat(3, 1) + draft) <= 1.0e-6_wp, 'spar draft rho A draft = m_total')
    END IF
    t_ref = 2.0_wp*PI*SQRT(mtot/(RHO_W*GRAV*a))
    CALL write_spar('bodrod_spar_heave.dat', 60.0_wp - draft + 0.5_wp, 'deck', .FALSE.)
    CALL run('bodrod_spar_heave.dat', 'bodrod_spar_heave', 4, dat, ok)
    IF (ok) THEN
      got = crossing_period(dat(1, :), dat(2, :))
      WRITE (*, '(A,2F12.5)') 'floating spar heave period got/analytic [s]: ', got, t_ref
      CALL require(ABS(got - t_ref) <= 0.005_wp*t_ref, 'spar heave period 2 pi sqrt(m/(rho g A))')
    END IF
  END SUBROUTINE check_floating_spar

  SUBROUTINE check_moored_spar()
    !! Raised 0.5 m above its free-floating draft by the tether: the static tether tension is the
    !! extra buoyancy rhoW g A 0.5 m (less the tether's own share, far below the tolerance).
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: a, mtot, draft, ten_ref
    LOGICAL :: ok
    a = 0.25_wp*PI*64.0_wp
    mtot = 2.0e6_wp + 70.0_wp*1000.0_wp
    draft = mtot/(RHO_W*a)
    CALL write_spar('bodrod_spar_moored.dat', 60.0_wp - draft - 0.5_wp, 'static', .TRUE.)
    CALL run('bodrod_spar_moored.dat', 'bodrod_spar_moored', 5, dat, ok)
    IF (.NOT. ok) RETURN
    ten_ref = RHO_W*GRAV*a*(dat(3, 1) + draft)*(-1.0_wp)
    WRITE (*, '(A,2ES14.6)') 'moored spar tether tension got / rho g A (draft - free draft) [N]: ', dat(5, 1), ten_ref
    CALL require(ABS(dat(5, 1) - ten_ref) <= 1.0e-4_wp*ten_ref, 'tether carries the extra buoyancy')
    CALL require(nan_max_abs(dat(2, :) - dat(2, 1)) <= 1.0e-4_wp, 'moored spar holds its static pose')
    CALL require(ABS(dat(3, 1) - dat(2, 1) + 60.0_wp) <= 1.0e-5_wp, 'Rod1Pz follows the body')
  END SUBROUTINE check_moored_spar

  SUBROUTINE check_external_loads()
    !! EXTERNAL LOADS on the floating spar: a constant downward 1 MN force deepens the draft by
    !! F/(rhoW g A); linear heave damping B = 2 zeta sqrt(k M) (k = rhoW g A, M the total mass)
    !! gives the log decrement 2 pi zeta/sqrt(1 - zeta^2) (zeta = 0.05).
    REAL(wp), PARAMETER :: ZETA = 0.05_wp
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: a, mtot, draft, bdamp, pk(3), zeta_got, delta
    CHARACTER(64) :: row
    INTEGER :: i, n
    LOGICAL :: ok
    a = 0.25_wp*PI*64.0_wp
    mtot = 2.0e6_wp + 70.0_wp*1000.0_wp
    draft = mtot/(RHO_W*a)
    CALL write_spar('bodrod_ext_static.dat', 0.0_wp, 'static', .FALSE., '1 Body1 G 0|0|-1.0e6 0 0')
    CALL run('bodrod_ext_static.dat', 'bodrod_ext_static', 4, dat, ok)
    IF (ok) THEN
      WRITE (*, '(A,2F14.8)') 'external force: rod bottom got/analytic [m]: ', dat(3, 1), &
        -draft - 1.0e6_wp/(RHO_W*GRAV*a)
      CALL require(ABS(dat(3, 1) + draft + 1.0e6_wp/(RHO_W*GRAV*a)) <= 1.0e-6_wp, &
                   'constant external force deepens the draft by F/(rho g A)')
    END IF
    bdamp = 2.0_wp*ZETA*SQRT(RHO_W*GRAV*a*mtot)
    WRITE (row, '(ES21.14E2)') bdamp
    row = '1 Body1 L 0 0|0|'//TRIM(ADJUSTL(row))//' 0'
    CALL write_spar('bodrod_ext_damp.dat', 60.0_wp - draft + 0.5_wp, 'deck', .FALSE., TRIM(row))
    CALL run('bodrod_ext_damp.dat', 'bodrod_ext_damp', 4, dat, ok)
    IF (.NOT. ok) RETURN
    n = 0
    DO i = 2, SIZE(dat, 2) - 1
      IF (n == 3) EXIT
      IF (dat(2, i) > dat(2, i - 1) .AND. dat(2, i) >= dat(2, i + 1) .AND. dat(1, i) > 1.0_wp) THEN
        n = n + 1
        pk(n) = dat(2, i) - (60.0_wp - draft)
      END IF
    END DO
    CALL require(n == 3, 'three heave maxima')
    IF (n < 3) RETURN
    delta = 0.5_wp*LOG(pk(1)/pk(3))
    zeta_got = delta/SQRT(4.0_wp*PI*PI + delta*delta)
    WRITE (*, '(A,2F10.6)') 'external linear damping ratio got/set: ', zeta_got, ZETA
    CALL require(ABS(zeta_got - ZETA) <= 0.005_wp*ZETA, 'external linear damping log decrement')
  END SUBROUTINE check_external_loads

  SUBROUTINE check_external_load_rows()
    !! EXTERNAL LOADS row forms: the MoorDyn-F column order (ID Object Force Blin Bquad CSys)
    !! gives the same static draft as the CableDyn order; two rows on one body (one global,
    !! one body-frame) are summed; IDs must run 1, 2, ...; a Point3 body fails closed.
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: a, mtot, draft, zref
    LOGICAL :: ok
    CHARACTER(1) :: nl
    nl = NEW_LINE('a')
    a = 0.25_wp*PI*64.0_wp
    mtot = 2.0e6_wp + 70.0_wp*1000.0_wp
    draft = mtot/(RHO_W*a)
    zref = -draft - 1.0e6_wp/(RHO_W*GRAV*a)
    CALL write_spar('bodrod_ext_mdf.dat', 0.0_wp, 'static', .FALSE., '1 Body1 0|0|-1.0e6 0 0 G')
    CALL run('bodrod_ext_mdf.dat', 'bodrod_ext_mdf', 4, dat, ok)
    IF (ok) CALL require(ABS(dat(3, 1) - zref) <= 1.0e-6_wp, 'MoorDyn-F column order: same draft as F/(rho g A)')
    CALL write_spar('bodrod_ext_sum.dat', 0.0_wp, 'static', .FALSE., &
                    '1 Body1 G 0|0|-4.0e5 0 0'//nl//'2 Body1 0|0|-6.0e5 0 0 L')
    CALL run('bodrod_ext_sum.dat', 'bodrod_ext_sum', 4, dat, ok)
    IF (ok) CALL require(ABS(dat(3, 1) - zref) <= 1.0e-6_wp, 'two EXTERNAL LOADS rows (G + L) are summed')
    CALL write_spar('bodrod_ext_id.dat', 0.0_wp, 'static', .FALSE., '2 Body1 G 0|0|-1.0e6 0 0')
    CALL expect_reject('bodrod_ext_id.dat', 'sequential starting from 1', 'EXTERNAL LOADS ID not starting at 1')
    CALL write_spar('bodrod_ext_csys.dat', 0.0_wp, 'static', .FALSE., '1 Body1 0|0|-1.0e6 0 0 0')
    CALL expect_reject('bodrod_ext_csys.dat', 'CSys letter', 'EXTERNAL LOADS row without a CSys column')
    CALL write_point3_ext('bodrod_ext_point3.dat')
    CALL expect_reject('bodrod_ext_point3.dat', 'EXTERNAL LOADS apply to Rigid6 bodies only; Body1 is a Point3 body', &
                       'EXTERNAL LOADS on a Point3 body')
  END SUBROUTINE check_external_load_rows

  SUBROUTINE expect_reject(path, fragment, label)
    CHARACTER(*), INTENT(IN) :: path, fragment, label
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL CD_Run_Deck_Driver(path, path//'.tmp', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, fragment) > 0, label//' fails closed: '//TRIM(em))
  END SUBROUTINE expect_reject

  SUBROUTINE write_point3_ext(path)
    !! A Point3 buoy on one line, with an EXTERNAL LOADS row on the buoy.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Point3 buoy with an external load'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-)'
    WRITE (u, '(A)') '1 Point3 1.0 0.0 -0.5 0.0 0.0 0.0 20.0 0.0195121951 0.0 0.0 0.0 2.0 1.0'
    WRITE (u, '(A)') '--- EXTERNAL LOADS ---'
    WRITE (u, '(A)') 'ID Object Force Blin Bquad CSys'
    WRITE (u, '(A)') '1 Body1 0|0|-10 0 0 G'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_point3_ext

  SUBROUTINE write_rod_deck(path, tokens, rod_type)
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: tokens
    CHARACTER(*), INTENT(IN), OPTIONAL :: rod_type   ! the RODS Type column (default Free)
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Spar rod on four legs'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'spar 1.0 300.0 0.8 1.0 0.6 0.6'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    IF (PRESENT(rod_type)) THEN
      WRITE (u, '(A)') '1 spar '//rod_type//' 0 0 -30 0 0 -20 4 -'
    ELSE
      WRITE (u, '(A)') '1 spar Free 0 0 -30 0 0 -20 4 -'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    IF (.NOT. tokens) THEN
      WRITE (u, '(A)') '7 Rod1A 0 0 0 0 0 0 0'
      WRITE (u, '(A)') '8 Rod1B 0 0 0 0 0 0 0'
    END IF
    WRITE (u, '(A)') '3 Fixed 25 0 -50 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -25 0 -50 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed 0 30 -50 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed 0 -30 -50 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-) (m) (-) (-)'
    IF (tokens) THEN
      WRITE (u, '(A)') '1 poly R1A 3 31.95 8 -'
      WRITE (u, '(A)') '2 poly R1A 4 31.95 8 -'
      WRITE (u, '(A)') '3 poly R1B 5 42.40 8 -'
      WRITE (u, '(A)') '4 poly R1B 6 42.40 8 -'
    ELSE
      WRITE (u, '(A)') '1 poly 7 3 31.95 8 -'
      WRITE (u, '(A)') '2 poly 7 4 31.95 8 -'
      WRITE (u, '(A)') '3 poly 8 5 42.40 8 -'
      WRITE (u, '(A)') '4 poly 8 6 42.40 8 -'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '50 WtrDpth'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '4 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen3 Rod1Px Rod1Pz Rod1N4Pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_rod_deck

  SUBROUTINE check_rod_end_tokens()
    REAL(wp), ALLOCATABLE :: a(:, :), b(:, :)
    LOGICAL :: ok1, ok2
    ! MoorDyn CoupledPinned/VesselPinned rods need a coupled host: the standalone driver refuses
    ! them by name
    CALL write_rod_deck('bodrod_cpldpin.dat', .TRUE., 'CoupledPinned')
    CALL expect_reject('bodrod_cpldpin.dat', 'CoupledPinned/VesselPinned ROD requires a coupled host', &
                       'a CoupledPinned rod')
    CALL write_rod_deck('bodrod_tokens.dat', .TRUE.)
    CALL write_rod_deck('bodrod_points.dat', .FALSE.)
    CALL run('bodrod_tokens.dat', 'bodrod_tokens', 6, a, ok1)
    CALL run('bodrod_points.dat', 'bodrod_points', 6, b, ok2)
    IF (.NOT. (ok1 .AND. ok2)) RETURN
    CALL require(SIZE(a, 2) == SIZE(b, 2), 'R<N>A/B deck has the POINT-row deck''s rows')
    IF (SIZE(a, 2) /= SIZE(b, 2)) RETURN
    CALL require(nan_max_abs(a - b) <= 0.0_wp, 'R1A/R1B line ends equal Rod1A/Rod1B POINT rows')
    CALL require(ABS(b(6, 1) - b(5, 1) - 10.0_wp) <= 1.0e-6_wp, 'Rod1N4Pz is End B')
  END SUBROUTINE check_rod_end_tokens

  SUBROUTINE check_body_pinned_pendulum()
    !! A rod pinned to a body (Body1Pinned) on a body 1e8 times heavier, held up by its (MoorDyn,
    !! always wet) buoyancy, swings with the fixed-pin compound-pendulum period; the body stays.
    REAL(wp), PARAMETER :: L = 10.0_wp, D = 0.2_wp, TH0 = 30.0_wp
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: m, ia, t_ref, got, th, dt
    INTEGER :: u
    LOGICAL :: ok
    m = 50.0_wp*L
    ia = m*(L*L/3.0_wp + D*D/16.0_wp)
    th = TH0*PI/180.0_wp
    t_ref = 4.0_wp*SQRT(ia/(m*GRAV*0.5_wp*L))*ellip_k(SIN(0.5_wp*th))
    dt = t_ref/100.0_wp
    OPEN (NEWUNIT=u, FILE='bodrod_bodypin.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Dry rod pinned to a heavy body'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pend 0.2 50 0 0 0 0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*'
    WRITE (u, '(A)') '(#) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)'
    WRITE (u, '(A,ES22.14,A)') '1 Free 5 0 20 0 0 0 5.0e10 0 1.0e13 ', (5.0e10_wp + m)/RHO_W, ' 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A,ES22.14,A,ES22.14,A)') '1 pend Body1Pinned 0 0 0 ', L*SIN(th), ' 0 ', -L*COS(th), ' 4 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '100 WtrDpth'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') 'moordyn bodyWetting'
    WRITE (u, '(ES22.14,A)') dt, ' dtM'
    WRITE (u, '(ES22.14,A)') 5.0_wp*t_ref, ' TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1Px Rod1N4Px Rod1N4Pz Body1Pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL run('bodrod_bodypin.dat', 'bodrod_bodypin', 5, dat, ok)
    IF (.NOT. ok) RETURN
    got = crossing_period(dat(1, :), dat(3, :))
    WRITE (*, '(A,2F12.6)') 'rod pinned to a heavy body: period got/analytic [s]: ', got, t_ref
    CALL require(ABS(got - t_ref) <= 1.0e-3_wp*t_ref, 'body-pinned rod pendulum period (elliptic integral)')
    CALL require(nan_max_abs(dat(2, :) - 5.0_wp) <= 1.0e-5_wp, 'the pin stays on the heavy body')
    CALL require(nan_max_abs(SQRT((dat(3, :) - 5.0_wp)**2 + (dat(4, :) - 20.0_wp)**2) - L) <= 1.0e-5_wp, &
                 'body-pinned rod keeps its length about the pin')
  END SUBROUTINE check_body_pinned_pendulum

  SUBROUTINE write_pinned_line_deck(path)
    !! A heavy submerged rod pinned at End A, pulled sideways at End B by a taut line.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Pinned rod carrying a line'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'arm 0.5 800 1.0 1.0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 arm Pinned 0 0 -20 0 0 -30 5 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 40 0 -40 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-) (m) (-) (-)'
    WRITE (u, '(A)') '1 poly R1B 1 37.5 10 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '60 WtrDpth'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '3 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1N5Px Rod1N5Pz FairTen1 Rod1TenB Rod1TenA Rod1Mx Rod1My Rod1Mz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_pinned_line_deck

  SUBROUTINE check_pinned_rod_with_line()
    !! The static solve turns a pinned rod about its pin to the balance of its weight and the
    !! line; the march then stays at rest, the line force on End B is Rod1TenB, and the rod's
    !! moment about the pin (End A, where the pin reaction acts) vanishes: Rod1M is the moment
    !! of every load but the pin's.
    REAL(wp), ALLOCATABLE :: dat(:, :)
    LOGICAL :: ok
    CALL write_pinned_line_deck('bodrod_pinline.dat')
    CALL run('bodrod_pinline.dat', 'bodrod_pinline', 9, dat, ok)
    IF (.NOT. ok) RETURN
    WRITE (*, '(A,3ES12.4)') 'pinned rod with a line: End B x, drift, |M_A| [m, m, N m]: ', dat(2, 1), &
      nan_max_abs(dat(2, :) - dat(2, 1)), nan_max_abs(dat(7:9, 1))
    CALL require(dat(2, 1) > 1.0_wp, 'the line turns the pinned rod toward its anchor')
    CALL require(nan_max_abs(dat(2, :) - dat(2, 1)) <= 1.0e-4_wp .AND. &
                 nan_max_abs(dat(3, :) - dat(3, 1)) <= 1.0e-4_wp, 'pinned rod with a line starts at rest')
    CALL require(ABS(dat(5, 1) - dat(4, 1)) <= 1.0e-9_wp*dat(4, 1), 'Rod1TenB is the line force on End B')
    CALL require(ABS(dat(6, 1)) <= 0.0_wp, 'no line on End A: Rod1TenA = 0')
    CALL require(nan_max_abs(dat(7:9, 1)) <= 1.0e-6_wp*dat(4, 1)*10.0_wp, &
                 'static moment about the pin vanishes (Rod1M)')
  END SUBROUTINE check_pinned_rod_with_line

  SUBROUTINE write_junction_deck(path, zero_length_rod)
    !! Two lines joined at a massless junction: a Free point, or a zero-length free rod.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: zero_length_rod
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Two lines joined at a junction'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.10 20.0 5.0e8 -1.0 0.0 1.2 0.4 1.0 0.0'
    IF (zero_length_rod) THEN
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'knot 0.3 100 1.0 1.0 0.6 0.6'
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      WRITE (u, '(A)') '1 knot Free 0 0 -40 0 0 -40 0 -'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed -40 0 -60 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 45 0 -20 0 0 0 0'
    IF (.NOT. zero_length_rod) WRITE (u, '(A)') '3 Free 0 0 -40 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-) (m) (-) (-)'
    IF (zero_length_rod) THEN
      WRITE (u, '(A)') '1 chain R1A 1 46 10 -'
      WRITE (u, '(A)') '2 chain 2 R1B 52 10 -'
    ELSE
      WRITE (u, '(A)') '1 chain 3 1 46 10 -'
      WRITE (u, '(A)') '2 chain 2 3 52 10 -'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '70 WtrDpth'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '2 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen2 FairTen2'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_junction_deck

  SUBROUTINE check_zero_length_rod()
    !! A zero-length free rod (NumSegs 0) joining two lines is the massless Free point junction
    !! (MoorDyn: no mass, volume or side loads, and no axis for its end terms).
    REAL(wp), ALLOCATABLE :: a(:, :), b(:, :)
    LOGICAL :: ok1, ok2
    CALL write_junction_deck('bodrod_zl_rod.dat', .TRUE.)
    CALL write_junction_deck('bodrod_zl_point.dat', .FALSE.)
    CALL run('bodrod_zl_rod.dat', 'bodrod_zl_rod', 4, a, ok1)
    CALL run('bodrod_zl_point.dat', 'bodrod_zl_point', 4, b, ok2)
    IF (.NOT. (ok1 .AND. ok2)) RETURN
    CALL require(SIZE(a, 2) == SIZE(b, 2), 'zero-length rod deck has the point deck''s rows')
    IF (SIZE(a, 2) /= SIZE(b, 2)) RETURN
    WRITE (*, '(A,ES12.4)') 'zero-length rod vs Free point junction: max |dT| [N]: ', nan_max_abs(a - b)
    CALL require(nan_max_abs(a - b) <= 1.0e-9_wp*nan_max_abs(b), 'zero-length free rod equals a massless Free point')
  END SUBROUTINE check_zero_length_rod

  SUBROUTINE check_mixed_rest()
    !! A mixed deck (Free body with a fixed and a pinned rod, taut EI=0 legs, a chain through a
    !! Free point, a finite-EI cable) starts at its static equilibrium: it stays at rest, the net
    !! external load on the body (Body1F/M) vanishes, and Point<P>F of the cable anchor equals
    !! the cable's AnchTen.
    REAL(wp), ALLOCATABLE :: dat(:, :)
    REAL(wp) :: w
    INTEGER :: u
    LOGICAL :: ok
    OPEN (NEWUNIT=u, FILE='bodrod_mixed.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Mixed topology at rest'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'nylon 0.124 13.76 2.515288e6 -0.8 0 1.6 0.05 1.0 0'
    WRITE (u, '(A)') 'chain 0.1 20 5.0e8 -0.8 0 1.2 0.4 1.0 0'
    WRITE (u, '(A)') 'cable 0.15 30 5.0e8 -0.8 1.0e4 1.2 0.01 1.0 0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'can 2 1500 0.8 1.0 0 0'
    WRITE (u, '(A)') 'arm 0.5 600 1.0 1.0 0 0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*'
    WRITE (u, '(A)') '(#) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Free 0 0 -15 0 0 0 1.5e5 0 2e6 160 20|0 0.5'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 can Body1 0 0 2 0 0 8 4 -'
    WRITE (u, '(A)') '2 arm Body1Pinned 0 0 -2 0 0 -12 5 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 3 0 0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -1.5 2.598 0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 -1.5 -2.598 0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 150 0 -70 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -75 129.9 -70 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -75 -129.9 -70 0 0 0 0'
    WRITE (u, '(A)') '7 Fixed -60 0 -70 0 0 0 0'
    WRITE (u, '(A)') '8 Free -30 0 -45 100 1.0 0 0'
    WRITE (u, '(A)') '9 Body1 -2 0 -2 0 0 0 0'
    WRITE (u, '(A)') '10 Fixed 0 0 -70 0 0 0 0'
    WRITE (u, '(A)') '11 Body1 0 3 -2 0 0 0 0'
    WRITE (u, '(A)') '12 Fixed 0 60 -70 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-) (m) (-) (-)'
    WRITE (u, '(A)') '1 nylon 1 4 150 20 -'
    WRITE (u, '(A)') '2 nylon 2 5 150 20 -'
    WRITE (u, '(A)') '3 nylon 3 6 150 20 -'
    WRITE (u, '(A)') '4 chain 8 7 40 10 -'
    WRITE (u, '(A)') '5 chain 9 8 45 10 -'
    WRITE (u, '(A)') '6 nylon R2B 10 42 8 -'
    WRITE (u, '(A)') '7 cable 11 12 90 30 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '70 WtrDpth'
    WRITE (u, '(A)') 'moordyn bodyWetting'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '2 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px Body1Pz Rod2N5Px Body1Fx Body1Fy Body1Fz Body1Mx Body1My Body1Mz AnchTen7 Point12FH '// &
      'Point12Fz Rod2TenB FairTen6'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL run('bodrod_mixed.dat', 'bodrod_mixed', 15, dat, ok)
    IF (.NOT. ok) RETURN
    w = 1.5e5_wp*GRAV
    WRITE (*, '(A,3ES12.4)') 'mixed deck at rest: drift, max |Body1F| / weight, max |Body1M| / (weight x 3 m): ', &
      nan_max_abs(dat(2:4, :) - SPREAD(dat(2:4, 1), 2, SIZE(dat, 2))), nan_max_abs(dat(5:7, 1))/w, &
      nan_max_abs(dat(8:10, 1))/(3.0_wp*w)
    CALL require(nan_max_abs(dat(2:4, :) - SPREAD(dat(2:4, 1), 2, SIZE(dat, 2))) <= 5.0e-3_wp, &
                 'mixed deck starts at rest (body and pinned rod)')
    CALL require(nan_max_abs(dat(5:7, 1)) <= 2.0e-3_wp*w .AND. nan_max_abs(dat(8:10, 1)) <= 2.0e-3_wp*3.0_wp*w, &
                 'net external load on the body vanishes at its static equilibrium')
    CALL require(ABS(SQRT(dat(12, 1)**2 + dat(13, 1)**2) - dat(11, 1)) <= 1.0e-9_wp*dat(11, 1), &
                 'cable anchor Point<P>F equals AnchTen')
    CALL require(ABS(dat(14, 1) - dat(15, 1)) <= 1.0e-9_wp*dat(15, 1), 'Rod2TenB is the tether''s FairTen')
  END SUBROUTINE check_mixed_rest

  SUBROUTINE write_short_pendulum(path, dt, with_cable)
    !! A dry 1 m rod (50 kg/m) pinned at End A at (0, 0, 20) and released at 30 degrees, on a deck
    !! without lines, or (with_cable) on the staggered multibody march beside an independent
    !! finite-EI cable hung from a Fixed rod to an anchor (no EI=0 line, so no line spring reaches
    !! the pinned rod).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: dt
    LOGICAL, INTENT(IN) :: with_cable
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Short dry rod pendulum pinned at End A'
    IF (with_cable) THEN
      WRITE (u, '(A)') '--- LINE TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'cable 0.15 30 5.0e8 -0.8 1.0e4 1.2 0.01 1.0 0'
    END IF
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pend 0.2 50 0 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A,ES22.14,A,ES22.14,A)') '1 pend Pinned 0 0 20 ', 0.5_wp, ' 0 ', 20.0_wp - SQRT(0.75_wp), ' 4 -'
    IF (with_cable) WRITE (u, '(A)') '2 pend Fixed 10 0 -55 10 0 -57 2 -'
    IF (with_cable) THEN
      WRITE (u, '(A)') '--- POINTS ---'
      WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A)') '1 Fixed 40 0 -60 0 0 0 0'
      WRITE (u, '(A)') '--- LINES ---'
      WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (-) (m) (-) (-)'
      WRITE (u, '(A)') '1 cable R2B 1 35 10 -'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '70 WtrDpth'
    WRITE (u, '(A)') 'deck bodyIC'
    IF (with_cable) WRITE (u, '(A)') 'staggered bodyScheme'
    WRITE (u, '(ES22.14,A)') dt, ' dtM'
    WRITE (u, '(A)') '18 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1N4Px Rod1N4Pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_short_pendulum

  SUBROUTINE check_lineless_substep()
    !! A 1 m dry pinned rod swings with omega0^2 = m g (L/2)/I_A, about 14.6 rad^2/s^2, so a 0.6 s
    !! step (omega0 dt = 2.29) is beyond the explicit limit of 2 for any line-free march: the deck
    !! without lines, and the staggered multibody march whose only line is a finite-EI cable,
    !! must take 6 sub-steps (omega0 dt/0.4 = 5.73) from the rod's own swing. Each run must
    !! reproduce a run at the sub-step size at every 0.6 s output row (to the printed digits),
    !! stay within its release angle and keep the elliptic-integral period to the accuracy of
    !! omega0 dt_sub of about 0.38 (near (omega dt)^2/24 = 0.6 %).
    REAL(wp), PARAMETER :: TH0 = 30.0_wp
    REAL(wp), ALLOCATABLE :: dc(:, :), df(:, :)
    REAL(wp) :: ia, t_ref, got, err, amp
    INTEGER :: kase, i, nc
    LOGICAL :: ok
    CHARACTER(16) :: tag

    ia = 50.0_wp*(1.0_wp/3.0_wp + 0.2_wp**2/16.0_wp)
    t_ref = 4.0_wp*SQRT(ia/(50.0_wp*GRAV*0.5_wp))*ellip_k(SIN(0.5_wp*TH0*PI/180.0_wp))
    DO kase = 1, 2
      tag = MERGE('no lines        ', 'staggered, cable', kase == 1)
      CALL write_short_pendulum('bodrod_short_c.dat', 0.6_wp, kase == 2)
      CALL run('bodrod_short_c.dat', 'bodrod_short_c', 3, dc, ok)
      IF (.NOT. ok) RETURN
      CALL write_short_pendulum('bodrod_short_f.dat', 0.1_wp, kase == 2)
      CALL run('bodrod_short_f.dat', 'bodrod_short_f', 3, df, ok)
      IF (.NOT. ok) RETURN
      nc = SIZE(dc, 2)
      err = 0.0_wp
      DO i = 1, nc
        err = MAX(err, nan_max_abs(dc(2:3, i) - df(2:3, 6*(i - 1) + 1)))
      END DO
      amp = MAX(nan_max_abs(dc(2, :)), nan_max_abs(df(2, :)))
      got = crossing_period(df(1, :), df(2, :))
      WRITE (*, '(A,A,A,ES10.3,A,F8.5,A,2F10.6)') 'short pinned rod at a 0.6 s step (', TRIM(tag), &
        '): vs 0.1 s run ', err, ' m; max End B x/release ', amp/0.5_wp, '; period got/analytic [s] ', got, t_ref
      CALL require(nc == 31 .AND. SIZE(df, 2) == 181, 'short pendulum: output rows ('//TRIM(tag)//')')
      CALL require(err <= 1.0e-6_wp, 'short pendulum: 0.6 s step equals its 0.1 s sub-step run ('//TRIM(tag)//')')
      CALL require(amp <= 1.02_wp*0.5_wp, 'short pendulum: the swing stays within its release ('//TRIM(tag)//')')
      CALL require(ABS(got - t_ref) <= 1.5e-2_wp*t_ref, 'short pendulum: period ('//TRIM(tag)//')')
    END DO
  END SUBROUTINE check_lineless_substep

  SUBROUTINE write_cable_rod(path, dt)
    !! A heavy 1 m rod (D = 0.3 m, 500 kg/m) hanging from a pin at (0, 0, -20), its End B held by
    !! a 20 m neutrally buoyant finite-EI cable (EA 1e7 N, EI 10 N m^2) to an anchor along x at
    !! 100 N of pretension, on the staggered multibody march (no EI=0 line).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: dt
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Pinned rod held by a stiff finite-EI cable'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') 'tcable 0.05 ', RHO_W*0.25_wp*PI*0.05_wp**2, ' 1.0e7 -0.8 10.0 1.2 0.01 1.0 0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'heavy 0.3 500 0 0 0 0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 heavy Pinned 0 0 -20 0 0 -21 4 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 20 0 -21 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID LineType AttachA AttachB UnstrLen NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-) (m) (-) (-)'
    WRITE (u, '(A,ES24.16,A)') '1 tcable R1B 1 ', 20.0_wp*(1.0_wp - 1.0e-5_wp), ' 10 -'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '70 WtrDpth'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') 'staggered bodyScheme'
    WRITE (u, '(ES22.14,A)') dt, ' dtM'
    WRITE (u, '(A)') '2 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Rod1N4Px Rod1N4Pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_cable_rod

  SUBROUTINE check_cable_rod_substep()
    !! The cable's axial stiffness EA/L = 5e5 N/m acts at the 1 m arm against the rod's inertia
    !! about its pin (about 170 kg m^2): omega^2 about 3e3 rad^2/s^2, against about 14 from the
    !! rod's net weight, so a 0.05 s step (omega dt = 2.7) needs sub-steps that only the cable
    !! spring of the estimate asks for (the staggered march returns the cable end force
    !! explicitly). The rod must stay near its pose (End B within 0.1 m) and end within 1 cm of
    !! a run at dtM = 0.005 s.
    REAL(wp), ALLOCATABLE :: dc(:, :), df(:, :)
    REAL(wp) :: dev, err
    LOGICAL :: ok
    CALL write_cable_rod('bodrod_cable_c.dat', 0.05_wp)
    CALL run('bodrod_cable_c.dat', 'bodrod_cable_c', 3, dc, ok)
    IF (.NOT. ok) RETURN
    CALL write_cable_rod('bodrod_cable_f.dat', 0.005_wp)
    CALL run('bodrod_cable_f.dat', 'bodrod_cable_f', 3, df, ok)
    IF (.NOT. ok) RETURN
    dev = nan_max_abs(dc(2, :))
    err = nan_max_abs(dc(2:3, SIZE(dc, 2)) - df(2:3, SIZE(df, 2)))
    WRITE (*, '(A,ES10.3,A,ES10.3)') 'pinned rod on a stiff cable at a 0.05 s step: max |End B x| ', dev, &
      ' m; end vs dtM/10 ', err
    CALL require(dev <= 0.1_wp, 'cable rod: End B stays near its pose (cable spring sub-steps)')
    CALL require(err <= 1.0e-2_wp, 'cable rod: ends as the dtM/10 run')
  END SUBROUTINE check_cable_rod_substep
END PROGRAM test_bodies_rods
