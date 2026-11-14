! File: tests/test_static_dry_weight.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_static_dry_weight
  !! The static start of an EI = 0 line held above the still-water level gives the part above
  !! the surface its dry weight, as the dynamic model's buoyancy recovery does, on the
  !! standalone and the coupled route alike (CD_Static_Line_Equilibrium with the dry-part
  !! arguments). Gates:
  !!   1. A vertical chain hung from 10 m above the surface to a point 90 m below it (99.9 m,
  !!      taut): the vertical loads of its two ends sum to its weight, w_sub times the wet
  !!      length plus the dry weight per metre times the dry length (the dry length 10 m over
  !!      the stretch of the top element), to 1e-6 (measured 1.5e-8). With the buoyancy kept
  !!      above the surface the sum read 1.4e-2 low.
  !!   2. A chain hung 5 m above the surface onto a 200 m seabed (850 m, grounded tail): the
  !!      coupled aggregate's static start gives the standalone driver's fairlead load to the
  !!      driver's 8 output digits, 2e-7 (measured 1.4e-8; before 2.4e-4: the coupled load was
  !!      the dynamic reaction of a start that was not the equilibrium of the dynamics, whose
  !!      buoyancy recovery gives the dry part its dry weight).
  !!   3. The same chain held still on the coupled route for 1 s (40 steps of 0.025 s): the
  !!      fairlead load stays at its static value to 1e-7 (measured 1e-10; before it moved by
  !!      9.7e-4 in the first step and by 1.4e-3 at 1 s, ringing about the heavier
  !!      equilibrium).
  !!   4. A finite-EI cable hung 5 m above the surface (its statics already carry the dry
  !!      weight): coupled and standalone starts agree to 2e-7 (measured 7e-8; a guard).
  !!   5. A 50 t Connect point hung by two chains from Fixed points 10 m above the surface on a
  !!      300 m seabed: the point's force balance (the static object solve, its warm line solves
  !!      included) carries the dry weight too, so the point holds its static position over 2 s
  !!      of the march to 1e-4 m, the output's 8 digits (measured 0), and the fairlead tension to
  !!      1e-6 (measured 0). With the dry weight only in the line starts the point sank 1.1e-2 m
  !!      and the tension moved by 9.6e-4.
  !!   6. A finite-EI cable hung from 5 m above the surface carrying a module (500 kg, 0.2 m^3)
  !!      2 m along it, above the surface, which the dynamics loads with its weight alone (no
  !!      buoyancy, no drag), held still for 1 s (dtM 0.01 s): the fairlead load stays at its
  !!      static value to 1e-7 (measured 0, the output's 8 digits); before, the static start gave
  !!      the module its buoyancy and the load moved by up to 6.1e-2 (Fz -44269 to -46272 N at
  !!      1 s). The same cable restrained in torsion at both ends (GJ 1e4 N m^2, a quarter turn,
  !!      the torsion stage after the attachment polish): the same, measured 0, before 6.1e-2. A
  !!      module 30 m along the line, under water, keeps its net weight: the guard of both
  !!      (measured 0).
  !!   7. A stiff body (C44 = C55 = 2e8 N m/rad) on three EI = 0 legs, with a light finite-EI cable
  !!      (EI 100 N m^2, whose bending changes its end force little) pinned at a body point 5 m
  !!      above the surface, on a deck without a seabed: the body static solve gives the cable's
  !!      part above the surface its dry weight, as its cubic-Hermite cable has it, so the body
  !!      holds its heave over 3 s to 1e-4 m (measured 7e-6 m); before the solve kept the buoyancy
  !!      of that part (the cable's EI = 0 surrogate took the dry weight only with a seabed) and the
  !!      body's heave moved by 2.8e-3 m.
  !!   8. An EI = 0 chain between two moving objects across the surface: from a body point 5 m above
  !!      it (the stiff body of gate 7) to a 3 t Connect clump that a second chain holds to an
  !!      anchor, WtrDpth 100 m. The object solve moves the body and the point together, the chain
  !!      solved with its dry part between them: both hold their static positions over 3 s of the
  !!      march to 1e-4 m (measured 0); with the buoyancy kept above the surface (dev before the
  !!      dry-weight fix) they moved by 5.5e-3 m.
  !!   9. A net-buoyant module (200 kg, 2 m^3) 50 m along a slack finite-EI cable from 20 m below
  !!      the surface: in water it lifts its node 4.5 m above the surface, where the dynamics gives
  !!      it its weight alone, which sinks it: a point attachment has no static position there.
  !!      The static start fails closed and its message names the attachment that crossed the
  !!      still-water level. Before, the solves carried the module above and below the surface in
  !!      turn until a load step failed, and the message read as a homotopy that stopped (dev
  !!      started the module 4.5 m above the surface with its buoyancy and ran).
  !! A deck whose lines are all submerged is solved once, bit-identically (the example A/B).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_NMovingPoints, CD_AGG_CalcOutput, CD_AGG_Step_Moving, CD_AGG_End, &
                                         CD_AGG_OK
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: G = 9.80665_wp, RHOW = 1025.0_wp, PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: D_CHAIN = 0.333_wp, M_CHAIN = 685.0_wp, EA_CHAIN = 3.27e9_wp
  INTEGER :: nfail
  REAL(wp) :: f_drv(3), f_agg(3), f2(3), w_dry, w_sub, l_dry, eps_top, w_true, err, dmax

  nfail = 0
  w_dry = M_CHAIN*G
  w_sub = w_dry - RHOW*G*0.25_wp*PI*D_CHAIN**2

  ! 1. vertical chain across the surface
  CALL write_deck('dry_vertical.dat', 'main 0.333 685.00 3.27e9 -1.0 0.0 2.0 0.4 0.82 0.27', &
                  '0.0 0.0 10.0', '0.0 0.0 -90.0', '1 main 99.9 100', 200.0_wp)
  CALL driver_forces('dry_vertical', f_drv, f2)
  ! the dry length: 10 m of the top element's stretch (the tension varies by 0.1 % over it)
  eps_top = -f_drv(3)/EA_CHAIN
  l_dry = 10.0_wp/(1.0_wp + eps_top)
  w_true = w_sub*(99.9_wp - l_dry) + w_dry*l_dry
  err = ABS(f_drv(3) + f2(3) + w_true)/w_true
  WRITE (*, '(A,ES12.4,A,ES12.4,A,ES10.2)') '  vertical chain: sum of the end loads ', -(f_drv(3) + f2(3)), &
    ' N, weight ', w_true, ' N, rel. error ', err
  WRITE (*, '(A,ES10.2)') '    (buoyancy kept above the surface would read it low by ', &
    (w_dry - w_sub)*l_dry/w_true
  CALL check(err <= 1.0e-6_wp, 'vertical chain: the end loads carry the dry weight above the surface')

  ! 2. and 3. chain from 5 m above the surface onto the seabed
  CALL write_deck('dry_chain.dat', 'main 0.333 685.00 3.27e9 -1.0 0.0 2.0 0.4 0.82 0.27', &
                  '-58.0 0.0 5.0', '-837.6 0.0 -200.0', '1 main 850.0 50', 200.0_wp)
  CALL driver_forces('dry_chain', f_drv, f2)
  CALL coupled_force('dry_chain.dat', 40, f_agg, dmax)
  err = MAXVAL(ABS(f_agg - f_drv))/NORM2(f_drv)
  WRITE (*, '(A,3ES16.8)') '  chain, standalone fairlead load ', f_drv
  WRITE (*, '(A,3ES16.8,A,ES10.2)') '  chain, coupled fairlead load    ', f_agg, '  rel. ', err
  CALL check(err <= 2.0e-7_wp, 'chain above the surface: coupled and standalone static starts agree')
  WRITE (*, '(A,ES10.2)') '  chain held still 1 s on the coupled route: largest rel. load change ', dmax
  CALL check(dmax <= 1.0e-7_wp, 'chain above the surface: the static start is the equilibrium of the march')

  ! 4. finite-EI cable from 5 m above the surface
  CALL write_deck('dry_cable.dat', 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0', &
                  '30.0 0.0 5.0', '500.0 0.0 -200.0', '1 bare 600.0 240', 200.0_wp)
  CALL driver_forces('dry_cable', f_drv, f2)
  CALL coupled_force('dry_cable.dat', 0, f_agg, dmax)
  err = MAXVAL(ABS(f_agg - f_drv))/NORM2(f_drv)
  WRITE (*, '(A,ES10.2)') '  finite-EI cable above the surface: coupled vs standalone rel. ', err
  CALL check(err <= 2.0e-7_wp, 'finite-EI cable above the surface: coupled and standalone static starts agree')

  ! 5. a Connect point between two chains held above the surface
  CALL connect_point_drift(err, dmax)
  WRITE (*, '(A,ES10.2,A,ES10.2)') '  Connect point held 2 s: largest vertical drift ', dmax, &
    ' m, largest rel. fairlead tension change ', err
  CALL check(dmax <= 1.0e-4_wp, 'Connect point above the surface: its static position is the equilibrium of the march')
  CALL check(err <= 1.0e-6_wp, 'Connect point above the surface: the fairlead tension holds its static value')

  ! 6. an attachment above the surface, untwisted and restrained in torsion; under water, the guard
  CALL attachment_hold('dry_att', '1 2.0 500.0 0.2 0.0 0.0', .FALSE., err)
  WRITE (*, '(A,ES10.2)') '  module above the surface, held 1 s: largest rel. fairlead load change ', err
  CALL check(err <= 1.0e-7_wp, 'module above the surface: the static start is the equilibrium of the march')
  CALL attachment_hold('dry_att_tors', '1 2.0 500.0 0.2 0.0 0.0', .TRUE., err)
  WRITE (*, '(A,ES10.2)') '  module above the surface, torsion, held 1 s: largest rel. fairlead load change ', err
  CALL check(err <= 1.0e-7_wp, 'module above the surface, torsion: the static start is the equilibrium of the march')
  CALL attachment_hold('wet_att', '1 30.0 500.0 0.2 0.0 0.0', .FALSE., err)
  WRITE (*, '(A,ES10.2)') '  module under water, held 1 s: largest rel. fairlead load change ', err
  CALL check(err <= 1.0e-7_wp, 'module under water: the static start is the equilibrium of the march')

  ! 7. a pinned finite-EI cable above the surface on a body, no seabed
  CALL body_cable_heave(dmax)
  WRITE (*, '(A,ES10.2,A)') '  body with a pinned cable above the surface, no seabed: largest heave change ', dmax, ' m'
  CALL check(dmax <= 1.0e-4_wp, 'pinned cable above the surface on a body: the body static balance carries its '// &
             'dry weight')

  ! 8. an EI = 0 chain between a body above the surface and a Connect point
  CALL two_objects_drift(dmax)
  WRITE (*, '(A,ES10.2,A)') '  chain between a body above the surface and a Connect point: largest drift ', dmax, ' m'
  CALL check(dmax <= 1.0e-4_wp, 'chain between two moving objects across the surface: both start in the march''s '// &
             'equilibrium')

  ! 9. a module that would float: no static position, failed by name
  CALL floating_module()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAILED: ', nfail, ' check(s)'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: static dry weight above the surface'

CONTAINS

  SUBROUTINE check(ok, what)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: what
    IF (ok) THEN
      WRITE (*, '(2A)') '  ok: ', what
    ELSE
      WRITE (*, '(2A)') '  FAIL: ', what
      nfail = nfail + 1
    END IF
  END SUBROUTINE check

  SUBROUTINE write_deck(path, type_row, pa, pb, section_row, depth)
    !! One line from a Coupled point pa (End A) to a Fixed point pb; the standalone static start
    !! at TMax = 0, the time step for the coupled route.
    CHARACTER(*), INTENT(IN) :: path, type_row, pa, pb, section_row
    REAL(wp), INTENT(IN) :: depth
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='replace', ACTION='write')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'test_static_dry_weight: a line held above the still-water level'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') type_row
    WRITE (u, '(A)') '--------------------- POINTS ------------------------------------------------'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled '//pa
    WRITE (u, '(A)') '2 Fixed '//pb
    WRITE (u, '(A)') '--------------------- LINES -------------------------------------------------'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--------------------- SECTIONS ----------------------------------------------'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') section_row
    WRITE (u, '(A)') '--------------------- OPTIONS -----------------------------------------------'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '3.0e5 cBot'
    WRITE (u, '(A)') '0.025 dtM'
    WRITE (u, '(F8.2,A)') depth, ' WtrDpth'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--------------------- OUTPUTS -----------------------------------------------'
    WRITE (u, '(A)') '"Point1Fx"'
    WRITE (u, '(A)') '"Point1Fy"'
    WRITE (u, '(A)') '"Point1Fz"'
    WRITE (u, '(A)') '"Point2Fx"'
    WRITE (u, '(A)') '"Point2Fy"'
    WRITE (u, '(A)') '"Point2Fz"'
    WRITE (u, '(A)') 'END'
    WRITE (u, '(A)') '--------------------- need this line ----------------------------------------'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE driver_forces(root, fa, fb)
    !! The standalone static start (TMax = 0): the loads on points 1 and 2 (the t = 0 row).
    CHARACTER(*), INTENT(IN) :: root
    REAL(wp), INTENT(OUT) :: fa(3), fb(3)
    LOGICAL :: conv
    INTEGER :: es, u, ios
    CHARACTER(1024) :: em
    CHARACTER(4096) :: line
    REAL(wp) :: t
    fa = 0.0_wp
    fb = 0.0_wp
    CALL CD_Run_Deck_Driver(root//'.dat', root, conv, es, em)
    CALL check(es == CD_DECKDRV_OK .AND. conv, root//': standalone static start: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='old', ACTION='read')
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. INDEX(line, 'Time') > 0 .OR. LEN_TRIM(line) == 0) CYCLE
      READ (line, *) t, fa, fb
      EXIT
    END DO
    CLOSE (u)
  END SUBROUTINE driver_forces

  SUBROUTINE connect_point_drift(ten_rel, dz_max)
    !! Gate 5: two 240 m chains from Fixed points at (-+200, 0, 10) m to a Connect point (50 t,
    !! 2 m^3) at (0, 0, -100) m, WtrDpth 300 m, held 2 s (dtM 0.01 s). ten_rel: the largest change
    !! of FairTen1 over its t = 0 value, relative; dz_max: the largest change of the point's z [m].
    REAL(wp), INTENT(OUT) :: ten_rel, dz_max
    INTEGER :: u, ios, es
    LOGICAL :: conv
    REAL(wp) :: row(4), t0, z0
    CHARACTER(1024) :: em
    CHARACTER(4096) :: line
    LOGICAL :: first
    ten_rel = HUGE(1.0_wp)
    dz_max = HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE='dry_connect.dat', STATUS='replace', ACTION='write')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'test_static_dry_weight: a Connect point between two chains held above the surface'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.2791 480.93 2.058e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--------------------- POINTS ------------------------------------------------'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Fixed -200.0 0.0 10.0 0 0 0 0'
    WRITE (u, '(A)') '2 Connect 0.0 0.0 -100.0 50000.0 2.0 0 0'
    WRITE (u, '(A)') '3 Fixed 200.0 0.0 10.0 0 0 0 0'
    WRITE (u, '(A)') '--------------------- LINES -------------------------------------------------'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '2 3 2 -'
    WRITE (u, '(A)') '--------------------- SECTIONS ----------------------------------------------'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 240.0 30'
    WRITE (u, '(A)') '2 chain 240.0 30'
    WRITE (u, '(A)') '--------------------- OPTIONS -----------------------------------------------'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '2.0 TMax'
    WRITE (u, '(A)') '300.0 WtrDpth'
    WRITE (u, '(A)') '--------------------- OUTPUTS -----------------------------------------------'
    WRITE (u, '(A)') '"FairTen1"'
    WRITE (u, '(A)') '"Point2px"'
    WRITE (u, '(A)') '"Point2pz"'
    WRITE (u, '(A)') 'END'
    WRITE (u, '(A)') '--------------------- need this line ----------------------------------------'
    CLOSE (u)
    CALL CD_Run_Deck_Driver('dry_connect.dat', 'dry_connect', conv, es, em)
    CALL check(es == CD_DECKDRV_OK .AND. conv, 'dry_connect: run: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE='dry_connect.out', STATUS='old', ACTION='read')
    first = .TRUE.
    t0 = 0.0_wp
    z0 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. INDEX(line, 'Time') > 0 .OR. LEN_TRIM(line) == 0) CYCLE
      READ (line, *) row
      IF (first) THEN
        t0 = row(2)
        z0 = row(4)
        ten_rel = 0.0_wp
        dz_max = 0.0_wp
        first = .FALSE.
      END IF
      ten_rel = MAX(ten_rel, ABS(row(2) - t0)/t0)
      dz_max = MAX(dz_max, ABS(row(4) - z0))
    END DO
    CLOSE (u)
  END SUBROUTINE connect_point_drift

  SUBROUTINE attachment_hold(root, att_row, torsion, dmax_rel)
    !! Gate 6: a 600 m finite-EI cable (240 elements) from a Coupled point at (30, 0, 5) m to a
    !! Fixed one at (500, 0, -200) m on a 200 m seabed with one ATTACHMENTS row, held 1 s (dtM
    !! 0.01 s); torsion: restrained at both ends, a quarter turn at End B. dmax_rel: the largest
    !! change of the fairlead load over its t = 0 value, relative.
    CHARACTER(*), INTENT(IN) :: root, att_row
    LOGICAL, INTENT(IN) :: torsion
    REAL(wp), INTENT(OUT) :: dmax_rel
    INTEGER :: u, ios, es
    LOGICAL :: conv, first
    REAL(wp) :: row(3), f0(2)
    CHARACTER(1024) :: em
    CHARACTER(4096) :: line
    dmax_rel = HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE=root//'.dat', STATUS='replace', ACTION='write')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'test_static_dry_weight: a module above the still-water level'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    IF (torsion) THEN
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.0e8 1.0e4 1.0 0.1 1.2 0.1 1.0 0.0'
    ELSE
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    END IF
    WRITE (u, '(A)') '--------------------- POINTS ------------------------------------------------'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 30.0 0.0 5.0'
    WRITE (u, '(A)') '2 Fixed 500.0 0.0 -200.0'
    WRITE (u, '(A)') '--------------------- LINES -------------------------------------------------'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--------------------- SECTIONS ----------------------------------------------'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 600.0 240'
    WRITE (u, '(A)') '--------------------- ATTACHMENTS -------------------------------------------'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
    WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
    WRITE (u, '(A)') att_row
    IF (torsion) THEN
      WRITE (u, '(A)') '--------------------- END CONNECTIONS ----------------------------------------'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
      WRITE (u, '(A)') '1 A Pinned 0.7071067811865476 0 -0.7071067811865476 Rigid 0 1 0 0'
      WRITE (u, '(A)') '1 B Pinned 1 0 0 Rigid 0 1 0 90'
    END IF
    WRITE (u, '(A)') '--------------------- OPTIONS -----------------------------------------------'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '3.0e5 cBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '1.0 TMax'
    WRITE (u, '(A)') '--------------------- OUTPUTS -----------------------------------------------'
    WRITE (u, '(A)') '"Point1Fx"'
    WRITE (u, '(A)') '"Point1Fz"'
    WRITE (u, '(A)') 'END'
    WRITE (u, '(A)') '--------------------- need this line ----------------------------------------'
    CLOSE (u)
    CALL CD_Run_Deck_Driver(root//'.dat', root, conv, es, em)
    CALL check(es == CD_DECKDRV_OK .AND. conv, root//': run: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='old', ACTION='read')
    first = .TRUE.
    f0 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. INDEX(line, 'Time') > 0 .OR. LEN_TRIM(line) == 0) CYCLE
      READ (line, *) row
      IF (first) THEN
        f0 = row(2:3)
        dmax_rel = 0.0_wp
        first = .FALSE.
      END IF
      dmax_rel = MAX(dmax_rel, NORM2(row(2:3) - f0)/NORM2(f0))
    END DO
    CLOSE (u)
  END SUBROUTINE attachment_hold

  SUBROUTINE body_cable_heave(dz_max)
    !! Gate 7: a body at z = -3 m on three 103 m polyester legs to anchors at -100 m, with a
    !! 120 m finite-EI cable (EI 100 N m^2, 60 elements) pinned at the body point (0, 0, 8) m (5 m
    !! above the surface) towards a Fixed point at (-40, 0, -100) m, no seabed, bodyIC static,
    !! 3 s of the march (dtM 0.05 s). dz_max: the largest change of the body's heave [m].
    REAL(wp), INTENT(OUT) :: dz_max
    INTEGER :: u, ios, es
    LOGICAL :: conv, first
    REAL(wp) :: row(4), z0
    CHARACTER(1024) :: em
    CHARACTER(4096) :: line
    dz_max = HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE='dry_body_cable.dat', STATUS='replace', ACTION='write')
    WRITE (u, '(A)') 'test_static_dry_weight: a pinned finite-EI cable above the surface on a body, no seabed'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cab 0.2 60.0 5.0e8 -1.0 1.0e2 1.2 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0 0 -3 0 0 0 2.0e4 40.0 0.0 2.0e8 2.0e8 8.0 0.5 3.5e4 3.5e4 3.5e4'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '7 Body1 0.0 0.0 8.0 0 0 0 0'
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
    WRITE (u, '(A)') '1 poly 103.0 20'
    WRITE (u, '(A)') '2 poly 103.0 20'
    WRITE (u, '(A)') '3 poly 103.0 20'
    WRITE (u, '(A)') '4 cab 120.0 60'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '3.0 TMax'
    WRITE (u, '(A)') 'static bodyIC'
    WRITE (u, '(A)') 'monolithic bodyScheme'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px'
    WRITE (u, '(A)') 'Body1Pz'
    WRITE (u, '(A)') 'Body1Ry'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL CD_Run_Deck_Driver('dry_body_cable.dat', 'dry_body_cable', conv, es, em)
    CALL check(es == CD_DECKDRV_OK .AND. conv, 'dry_body_cable: run: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE='dry_body_cable.out', STATUS='old', ACTION='read')
    first = .TRUE.
    z0 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. INDEX(line, 'Time') > 0 .OR. LEN_TRIM(line) == 0) CYCLE
      READ (line, *) row
      IF (first) THEN
        z0 = row(3)
        dz_max = 0.0_wp
        first = .FALSE.
      END IF
      dz_max = MAX(dz_max, ABS(row(3) - z0))
    END DO
    CLOSE (u)
  END SUBROUTINE body_cable_heave

  SUBROUTINE floating_module()
    !! Gate 9: a 160 m finite-EI cable (80 elements) from a Coupled point at (0, 0, -20) m to a
    !! Fixed one at (100, 0, -50) m on a 50 m seabed, a 200 kg, 2 m^3 module 50 m along it.
    INTEGER :: u, es
    LOGICAL :: conv
    CHARACTER(1024) :: em
    OPEN (NEWUNIT=u, FILE='dry_float.dat', STATUS='replace', ACTION='write')
    WRITE (u, '(A)') 'test_static_dry_weight: a net-buoyant module that would float'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -20.0'
    WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 160.0 80'
    WRITE (u, '(A)') '--- ATTACHMENTS ---'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
    WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
    WRITE (u, '(A)') '1 50.0 200.0 2.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '3.0e5 cBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '0.1 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1Fz'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL CD_Run_Deck_Driver('dry_float.dat', 'dry_float', conv, es, em)
    WRITE (*, '(2A)') '  module that would float: ', TRIM(em)
    CALL check(es /= CD_DECKDRV_OK, 'module that would float: the static start fails closed')
    CALL check(INDEX(em, 'attachment 1 of the line') > 0 .AND. INDEX(em, 'crossed the still-water level') > 0, &
               'module that would float: the failure names the attachment that crossed the surface')
  END SUBROUTINE floating_module

  SUBROUTINE two_objects_drift(dmax)
    !! Gate 8: the body of gate 7, a 65 m chain (EI = 0, 30 segments) from its point (0, 0, 8) m to
    !! a Connect point (3 t) at (-30, 0, -50) m, and an 85 m chain from there to a Fixed point at
    !! (-90, 0, -100) m, WtrDpth 100 m, bodyIC static, 3 s of the march (dtM 0.02 s). dmax: the
    !! largest change of the body's x and z and the point's z [m].
    REAL(wp), INTENT(OUT) :: dmax
    INTEGER :: u, ios, es
    LOGICAL :: conv, first
    REAL(wp) :: row(4), r0(3)
    CHARACTER(1024) :: em
    CHARACTER(4096) :: line
    dmax = HUGE(1.0_wp)
    OPEN (NEWUNIT=u, FILE='dry_two_objects.dat', STATUS='replace', ACTION='write')
    WRITE (u, '(A)') 'test_static_dry_weight: an EI = 0 chain between a body above the surface and a Connect point'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'chain 0.1 60.0 8.0e8 -1.0 0.0 1.2 0.4 1.0 0.5'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0 0 -3 0 0 0 2.0e4 40.0 0.0 2.0e8 2.0e8 8.0 0.5 3.5e4 3.5e4 3.5e4'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '7 Body1 0.0 0.0 8.0 0 0 0 0'
    WRITE (u, '(A)') '8 Connect -30.0 0.0 -50.0 3000.0 0.0 0 0'
    WRITE (u, '(A)') '9 Fixed -90.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 4 -'
    WRITE (u, '(A)') '2 2 5 -'
    WRITE (u, '(A)') '3 3 6 -'
    WRITE (u, '(A)') '4 7 8 -'
    WRITE (u, '(A)') '5 8 9 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 103.0 20'
    WRITE (u, '(A)') '2 poly 103.0 20'
    WRITE (u, '(A)') '3 poly 103.0 20'
    WRITE (u, '(A)') '4 chain 65.0 30'
    WRITE (u, '(A)') '5 chain 85.0 30'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.02 dtM'
    WRITE (u, '(A)') '3.0 TMax'
    WRITE (u, '(A)') 'static bodyIC'
    WRITE (u, '(A)') 'monolithic bodyScheme'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Px'
    WRITE (u, '(A)') 'Body1Pz'
    WRITE (u, '(A)') 'Point8pz'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL CD_Run_Deck_Driver('dry_two_objects.dat', 'dry_two_objects', conv, es, em)
    CALL check(es == CD_DECKDRV_OK .AND. conv, 'dry_two_objects: run: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE='dry_two_objects.out', STATUS='old', ACTION='read')
    first = .TRUE.
    r0 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. INDEX(line, 'Time') > 0 .OR. LEN_TRIM(line) == 0) CYCLE
      READ (line, *) row
      IF (first) THEN
        r0 = row(2:4)
        dmax = 0.0_wp
        first = .FALSE.
      END IF
      dmax = MAX(dmax, MAXVAL(ABS(row(2:4) - r0)))
    END DO
    CLOSE (u)
  END SUBROUTINE two_objects_drift

  SUBROUTINE coupled_force(path, nstep, f0, dmax_rel)
    !! The coupled aggregate's static start (OpenFAST host environment): the fairlead load, and
    !! the largest relative change of it over nstep still steps of 0.025 s.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: nstep
    REAL(wp), INTENT(OUT) :: f0(3), dmax_rel
    TYPE(CD_AGG_ModuleType) :: agg
    REAL(wp), ALLOCATABLE :: pos(:, :), vel(:, :), acc(:, :), ld(:, :), p0(:, :)
    INTEGER :: es, ncp, n, it
    LOGICAL :: conv, stalled
    CHARACTER(1024) :: em
    f0 = 0.0_wp
    dmax_rel = HUGE(1.0_wp)
    CALL CD_AGG_Init_From_Deck(agg, path, 0.025_wp, es, em, env_gravity=G, env_rho_water=RHOW, &
                               env_wtrdpth=200.0_wp)
    CALL check(es == CD_AGG_OK, path//': coupled static start: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    ncp = CD_AGG_NMovingPoints(agg, es, em)
    ALLOCATE (pos(3, ncp), vel(3, ncp), acc(3, ncp), ld(3, ncp), p0(3, ncp))
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, ld, es, em)
    f0 = ld(:, 1)
    p0 = pos
    vel = 0.0_wp
    acc = 0.0_wp
    dmax_rel = 0.0_wp
    DO n = 1, nstep
      CALL CD_AGG_Step_Moving(agg, 0.025_wp, p0, vel, acc, conv, stalled, it, es, em)
      IF (es /= CD_AGG_OK) THEN
        CALL check(.FALSE., path//': coupled still step: '//TRIM(em))
        EXIT
      END IF
      CALL CD_AGG_CalcOutput(agg, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, ld, es, em)
      vel = 0.0_wp
      acc = 0.0_wp
      dmax_rel = MAX(dmax_rel, NORM2(ld(:, 1) - f0)/NORM2(f0))
    END DO
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE coupled_force
END PROGRAM test_static_dry_weight
