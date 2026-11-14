! File: tests/test_end_tangent_channels.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_end_tangent_channels
  !! The tangent channels of a finite-EI line read its tangent, the Hermite tangent DOF m = dr/ds
  !! of every node (normalised, End A -> End B), not a difference of node positions. A cable is
  !! clamped at End A (END CONNECTIONS Rigid) along a set direction, swept over declinations of
  !! 120 to 180 deg and azimuths of 0 and 20 deg (a clamp out of the vertical plane of the
  !! ends), and pinned (bending-free) at End B. At the clamp FairDecl, FairAngle, FairIncl,
  !! L1N1Dec and L1N1Azi equal the clamp's angles to round-off, though the line bends sharply
  !! within its first element there; at the pinned end AnchDecl, AnchIncl and the last node's
  !! Dec, and at every interior node Dec, equal the angle of the solution's own tangent. On the
  !! aggregate route, which the C API and the OpenFAST shell share; the standalone outputs use
  !! the same evaluator (check_end_tangent_channels.py).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_End, CD_AGG_OK
  USE CableDyn_DeckDriver, ONLY: CD_Eval_Aggregate_Channel
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: TOL_DEG = 1.0e-9_wp
  REAL(wp), PARAMETER :: DECLINATIONS(5) = [180.0_wp, 165.0_wp, 150.0_wp, 135.0_wp, 120.0_wp]
  REAL(wp), PARAMETER :: AZIMUTHS(2) = [0.0_wp, 20.0_wp]
  INTEGER :: nfail, id, ia
  REAL(wp) :: worst_clamp, worst_node, worst_chord
  ! the case under way
  TYPE(CD_AGG_ModuleType) :: agg
  CHARACTER(96) :: label

  nfail = 0
  worst_clamp = 0.0_wp
  worst_node = 0.0_wp
  worst_chord = 0.0_wp
  DO id = 1, SIZE(DECLINATIONS)
    DO ia = 1, SIZE(AZIMUTHS)
      IF (id == 1 .AND. ia > 1) CYCLE   ! a vertical clamp has no azimuth
      CALL run_case(DECLINATIONS(id), AZIMUTHS(ia))
    END DO
  END DO
  WRITE (*, '(A,ES10.3,A,ES10.3,A)') 'largest channel error at the clamp ', worst_clamp, &
    ' deg, at the other nodes ', worst_node, ' deg'
  WRITE (*, '(A,F8.3,A)') 'the node-position difference at the clamp is off by up to ', worst_chord, ' deg'
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS'

