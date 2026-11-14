! File: tests/test_pinned_touchdown_stability.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_pinned_touchdown_stability
  !! Regression for an endpoint-tangent collapse in an installed 200 m
  !! floating-wind dynamic power cable.  The production deck builder creates
  !! a pinned-ended finite-EI lazy wave with live seabed contact.  The platform hang-off
  !! is then moved 0.25 m laterally over a smooth 10 s ramp and held.  A correct coupled
  !! model distributes this out-of-plane displacement along the cable.  It must not freeze
  !! the interior lateral DOFs and force the complete offset into the hang-off element,
  !! which collapses the endpoint tangent and drives the axial resultant toward -EA.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_Step_Moving, &
                                         CD_AGG_End, CD_AGG_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_Curvature_Exact, CD_HFMF_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DT = 0.05_wp, T_END = 30.0_wp, RAMP_TIME = 10.0_wp
  REAL(wp), PARAMETER :: SWAY = 0.25_wp, EA = 4.69e8_wp
  REAL(wp), PARAMETER :: MIN_TANGENT_NORM = 0.90_wp
  REAL(wp), PARAMETER :: MAX_ENDPOINT_CURVATURE = 0.20_wp
  INTEGER, PARAMETER :: NSTEPS = NINT(T_END/DT)
  TYPE(CD_AGG_ModuleType) :: agg
  REAL(wp) :: pos(3, 1), vel(3, 1), acc(3, 1), load(3, 1)
  REAL(wp), ALLOCATABLE :: curvature(:)
  REAL(wp) :: mnorm, tension, max_curvature, min_mnorm, min_tension, t, u, neighbour_sway
  INTEGER :: es, hs, s, ni, nn, base, nfail
  LOGICAL :: converged, stalled
  CHARACTER(2048) :: em

  nfail = 0
  CALL write_case('pinned_touchdown_stability.dat')
  CALL CD_AGG_Init_From_Deck(agg, 'pinned_touchdown_stability.dat', DT, es, em)
  CALL require(es == CD_AGG_OK, 'aggregate initialisation: '//TRIM(em))
  IF (es /= CD_AGG_OK) ERROR STOP 1
  CALL require(SIZE(agg%cables) == 1, 'one finite-EI cable was built')
  nn = agg%cables(1)%line%nn
  base = 6*(nn - 1)
  ALLOCATE (curvature(nn))
  CALL CD_AGG_GetMovingPointMesh(agg, pos, vel, acc, load, es, em)
  CALL require(es == CD_AGG_OK, 'initial moving-point mesh: '//TRIM(em))
  vel = 0.0_wp
  acc = 0.0_wp

  min_mnorm = HUGE(1.0_wp)
  min_tension = HUGE(1.0_wp)
  max_curvature = 0.0_wp
  DO s = 1, NSTEPS
    t = REAL(s, wp)*DT
    IF (t < RAMP_TIME) THEN
      u = t/RAMP_TIME
      pos(2, 1) = SWAY*(10.0_wp*u**3 - 15.0_wp*u**4 + 6.0_wp*u**5)
      vel(2, 1) = SWAY*(30.0_wp*u**2 - 60.0_wp*u**3 + 30.0_wp*u**4)/RAMP_TIME
      acc(2, 1) = SWAY*(60.0_wp*u - 180.0_wp*u**2 + 120.0_wp*u**3)/RAMP_TIME**2
    ELSE
      pos(2, 1) = SWAY
      vel(2, 1) = 0.0_wp
      acc(2, 1) = 0.0_wp
    END IF
    CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, converged, stalled, ni, es, em)
    IF (es /= CD_AGG_OK .OR. .NOT. converged) THEN
      CALL require(.FALSE., 'held dynamic step at t='//TRIM(real_text(REAL(s, wp)*DT))//' s: '//TRIM(em))
      EXIT
    END IF
    ! The geometric trace of the centreline at the pinned hang-off: a collapsing endpoint tangent
    ! shows here. The recovered curvature (CD_HFMF_Curvature) is the equilibrium moment over EI,
    ! which a pinned end does not carry, so it cannot detect the collapse.
    CALL CD_HFMF_Curvature_Exact(agg%cables(1), curvature, hs, em)
    IF (hs /= CD_HFMF_OK) THEN
      CALL require(.FALSE., 'curvature evaluation: '//TRIM(em))
      EXIT
    END IF
    mnorm = SQRT(SUM(agg%cables(1)%line%q(base + 4:base + 6)**2))
    tension = EA*(mnorm - 1.0_wp)
    min_mnorm = MIN(min_mnorm, mnorm)
    min_tension = MIN(min_tension, tension)
    max_curvature = MAX(max_curvature, curvature(nn))
    IF (MOD(s, NINT(5.0_wp/DT)) == 0) THEN
      WRITE (*, '(A,F6.1,A,ES12.4,A,ES12.4,A,ES12.4)') '  t=', REAL(s, wp)*DT, &
        ' s  |m_HOP|=', mnorm, '  kappa_HOP=', curvature(nn), '  N_HOP=', tension
    END IF
  END DO

  WRITE (*, '(A,ES12.4,A,ES12.4,A,ES12.4)') 'Pinned-HOP extrema: min |m|=', min_mnorm, &
    '  max kappa=', max_curvature, '  min N=', min_tension
  neighbour_sway = agg%cables(1)%line%q(6*(nn - 2) + 2)
  WRITE (*, '(A,ES12.4,A,ES12.4)') 'Final lateral displacement: HOP=', &
    agg%cables(1)%line%q(base + 2), '  adjacent node=', neighbour_sway
  CALL require(s > NSTEPS, 'completed the full 30 s lateral-offset march')
  CALL require(neighbour_sway > 0.10_wp, 'lateral offset is distributed beyond the hang-off element')
  CALL require(min_mnorm >= MIN_TANGENT_NORM, 'hang-off tangent norm remains physical')
  CALL require(max_curvature <= MAX_ENDPOINT_CURVATURE, 'hang-off curvature remains bounded')
  CALL require(min_tension > -0.10_wp*EA, 'hang-off axial force remains far above -EA')
  CALL CD_AGG_End(agg, es, em)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: pinned installed cable distributes lateral hang-off motion physically'

CONTAINS

  SUBROUTINE require(condition, label)
    LOGICAL, INTENT(IN) :: condition
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. condition) THEN
      WRITE (*, '(A)') 'MISMATCH: '//label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  FUNCTION real_text(value) RESULT(text)
    REAL(wp), INTENT(IN) :: value
    CHARACTER(32) :: text
    WRITE (text, '(F0.3)') value
  END FUNCTION real_text

  SUBROUTINE write_case(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create regression deck')
    WRITE (u, '(A)') 'Pinned installed lazy-wave endpoint stability regression'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'buoy 0.30 60.85 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 5.0 0.0 -14.0'
    WRITE (u, '(A)') '2 Fixed 205.0 0.0 -200.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    ! Exact section-aligned 952-element mesh used by the 200 m reference case.
    WRITE (u, '(A)') '1 bare 171.978 464'
    WRITE (u, '(A)') '1 buoy 60.000 160'
    WRITE (u, '(A)') '1 bare 121.527 328'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.4 rhoInf'
    WRITE (u, '(A)') 'False adaptive_mesh'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') 'dynamic_solver 1.0e-4 1.0e-14 100 12'
    WRITE (u, '(A)') 'none frictionMu'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_case

END PROGRAM test_pinned_touchdown_stability
