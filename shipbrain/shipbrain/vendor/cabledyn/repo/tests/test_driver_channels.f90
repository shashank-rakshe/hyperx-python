! File: tests/test_driver_channels.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_driver_channels
  !! Gate for the OrcaFlex line output channels in the standalone `cabledyn` deck driver:
  !! curvature, bend moment, node declination / azimuth (incl. the fairlead / anchor
  !! angles), node acceleration, the nodal `.static.out` profile, and continuous
  !! element extrema in `.elements.out`.
  !!
  !! Correctness is checked two ways:
  !!   (1) the production geometry helpers (line_geom_value / menger_curvature /
  !!       tangent_declination_deg / tangent_azimuth_deg) are exercised on HAND-PLACED
  !!       circular-arc and known-tangent geometry -> exact 1/R, EI/R, and angles;
  !!   (2) end-to-end decks are run through CD_Run_Deck_Driver and each derived channel
  !!       is cross-checked against the position channels reported in the SAME file with
  !!       an INDEPENDENT reimplementation of the formula (so the wiring, node mapping,
  !!       and EI resolution are all verified, not just column presence).
  !! Plus: acceleration is exactly 0.0 on a static run and non-zero on a driven dynamic
  !! run; the `.static.out` file parses as a header+units+data table whose curvature
  !! column matches the analytic value; and every bad channel token fails closed.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, line_geom_value, menger_curvature, &
                                 tangent_declination_deg, tangent_azimuth_deg, &
                                 circumcircle_curvature_vector, &
                                 CD_DECKDRV_OK, CD_DECKDRV_BADINPUT
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DEG = 57.29577951308232087680_wp     ! 180/pi (independent of the module const)
  INTEGER :: nfail

  nfail = 0

  CALL test_geometry_helpers()
  CALL test_static_channels()
  CALL test_static_config_file()
  CALL test_finite_dynamic_channels()
  CALL test_finite_straight_bendmom()
  CALL test_motion_accel_channels()
  CALL test_fail_closed()
  CALL test_azimuth_ranges()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: cabledyn OrcaFlex output channels (curvature/bend/angles/accel + static.out)'

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

  LOGICAL FUNCTION exact(a, b) RESULT(same)
    !! a equals b bit for bit (order comparisons, which -Wcompare-reals accepts).
    REAL(wp), INTENT(IN) :: a, b
    same = .NOT. (a < b .OR. a > b)
  END FUNCTION exact

  ! ---- independent reference geometry (NOT the production code) ----

  REAL(wp) FUNCTION ref_curv(p1, p2, p3) RESULT(k)
    REAL(wp), INTENT(IN) :: p1(3), p2(3), p3(3)
    REAL(wp) :: u(3), w(3), cr(3), den
    u = p2 - p1
    w = p3 - p1
    cr = [u(2)*w(3) - u(3)*w(2), u(3)*w(1) - u(1)*w(3), u(1)*w(2) - u(2)*w(1)]
    den = NORM2(u)*NORM2(w)*NORM2(w - u)
    k = 0.0_wp
    IF (den > 0.0_wp) k = 2.0_wp*NORM2(cr)/den
  END FUNCTION ref_curv

  REAL(wp) FUNCTION ref_dec(t) RESULT(d)
    REAL(wp), INTENT(IN) :: t(3)
    REAL(wp) :: n
    n = NORM2(t)
    d = 0.0_wp
    IF (n > 0.0_wp) d = ACOS(MAX(-1.0_wp, MIN(1.0_wp, t(3)/n)))*DEG
  END FUNCTION ref_dec

  REAL(wp) FUNCTION ref_azi(t) RESULT(a)
    REAL(wp), INTENT(IN) :: t(3)
    a = 0.0_wp
    IF (ABS(t(1)) > 0.0_wp .OR. ABS(t(2)) > 0.0_wp) a = ATAN2(t(2), t(1))*DEG
    IF (a < 0.0_wp) a = a + 360.0_wp
  END FUNCTION ref_azi

  ! ---- Geometry helpers on hand-computed geometry ----

  SUBROUTINE test_geometry_helpers()
    REAL(wp), PARAMETER :: R = 10.0_wp
    REAL(wp) :: p1(3), p2(3), p3(3), q(15), phi, c, kv(3)
    INTEGER :: i, dn

    ! menger_curvature of three points on a circle of radius R is exactly 1/R.
    p1 = [R, 0.0_wp, 0.0_wp]
    p2 = [R*COS(0.3_wp), 0.0_wp, R*SIN(0.3_wp)]
    p3 = [R*COS(0.6_wp), 0.0_wp, R*SIN(0.6_wp)]
    CALL require(ABS(menger_curvature(p1, p2, p3) - 1.0_wp/R) < 1.0e-10_wp, 'menger curvature = 1/R on a circle')
    CALL require(menger_curvature([0.0_wp, 0.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], &
                                  [2.0_wp, 0.0_wp, 0.0_wp]) < 1.0e-12_wp, 'menger curvature = 0 for collinear points')

    ! declination (angle from +GZ) on known tangents.
    CALL require(ABS(tangent_declination_deg([0.0_wp, 0.0_wp, 1.0_wp]) - 0.0_wp) < 1.0e-10_wp, 'declination up = 0 deg')
    CALL require(ABS(tangent_declination_deg([0.0_wp, 0.0_wp, -1.0_wp]) - 180.0_wp) < 1.0e-10_wp, &
                 'declination down = 180 deg')
    CALL require(ABS(tangent_declination_deg([1.0_wp, 0.0_wp, 0.0_wp]) - 90.0_wp) < 1.0e-10_wp, &
                 'declination horiz = 90 deg')
    CALL require(ABS(tangent_declination_deg([1.0_wp, 0.0_wp, 1.0_wp]) - 45.0_wp) < 1.0e-10_wp, 'declination 45 deg')

    ! azimuth (from +GX toward +GY), reported in [0,360).
    CALL require(ABS(tangent_azimuth_deg([1.0_wp, 0.0_wp, 0.0_wp]) - 0.0_wp) < 1.0e-10_wp, 'azimuth +x = 0 deg')
    CALL require(ABS(tangent_azimuth_deg([0.0_wp, 1.0_wp, 0.0_wp]) - 90.0_wp) < 1.0e-10_wp, 'azimuth +y = 90 deg')
    CALL require(ABS(tangent_azimuth_deg([1.0_wp, 1.0_wp, 0.0_wp]) - 45.0_wp) < 1.0e-10_wp, 'azimuth +x+y = 45 deg')
    CALL require(ABS(tangent_azimuth_deg([-1.0_wp, 0.0_wp, 0.0_wp]) - 180.0_wp) < 1.0e-10_wp, 'azimuth -x = 180 deg')
    CALL require(ABS(tangent_azimuth_deg([0.0_wp, -1.0_wp, 0.0_wp]) - 270.0_wp) < 1.0e-10_wp, 'azimuth -y = 270 deg')

    ! line_geom_value on a 5-node circular arc (internal order); curvature = 1/R at every
    ! interior deck node, and bend moment = EI * (1/R) with a homogeneous EI.
    DO i = 1, 5
      phi = 0.2_wp + REAL(i - 1, wp)*0.25_wp
      q(3*i - 2) = R*COS(phi)
      q(3*i - 1) = 0.0_wp
      q(3*i) = R*SIN(phi)
    END DO
    DO dn = 2, 4
      c = line_geom_value(5, dn, 5, q, 3)
      CALL require(ABS(c - 1.0_wp/R) < 1.0e-9_wp, 'line_geom_value curvature = 1/R on arc')
    END DO
    ! Reference-relative bend moment machinery. The finite-EI channel is
    ! BendMom = EI * |kvec_current - kvec_reference|, so a cable at its reference reports 0
    ! and a straight reference (kvec_reference = 0) reduces to EI * geometric curvature.
    kv = circumcircle_curvature_vector(p1, p2, p3)
    CALL require(ABS(NORM2(kv) - 1.0_wp/R) < 1.0e-10_wp, 'curvature-vector magnitude = 1/R')
    ! direction: for a circle centred at the origin the curvature vector at p2 points toward
    ! the origin, i.e. antiparallel to p2.
    CALL require(NORM2(kv/NORM2(kv) + p2/NORM2(p2)) < 1.0e-10_wp, 'curvature vector points toward the centre')
    ! a straight (collinear) reference contributes zero curvature vector.
    CALL require(NORM2(circumcircle_curvature_vector([0.0_wp, 0.0_wp, 0.0_wp], [1.0_wp, 0.0_wp, 0.0_wp], &
                                                     [2.0_wp, 0.0_wp, 0.0_wp])) < 1.0e-12_wp, &
                 'straight reference -> zero curvature vector')
    ! (current == reference is checked end to end on a straight finite-EI line in
    ! test_finite_straight_bendmom: the production BendMom channel must report 0 there.)
  END SUBROUTINE test_geometry_helpers

  ! ---- End-to-end static deck; cross-check channels against positions ----

  SUBROUTINE test_static_channels()
    INTEGER :: es, ok
    LOGICAL :: conv
    CHARACTER(256) :: em
    CHARACTER(2048) :: hdr
    REAL(wp) :: v(34), vd(34), n1(3), n2(3), n3(3), n4(3), n41(3), n42(3)
    CHARACTER(2048) :: hdr_decl

    CALL write_static_channels_deck('chan_static.dat')
    CALL CD_Run_Deck_Driver('chan_static.dat', 'chan_static', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'static channels deck converged: '//TRIM(em))
    CALL read_out_table('chan_static.out', hdr, v, 34, ok)
    CALL require(ok == 0, 'read static channels .out')
    IF (ok /= 0) RETURN

    ! header carries the exact channel tokens.
    CALL require(INDEX(hdr, 'FairAngle1') > 0, 'header has FairAngle1')
    CALL require(INDEX(hdr, 'AnchAngle1') > 0, 'header has AnchAngle1')
    CALL write_static_channels_deck('chan_static_decl.dat', explicit_decl=.TRUE.)
    CALL CD_Run_Deck_Driver('chan_static_decl.dat', 'chan_static_decl', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'explicit-declination deck converged: '//TRIM(em))
    CALL read_out_table('chan_static_decl.out', hdr_decl, vd, 34, ok)
    CALL require(ok == 0, 'read explicit-declination .out')
    IF (ok /= 0) RETURN
    CALL require(INDEX(hdr_decl, 'FairDecl1') > 0 .AND. INDEX(hdr_decl, 'AnchDecl1') > 0, &
                 'header has explicit endpoint declinations')
    CALL require(INDEX(hdr, 'FairIncl1') > 0 .AND. INDEX(hdr, 'AnchIncl1') > 0, &
                 'header has signed endpoint inclinations')
    CALL require(INDEX(hdr, 'Curv1N3') > 0, 'header has Curv1N3')
    CALL require(INDEX(hdr, 'BendMom1N3') > 0, 'header has BendMom1N3')
    CALL require(INDEX(hdr, 'L1N3Dec') > 0, 'header has L1N3Dec')
    CALL require(INDEX(hdr, 'L1N3Azi') > 0, 'header has L1N3Azi')
    CALL require(INDEX(hdr, 'L1N3az') > 0, 'header has L1N3az')

    n1 = v(6:8); n2 = v(9:11); n3 = v(12:14); n4 = v(15:17); n41 = v(18:20); n42 = v(21:23)

    ! endpoint positions confirm the deck-order (End A -> End B) node mapping.
    CALL require(NORM2(n1 - [0.0_wp, 0.0_wp, 0.0_wp]) < 1.0e-6_wp, 'node 1 = fairlead (0,0,0)')
    CALL require(NORM2(n42 - [400.0_wp, 0.0_wp, -50.0_wp]) < 1.0e-6_wp, 'node 42 = anchor (400,0,-50)')
    CALL require(v(2) > 0.0_wp .AND. v(3) > 0.0_wp, 'fairlead/anchor tensions positive')

    ! curvature channel == circumcircle curvature of the reported neighbour positions.
    CALL require(ABS(v(24) - ref_curv(n2, n3, n4)) < 5.0e-6_wp, 'Curv1N3 matches positions')
    ! declination / azimuth channels == angle of the central-difference tangent (End A -> End B).
    CALL require(ABS(v(25) - ref_dec(n4 - n2)) < 1.0e-3_wp, 'L1N3Dec matches tangent')
    CALL require(ABS(v(26) - ref_azi(n4 - n2)) < 1.0e-3_wp, 'L1N3Azi matches tangent')
    ! fairlead / anchor angle == one-sided declination at the ends.
    CALL require(ABS(v(4) - ref_dec(n2 - n1)) < 1.0e-3_wp, 'FairAngle1 = End A declination')
    CALL require(ABS(v(5) - ref_dec(n42 - n41)) < 1.0e-3_wp, 'AnchAngle1 = End B declination')
    CALL require(ABS(vd(4) - v(4)) < 1.0e-5_wp .AND. ABS(vd(5) - v(5)) < 1.0e-5_wp, &
                 'FairDecl/AnchDecl are explicit legacy-declination aliases')
    CALL require(v(31) > v(3) .AND. v(32) > v(3), 'suspended nodal tensions exceed the anchor tension')
    CALL require(ABS(v(33) - (v(4) - 90.0_wp)) < 1.0e-5_wp .AND. &
                 ABS(v(34) - (v(5) - 90.0_wp)) < 1.0e-5_wp, &
                 'FairIncl/AnchIncl are signed angles below horizontal')
    ! EI = 0 static line -> zero bend moment; static run -> exactly zero acceleration.
    CALL require(ABS(v(27)) < 1.0e-6_wp, 'BendMom1N3 = 0 on EI=0 line')
    CALL require(ABS(v(28)) < 1.0e-12_wp .AND. ABS(v(29)) < 1.0e-12_wp .AND. ABS(v(30)) < 1.0e-12_wp, &
                 'acceleration channel exactly 0 on a static run')
    ! declination physically sensible: the line leaves the fairlead downward (> 90 deg from +GZ).
    CALL require(v(4) > 90.0_wp .AND. v(4) <= 180.0_wp, 'FairAngle1 in the lower hemisphere')
    WRITE (*, '(A,F8.5,A,F9.4,A,F9.4)') 'static channels: Curv1N3=', v(24), '  FairAngle=', v(4), '  L1N3Dec=', v(25)
  END SUBROUTINE test_static_channels

  ! ---- Part 3: <out_root>.static.out along-arc profile ----

  SUBROUTINE test_static_config_file()
    INTEGER :: u, ios, es, nrow, lineid, node, prevnode
    LOGICAL :: conv
    CHARACTER(256) :: em
    CHARACTER(2048) :: title, hdr, units
    CHARACTER(512) :: buf
    REAL(wp) :: s, x, y, z, tn, cv, bm, dc, inc, az, prev_s
    REAL(wp) :: r2(3), r3(3), r4(3), c2, c3, c4, cv3

    CALL write_static_channels_deck('chan_cfg.dat')
    CALL CD_Run_Deck_Driver('chan_cfg.dat', 'chan_cfg', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'static.out deck converged: '//TRIM(em))

    OPEN (NEWUNIT=u, FILE='chan_cfg.static.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open chan_cfg.static.out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) title
    READ (u, '(A)', IOSTAT=ios) hdr
    READ (u, '(A)', IOSTAT=ios) units
    CALL require(INDEX(hdr, 'ArcLength') > 0 .AND. INDEX(hdr, 'Curvature') > 0 .AND. &
                 INDEX(hdr, 'BendMoment') > 0 .AND. INDEX(hdr, 'Declination') > 0 .AND. &
                 INDEX(hdr, 'Inclination') > 0 .AND. INDEX(hdr, 'Azimuth') > 0, &
                 'static.out header row has all columns')
    CALL require(INDEX(units, '(1/m)') > 0 .AND. INDEX(units, '(deg)') > 0 .AND. INDEX(units, '(N.m)') > 0, &
                 'static.out units row present')

    nrow = 0
    prevnode = 0
    prev_s = -1.0_wp
    cv3 = -1.0_wp
    c2 = 0.0_wp; c3 = 0.0_wp; c4 = 0.0_wp
    r2 = 0.0_wp; r3 = 0.0_wp; r4 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(buf) == 0) CYCLE
      READ (buf, *, IOSTAT=ios) lineid, node, s, x, y, z, tn, cv, bm, dc, inc, az
      CALL require(ios == 0, 'parse static.out data row')
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      CALL require(lineid == 1, 'static.out LineID column keyed to line 1')
      CALL require(node == prevnode + 1, 'static.out Node column increments 1..N')
      CALL require(s >= prev_s - 1.0e-9_wp, 'static.out ArcLength monotonic non-decreasing')
      IF (node == 1) CALL require(ABS(s) < 1.0e-9_wp, 'static.out arc length starts at 0 at End A')
      CALL require(ABS(bm) < 1.0e-6_wp, 'static.out BendMoment = 0 on EI=0 line')
      CALL require(ABS(inc - (dc - 90.0_wp)) < 2.0e-5_wp, 'static.out inclination convention')
      IF (node == 2) r2 = [x, y, z]
      IF (node == 3) THEN; r3 = [x, y, z]; cv3 = cv; END IF
      IF (node == 4) r4 = [x, y, z]
      prevnode = node
      prev_s = s
    END DO
    CLOSE (u)
    CALL require(nrow == 42, 'static.out has one row per node (42)')
    ! the curvature COLUMN at node 3 matches the circumcircle of nodes 2,3,4 from the same file.
    CALL require(cv3 >= 0.0_wp .AND. ABS(cv3 - ref_curv(r2, r3, r4)) < 5.0e-6_wp, &
                 'static.out Curvature column matches analytic value')
    WRITE (*, '(A,I0,A,F10.5)') 'static.out rows=', nrow, '  node3 curvature=', cv3
  END SUBROUTINE test_static_config_file

  ! ---- Part 4: finite-EI initialised deck; non-zero bend moment = EI*curvature/stretch ----

  SUBROUTINE test_finite_dynamic_channels()
    INTEGER :: es, ok
    LOGICAL :: conv
    CHARACTER(256) :: em
    CHARACTER(2048) :: hdr
    REAL(wp) :: v(18), n2(3), n3(3), n4(3)
    REAL(wp), PARAMETER :: EI = 2.0e5_wp

    CALL write_finite_channels_deck('chan_fin.dat')
    CALL CD_Run_Deck_Driver('chan_fin.dat', 'chan_fin', conv, es, em)
    CALL require(es == CD_DECKDRV_OK, 'finite-EI channels deck ran: '//TRIM(em))
    CALL read_out_table('chan_fin.out', hdr, v, 18, ok)
    CALL require(ok == 0, 'read finite-EI channels .out')
    IF (ok /= 0) RETURN

    CALL require(INDEX(hdr, 'BendMom1N3') > 0 .AND. INDEX(hdr, 'Curv1N3') > 0 .AND. &
                 INDEX(hdr, 'L1N3ax') > 0, 'finite header has curvature/bend/accel channels')
    n2 = v(6:8); n3 = v(9:11); n4 = v(12:14)
    ! This lazy-wave deck's CURRENT shape is the curved arch (state q0); its finite-EI
    ! stress-free reference (nodes_ref) is a STRAIGHT rod (CableDyn_HermiteArch builds a
    ! straight nodes_ref, not the arch). So the arch is genuinely bent RELATIVE to its
    ! straight reference: Curv (geometric) is non-zero and the reference-relative bend moment
    ! reduces to EI * geometric curvature (kvec_reference = 0 for a straight reference).
    CALL require(v(4) > 1.0e-4_wp, 'finite-EI Curv1N3 is non-zero (arched cable vs straight reference)')
    ! Finite-EI output is evaluated from the Hermite position and tangent DOFs.  It
    ! must not regress to a three-position Menger estimate, which can miss the
    ! element-interior maximum and is retained only for EI=0 nodal lines.
    CALL require(ABS(v(4) - ref_curv(n2, n3, n4)) > 5.0e-6_wp, &
                 'finite-EI Curv1N3 uses exact Hermite traces rather than Menger curvature')
    ! BendMom = EI(node) * |kvec_current - kvec_reference|/|r'|; straight reference => EI * geometric
    ! over the stretch, EI = 2.0e5 for this homogeneous line (the required straight-reference
    ! agreement check). The channels do not give |r'|, within 1e-4 of 1 on this stiff line: the
    ! exact relation is gated in test_openfast_aggregate and check_curvature_stretch.py.
    CALL require(ABS(v(5) - EI*v(4)) <= 1.0e-4_wp*ABS(v(5)) + 1.0e-9_wp, &
                 'BendMom1N3 = EI * geometric curvature, over the stretch, for the straight reference')
    CALL require(v(5) > 1.0_wp, 'finite-EI BendMom1N3 is non-zero (bent vs straight reference)')
    CALL check_continuous_element_file('chan_fin.elements.out', 20, EI)
    ! tensile_safety True judges the element-mean axial force (the pointwise resultant of a
    ! coarse element in the hang-off boundary layer oscillates about it): the segment tension
    ! of every node of the initial state is tensile.
    CALL require(min_static_tension('chan_fin.static.out') > 0.0_wp, &
                 'opt-in tensile safety leaves a tensile element-mean state before initialisation')
    ! The declination channel is the cable's tangent at the node (its tangent DOF), the
    ! Declination of the static profile; the chord of the neighbouring nodes is only close to it
    ! on this 20-element arch (1.2 deg off).
    CALL require(ABS(v(18) - static_declination('chan_fin.static.out', 3)) < 1.0e-5_wp, &
                 'finite-EI L1N3Dec is the static profile tangent')
    CALL require(ABS(v(18) - ref_dec(n4 - n2)) < 2.0_wp, 'finite-EI L1N3Dec is close to the chord')
    ! acceleration channel is finite on a dynamic run.
    CALL require(IEEE_IS_FINITE(v(15)) .AND. IEEE_IS_FINITE(v(16)) .AND. IEEE_IS_FINITE(v(17)), &
                 'finite-EI acceleration channel is finite')
    WRITE (*, '(A,F10.6,A,F12.3)') 'finite channels: Curv1N3=', v(4), '  BendMom1N3=', v(5)
  END SUBROUTINE test_finite_dynamic_channels

  SUBROUTINE test_finite_straight_bendmom()
    !! A neutrally buoyant, taut, straight finite-EI line: its current shape equals its
    !! straight stress-free reference, so the reference-relative BendMom channel is 0 (to the
    !! round-off of the neutral-buoyancy weight) while the same channel on the arched deck of
    !! test_finite_dynamic_channels is EI * curvature.
    INTEGER :: es, ok, u, ios
    LOGICAL :: conv
    CHARACTER(256) :: em
    CHARACTER(2048) :: hdr
    REAL(wp) :: v(3)
    OPEN (NEWUNIT=u, FILE='chan_fin_straight.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Finite-EI straight taut neutrally buoyant line'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    ! mass = rhoW pi d^2/4: zero submerged weight
    WRITE (u, '(A)') 'rod 0.10 8.0503311743 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0 0 -50'
    WRITE (u, '(A)') '2 Coupled 40 0 -50'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rod 39.99 10'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '0.001 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 BendMom1N3'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL CD_Run_Deck_Driver('chan_fin_straight.dat', 'chan_fin_straight', conv, es, em)
    CALL require(es == CD_DECKDRV_OK, 'straight finite-EI deck ran: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL read_out_table('chan_fin_straight.out', hdr, v, 3, ok)
    CALL require(ok == 0, 'read straight finite-EI .out')
    IF (ok /= 0) RETURN
    WRITE (*, '(A,ES12.4,A,ES12.4)') 'straight finite-EI: FairTen1=', v(2), '  BendMom1N3=', v(3)
    CALL require(v(2) > 1.0e5_wp, 'straight finite-EI line is taut')
    CALL require(ABS(v(3)) <= 1.0e-6_wp*2.0e5_wp, 'reference-relative BendMom = 0 when the shape equals its reference')
  END SUBROUTINE test_finite_straight_bendmom

  REAL(wp) FUNCTION static_declination(path, want_node) RESULT(dec)
    !! The Declination of node want_node of line 1 in a static.out profile; HUGE when unreadable.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: want_node
    INTEGER :: u, ios, lineid, node
    REAL(wp) :: s, x, y, z, tn, curv, bend, d
    CHARACTER(2048) :: buf
    dec = HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO node = 1, 3
      READ (u, '(A)', IOSTAT=ios) buf
    END DO
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(buf) == 0) CYCLE
      READ (buf, *, IOSTAT=ios) lineid, node, s, x, y, z, tn, curv, bend, d
      IF (ios /= 0) EXIT
      IF (lineid == 1 .AND. node == want_node) THEN
        dec = d
        EXIT
      END IF
    END DO
    CLOSE (u)
  END FUNCTION static_declination

  REAL(wp) FUNCTION min_static_tension(path) RESULT(tmin)
    !! Smallest node Tension (segment tension) of a static.out profile; -HUGE when unreadable.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, lineid, node
    REAL(wp) :: s, x, y, z, tn
    CHARACTER(2048) :: buf
    tmin = -HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    tmin = HUGE(1.0_wp)
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(buf) == 0) CYCLE
      READ (buf, *, IOSTAT=ios) lineid, node, s, x, y, z, tn
      IF (ios /= 0) THEN
        tmin = -HUGE(1.0_wp)
        EXIT
      END IF
      tmin = MIN(tmin, tn)
    END DO
    CLOSE (u)
  END FUNCTION min_static_tension

  SUBROUTINE check_continuous_element_file(path, expected_rows, EI)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: expected_rows
    REAL(wp), INTENT(IN) :: EI
    INTEGER :: u, ios, line_id, element, row_count
    REAL(wp) :: arc_start, arc_end, peak_xi, peak_arc, peak_curvature, bend_moment, &
                minimum_resultant, minimum_xi, maximum_resultant, maximum_xi, previous_end
    CHARACTER(2048) :: header

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open continuous Hermite-element extrema file')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) header
    READ (u, '(A)', IOSTAT=ios) header
    CALL require(INDEX(header, 'PeakCurvature') > 0 .AND. INDEX(header, 'MinimumAxialResultant') > 0, &
                 'element-extrema header identifies continuous design quantities')
    READ (u, '(A)', IOSTAT=ios) header
    row_count = 0
    previous_end = 0.0_wp
    DO
      READ (u, *, IOSTAT=ios) line_id, element, arc_start, arc_end, peak_xi, peak_arc, peak_curvature, &
        bend_moment, minimum_resultant, minimum_xi, maximum_resultant, maximum_xi
      IF (ios /= 0) EXIT
      row_count = row_count + 1
      CALL require(line_id == 1 .AND. element == row_count, 'element-extrema rows retain public line order')
      CALL require(ABS(arc_start - previous_end) < 1.0e-8_wp, 'element reference arcs are contiguous')
      CALL require(arc_end > arc_start .AND. peak_arc >= arc_start .AND. peak_arc <= arc_end, &
                   'curvature-peak reference station lies inside its element')
      CALL require(peak_xi >= 0.0_wp .AND. peak_xi <= 1.0_wp .AND. &
                   minimum_xi >= 0.0_wp .AND. minimum_xi <= 1.0_wp .AND. &
                   maximum_xi >= 0.0_wp .AND. maximum_xi <= 1.0_wp, &
                   'reported within-element stations lie in [0,1]')
      CALL require(peak_curvature >= 0.0_wp .AND. minimum_resultant <= maximum_resultant, &
                   'element extrema are ordered')
      CALL require(ABS(bend_moment - EI*peak_curvature) <= 2.0e-7_wp*MAX(1.0_wp, ABS(bend_moment)), &
                   'element peak bend moment equals EI times continuous peak curvature')
      CALL require(ALL(IEEE_IS_FINITE([arc_start, arc_end, peak_xi, peak_arc, peak_curvature, bend_moment, &
                                       minimum_resultant, minimum_xi, maximum_resultant, maximum_xi])), &
                   'element extrema are finite')
      previous_end = arc_end
    END DO
    CLOSE (u)
    CALL require(row_count >= expected_rows, &
                 'element-extrema file has one row per user or locally safety-refined Hermite element')
  END SUBROUTINE check_continuous_element_file

  ! ---- Part 5: EI=0 prescribed-motion deck; acceleration is non-zero ----

  SUBROUTINE test_motion_accel_channels()
    INTEGER :: es, ok
    LOGICAL :: conv
    CHARACTER(256) :: em
    CHARACTER(2048) :: hdr
    REAL(wp) :: v(9)

    CALL write_motion_channels_deck('chan_mot.dat', 'chan_mot_motion.dat')
    CALL write_motion_file('chan_mot_motion.dat')
    CALL CD_Run_Deck_Driver('chan_mot.dat', 'chan_mot', conv, es, em)
    CALL require(es == CD_DECKDRV_OK, 'motion channels deck ran: '//TRIM(em))
    CALL read_out_table('chan_mot.out', hdr, v, 9, ok)
    CALL require(ok == 0, 'read motion channels .out')
    IF (ok /= 0) RETURN

    CALL require(INDEX(hdr, 'L1N2ax') > 0 .AND. INDEX(hdr, 'Curv1N3') > 0, 'motion header has accel/curv channels')
    CALL require(IEEE_IS_FINITE(v(2)) .AND. IEEE_IS_FINITE(v(5)) .AND. IEEE_IS_FINITE(v(8)), &
                 'motion acceleration channels finite')
    ! the driven fairlead accelerates the interior nodes: at least one component is non-zero.
    CALL require(nan_max_abs(v(2:7)) > 1.0e-6_wp, 'EI=0 dynamic acceleration channel is non-zero')
    CALL require(IEEE_IS_FINITE(v(8)), 'motion Curv1N3 finite')
    WRITE (*, '(A,ES12.4)') 'motion channels: max |accel| =', nan_max_abs(v(2:7))
  END SUBROUTINE test_motion_accel_channels

  ! ---- Part 6: fail-closed on bad channel tokens ----

  SUBROUTINE test_fail_closed()
    CALL expect_bad('Bogus1N3', 'not supported', 'unknown channel token')
    CALL expect_bad('Curv9N3', 'bad line-node channel syntax', 'curvature on an unknown line id')
    CALL expect_bad('Curv1N999', 'node index exceeds', 'curvature node index out of range')
    CALL expect_bad('L1N3aq', 'bad line-node channel syntax', 'bad acceleration component')
    CALL expect_bad('FairAngle9', 'unknown line id', 'fairlead angle on an unknown line id')
    CALL expect_bad('AnchIncl9', 'unknown line id', 'anchor inclination on an unknown line id')
  END SUBROUTINE test_fail_closed

  SUBROUTINE expect_bad(channel, want_msg, what)
    CHARACTER(*), INTENT(IN) :: channel, want_msg, what
    INTEGER :: es
    LOGICAL :: conv
    CHARACTER(256) :: em

    CALL write_bad_channel_deck('chan_bad.dat', channel)
    CALL CD_Run_Deck_Driver('chan_bad.dat', 'chan_bad', conv, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT, 'fail-closed BADINPUT on '//TRIM(what)//': '//TRIM(em))
    CALL require(INDEX(em, want_msg) > 0, 'fail-closed message names the guard for '//TRIM(what)//': '//TRIM(em))
  END SUBROUTINE expect_bad

  ! ---- shared .out reader ----

  SUBROUTINE read_out_table(path, header, vals, nval, ErrStat)
    !! Read the channel-name header (2nd line) and the LAST data row (nval columns
    !! including the leading Time) of a driver `.out`. Tabs are list-directed separators.
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(OUT) :: header
    REAL(wp), INTENT(OUT) :: vals(:)
    INTEGER, INTENT(IN) :: nval
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    CHARACTER(2048) :: buf
    LOGICAL :: got_row

    ErrStat = 1
    header = ''
    got_row = .FALSE.
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf          ! # comment
    READ (u, '(A)', IOSTAT=ios) header       ! channel names
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(buf) == 0) CYCLE
      READ (buf, *, IOSTAT=ios) vals(1:nval)
      IF (ios /= 0) THEN
        CLOSE (u); RETURN
      END IF
      got_row = .TRUE.
    END DO
    CLOSE (u)
    IF (got_row) ErrStat = 0
  END SUBROUTINE read_out_table

  ! ---- deck fixtures ----

  ! ---- Azimuth range of a line: (-180, 180] near +X, [0, 360) otherwise ----

  SUBROUTINE test_azimuth_ranges()
    !! A line whose static chord (End A -> End B) heads within 45 deg of +X reports its tangent
    !! azimuths in (-180, 180], every other line in [0, 360), so a line swaying about +X no longer
    !! jumps between 0 and 360. A round-off component across the cut of the range reads on its
    !! included side, and one across +X reads exactly 0.
    INTEGER :: es, ok, u, ios, lineid, node, n1, n2, n3
    LOGICAL :: conv
    CHARACTER(256) :: em
    CHARACTER(2048) :: hdr, buf
    REAL(wp) :: v(6), a3_min, a3_max, s, x, y, z, tn, cv, bm, dc, inc, az, a1_min, a1_max, a2_min, a2_max
    REAL(wp), PARAMETER :: HEAD = 2.862405226111748_wp   ! ATAN2(20, 400) [deg]

    CALL require(exact(tangent_azimuth_deg([1.0_wp, -1.0e-17_wp, 0.0_wp]), 0.0_wp), &
                 'round-off just below +x reads exactly 0, not 360')
    CALL require(exact(tangent_azimuth_deg([1.0_wp, -1.0e-17_wp, 0.0_wp], .TRUE.), 0.0_wp), &
                 'round-off just below +x reads exactly 0 in the signed range')
    CALL require(ABS(tangent_azimuth_deg([1.0_wp, -1.0e-3_wp, 0.0_wp]) - (360.0_wp - 1.0e-3_wp*DEG)) < 1.0e-6_wp, &
                 'a heading just below +x is 359.94 deg in [0, 360)')
    CALL require(ABS(tangent_azimuth_deg([1.0_wp, -1.0e-3_wp, 0.0_wp], .TRUE.) + 1.0e-3_wp*DEG) < 1.0e-6_wp, &
                 'a heading just below +x is -0.057 deg in (-180, 180]')
    CALL require(ABS(tangent_azimuth_deg([0.0_wp, -1.0_wp, 0.0_wp], .TRUE.) + 90.0_wp) < 1.0e-10_wp, &
                 'signed azimuth -y = -90 deg')
    CALL require(exact(tangent_azimuth_deg([-1.0_wp, 0.0_wp, 0.0_wp], .TRUE.), 180.0_wp), 'signed azimuth -x = 180 deg')
    CALL require(exact(tangent_azimuth_deg([-1.0_wp, -1.0e-17_wp, 0.0_wp], .TRUE.), 180.0_wp), &
                 'round-off just below -x reads 180 in the signed range, not -180')

    ! Three lines, each from a fairlead (End A) to an anchor 400 m away: line 1 heads 2.86 deg
    ! below +X (the signed range), line 2 2.86 deg below -X and line 3 at 300 deg (the [0, 360)
    ! range: 60 deg from +X).
    CALL write_azimuth_deck('chan_azi.dat')
    CALL CD_Run_Deck_Driver('chan_azi.dat', 'chan_azi', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'azimuth-range deck converged: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL read_out_table('chan_azi.out', hdr, v, 6, ok)
    CALL require(ok == 0, 'read azimuth-range .out')
    IF (ok /= 0) RETURN
    CALL require(ABS(v(2) + HEAD) < 1.0e-6_wp, 'L1N3Azi = -2.862 deg on a line heading below +X')
    CALL require(ABS(v(3) + HEAD) < 1.0e-6_wp, 'L1N1Azi = -2.862 deg at End A')
    CALL require(ABS(v(4) - (180.0_wp + HEAD)) < 2.0e-5_wp, 'L2N3Azi = 182.862 deg on a line heading below -X')
    CALL require(ABS(v(5) - (180.0_wp + HEAD)) < 2.0e-5_wp, 'L2N1Azi = 182.862 deg at End A')
    CALL require(ABS(v(6) - 300.0_wp) < 2.0e-5_wp, 'L3N3Azi = 300 deg on a line heading 60 deg below +X')
    ! The static profile reports every node of each line in the line's range.
    a1_min = HUGE(1.0_wp); a1_max = -HUGE(1.0_wp); a2_min = HUGE(1.0_wp); a2_max = -HUGE(1.0_wp)
    a3_min = HUGE(1.0_wp); a3_max = -HUGE(1.0_wp)
    n1 = 0; n2 = 0; n3 = 0
    OPEN (NEWUNIT=u, FILE='chan_azi.static.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open chan_azi.static.out')
    IF (ios /= 0) RETURN
    DO lineid = 1, 3
      READ (u, '(A)', IOSTAT=ios) buf
    END DO
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(buf) == 0) CYCLE
      READ (buf, *, IOSTAT=ios) lineid, node, s, x, y, z, tn, cv, bm, dc, inc, az
      IF (ios /= 0) EXIT
      IF (lineid == 1) THEN
        n1 = n1 + 1; a1_min = MIN(a1_min, az); a1_max = MAX(a1_max, az)
      ELSE IF (lineid == 2) THEN
        n2 = n2 + 1; a2_min = MIN(a2_min, az); a2_max = MAX(a2_max, az)
      ELSE
        n3 = n3 + 1; a3_min = MIN(a3_min, az); a3_max = MAX(a3_max, az)
      END IF
    END DO
    CLOSE (u)
    CALL require(n1 == 21 .AND. n2 == 21 .AND. n3 == 21, 'static.out lists the three lines')
    CALL require(ABS(a3_min - 300.0_wp) < 2.0e-5_wp .AND. ABS(a3_max - 300.0_wp) < 2.0e-5_wp, &
                 'static.out Azimuth of line 3 is 300 deg at every node')
    CALL require(ABS(a1_min + HEAD) < 1.0e-6_wp .AND. ABS(a1_max + HEAD) < 1.0e-6_wp, &
                 'static.out Azimuth of line 1 is -2.862 deg at every node')
    CALL require(ABS(a2_min - (180.0_wp + HEAD)) < 2.0e-5_wp .AND. ABS(a2_max - (180.0_wp + HEAD)) < 2.0e-5_wp, &
                 'static.out Azimuth of line 2 is 182.862 deg at every node')
    WRITE (*, '(A,F10.5,A,F10.5)') 'azimuth ranges: L1N3Azi=', v(2), '  L2N3Azi=', v(4)
  END SUBROUTINE test_azimuth_ranges

  SUBROUTINE write_azimuth_deck(path)
    !! Three EI = 0 chains on a flat seabed, each from a fairlead at the surface to an anchor 400 m
    !! away horizontally: lines 1 and 2 toward +X and -X with the anchor 20 m toward -Y, line 3
    !! at 300 deg.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'azimuth-range deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 10.0 0.0 0.0'
    WRITE (u, '(A)') '2 Fixed 410.0 -20.0 -50.0'
    WRITE (u, '(A)') '3 Coupled -10.0 0.0 0.0'
    WRITE (u, '(A)') '4 Fixed -410.0 -20.0 -50.0'
    WRITE (u, '(A)') '5 Coupled 0.0 10.0 0.0'
    WRITE (u, '(A)') '6 Fixed 200.0 -336.41016151377546 -50.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '3 5 6 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 20'
    WRITE (u, '(A)') '2 chain 410.0 20'
    WRITE (u, '(A)') '3 chain 410.0 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N3Azi L1N1Azi L2N3Azi L2N1Azi L3N3Azi'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_azimuth_deck

  SUBROUTINE write_static_channels_deck(path, explicit_decl)
    !! WD0050 grounded chain (EI=0 static) requesting the full geometric channel set.
    !! explicit_decl requests columns 4-5 by their FairDecl/AnchDecl spelling instead of the
    !! FairAngle/AnchAngle aliases (one channel may be requested once, under either name).
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN), OPTIONAL :: explicit_decl
    INTEGER :: u, ios
    CHARACTER(24) :: ends
    ends = 'FairAngle1 AnchAngle1 '
    IF (PRESENT(explicit_decl)) THEN
      IF (explicit_decl) ends = 'FairDecl1 AnchDecl1 '
    END IF
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 static geometric-channel deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 '//ends// &
      'L1N1px L1N1py L1N1pz L1N2px L1N2py L1N2pz L1N3px L1N3py L1N3pz L1N4px L1N4py L1N4pz '// &
      'L1N41px L1N41py L1N41pz L1N42px L1N42py L1N42pz '// &
      'Curv1N3 L1N3Dec L1N3Azi BendMom1N3 L1N3ax L1N3ay L1N3az '// &
      'Ten1N2 Ten1N3 FairIncl1 AnchIncl1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_static_channels_deck

  SUBROUTINE write_finite_channels_deck(path)
    !! Finite-EI net-buoyant lazy-wave cable (EI = 2.0e5). The EQUIVALENT BUOYANCY row
    !! makes the line net-buoyant, so the finite-EI path seeds the CURVED cubic-Hermite
    !! arch (not a straight seed): node 3 sits on the arch, giving a genuinely non-zero
    !! curvature and bend moment. Mirrors the lazy-wave deck already in the suite.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Finite-EI lazy-wave geometric-channel deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'power 0.10 500 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0 0 -80'
    WRITE (u, '(A)') '2 Coupled 40 0 -20'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    ! Keep this channel-wiring fixture above the universal h*kappa safety floor;
    ! five elements produce a residual-balanced but element-localized arch fold.
    WRITE (u, '(A)') '1 power 90 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '0.001 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '4 axial_quadrature_order'
    WRITE (u, '(A)') '4 bending_quadrature_order'
    WRITE (u, '(A)') 'True tensile_safety'
    WRITE (u, '(A)') '--- EQUIVALENT BUOYANCY ---'
    WRITE (u, '(A)') 'LineType Diam SubmergedWeightNpm'
    WRITE (u, '(A)') '(-) (m) (N/m)'
    WRITE (u, '(A)') 'power 0.50 -1483.0'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 Curv1N3 BendMom1N3 '// &
      'L1N2px L1N2py L1N2pz L1N3px L1N3py L1N3pz L1N4px L1N4py L1N4pz '// &
      'L1N3ax L1N3ay L1N3az L1N3Dec'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_finite_channels_deck

  SUBROUTINE write_motion_channels_deck(path, motion_path)
    !! WD0050 EI=0 chain with a prescribed-motion fairlead, requesting node accelerations.
    CHARACTER(*), INTENT(IN) :: path, motion_path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 prescribed-motion acceleration-channel deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A,A)') TRIM(motion_path), ' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N2ax L1N2ay L1N2az L1N3ax L1N3ay L1N3az Curv1N3 L1N3Dec'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_motion_channels_deck

  SUBROUTINE write_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '0.00 2 0.0 0.0 0.000 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.01 2 0.0 0.0 0.005 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.02 2 0.0 0.0 0.010 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.03 2 0.0 0.0 0.015 0.0 0.0 0.5 0.0 0.0 0.0'
    CLOSE (u)
  END SUBROUTINE write_motion_file

  SUBROUTINE write_bad_channel_deck(path, channel)
    !! WD0050 static deck whose single OUTPUT is a deliberately invalid channel token.
    CHARACTER(*), INTENT(IN) :: path, channel
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 fail-closed channel deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') TRIM(channel)
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_bad_channel_deck

END PROGRAM test_driver_channels