CONTAINS

  SUBROUTINE run_case(dec_clamp, azi_clamp)
    REAL(wp), INTENT(IN) :: dec_clamp, azi_clamp
    CHARACTER(512) :: em
    CHARACTER(64) :: path, ch
    REAL(wp) :: ez(3), t(3), dec_m, chord(3)
    INTEGER :: es, nn, j, inode

    ez = [SIN(dec_clamp*PI/180.0_wp)*COS(azi_clamp*PI/180.0_wp), &
          SIN(dec_clamp*PI/180.0_wp)*SIN(azi_clamp*PI/180.0_wp), COS(dec_clamp*PI/180.0_wp)]
    path = 'end_tangent_channels.dat'
    CALL write_deck(path, ez)
    WRITE (label, '(A,F6.1,A,F5.1,A)') 'clamp declination ', dec_clamp, ' deg, azimuth ', azi_clamp, ' deg'
    CALL CD_AGG_Init_From_Deck(agg, TRIM(path), 0.05_wp, es, em)
    IF (es /= CD_AGG_OK) THEN
      CALL check(.FALSE., TRIM(label)//': init: '//TRIM(em))
      CALL CD_AGG_End(agg, es, em)
      RETURN
    END IF
    ! the clamped End A (the line's last internal node)
    CALL expect('FairDecl1', dec_clamp, worst_clamp)
    CALL expect('FairAngle1', dec_clamp, worst_clamp)
    CALL expect('FairIncl1', dec_clamp - 90.0_wp, worst_clamp)
    CALL expect('L1N1Dec', dec_clamp, worst_clamp)
    IF (ABS(ez(3)) < 1.0_wp - 1.0e-12_wp) CALL expect('L1N1Azi', azi_clamp, worst_clamp)
    nn = agg%cables(1)%line%nn
    ! what a difference of node positions gives at the clamp
    chord = agg%cables(1)%line%q(6*(nn - 2) + 1:6*(nn - 2) + 3) - agg%cables(1)%line%q(6*(nn - 1) + 1:6*(nn - 1) + 3)
    worst_chord = MAX(worst_chord, ABS(ACOS(chord(3)/NORM2(chord))*180.0_wp/PI - dec_clamp))
    ! every other node, the pinned End B included: the angle of the solution's tangent DOF
    DO j = 2, nn
      inode = nn + 1 - j
      t = -agg%cables(1)%line%q(6*(inode - 1) + 4:6*(inode - 1) + 6)
      dec_m = ACOS(MAX(-1.0_wp, MIN(1.0_wp, t(3)/NORM2(t))))*180.0_wp/PI
      WRITE (ch, '(A,I0,A)') 'L1N', j, 'Dec'
      CALL expect(TRIM(ch), dec_m, worst_node, mesh=.TRUE.)
    END DO
    CALL expect('AnchDecl1', dec_m, worst_node)
    CALL expect('AnchIncl1', dec_m - 90.0_wp, worst_node)
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE run_case

  SUBROUTINE expect(name, want, worst, mesh)
    !! The channel name of the case's line equals want [deg] to TOL_DEG; worst: the largest error.
    CHARACTER(*), INTENT(IN) :: name
    REAL(wp), INTENT(IN) :: want
    REAL(wp), INTENT(INOUT) :: worst
    LOGICAL, INTENT(IN), OPTIONAL :: mesh
    REAL(wp) :: v
    INTEGER :: ese
    CHARACTER(512) :: eme
    IF (PRESENT(mesh)) THEN
      CALL CD_Eval_Aggregate_Channel(name, agg%has_sys, agg%sys%fast%system, agg%cables, agg%line_is_cable, &
                                     agg%line_obj_index, v, ese, eme, mesh_node=mesh)
    ELSE
      CALL CD_Eval_Aggregate_Channel(name, agg%has_sys, agg%sys%fast%system, agg%cables, agg%line_is_cable, &
                                     agg%line_obj_index, v, ese, eme)
    END IF
    IF (ese /= 0) THEN
      CALL check(.FALSE., TRIM(label)//': '//name//': '//TRIM(eme))
      RETURN
    END IF
    worst = MAX(worst, ABS(v - want))
    IF (ABS(v - want) > TOL_DEG) THEN
      WRITE (*, '(4A,F14.9,A,F14.9)') '  ', TRIM(label), ': ', name, v, ' deg, the tangent gives ', want
      CALL check(.FALSE., TRIM(label)//': '//name//' is the angle of the line tangent')
    END IF
  END SUBROUTINE expect

  SUBROUTINE write_deck(path, ez)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: ez(3)
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'tangent channels of a cable clamped at End A'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    WRITE (u, '(A)') 'TypeName Diam MassDenInAir EA BA/-zeta EI Cd_n Cd_t Ca_n Ca_t'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cable 0.2 60.0 1.0e8 -1.0 1.0e4 1.2 0.008 1.0 0.0'
    WRITE (u, '(A)') '--------------------- POINTS -------------------------------------------------'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -10.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 80.0 0.0 -80.0 0 0 0 0'
    WRITE (u, '(A)') '--------------------- LINES --------------------------------------------------'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--------------------- SECTIONS -----------------------------------------------'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cable 125.0 100'
    WRITE (u, '(A)') '--------------------- END CONNECTIONS ----------------------------------------'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
    WRITE (u, '(A,3(1X,ES23.16))') '1 A Rigid', ez
    WRITE (u, '(A)') '--------------------- OPTIONS ------------------------------------------------'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '--------------------- OUTPUTS ------------------------------------------------'
    WRITE (u, '(A)') 'END'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE check(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (ok) RETURN
    nfail = nfail + 1
    WRITE (*, '(2A)') '  FAIL ', TRIM(label)
  END SUBROUTINE check

END PROGRAM test_end_tangent_channels
