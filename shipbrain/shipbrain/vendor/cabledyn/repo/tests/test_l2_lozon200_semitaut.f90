! File: tests/test_l2_lozon200_semitaut.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l2_lozon200_semitaut
  !! L2 static parity on the intermediate-depth (200 m) reference site of Lozon et al. (2025):
  !! the Gulf of Maine SEMITAUT mooring -- a two-section composite line, 181.8 mm polyester
  !! (199.8 m, from the fairlead) + 155 mm R4 studless chain (497.7 m, to the anchor). This is
  !! NOT the original all-chain VolturnUS-S catenary (that is `l2_volturnus_mooring`); it is
  !! Lozon's semitaut redesign. Fairlead at radius 58 m / z = -14 m, anchor on the seabed at
  !! radius 700 m / z = -200 m -> horizontal span 642 m, rise 186 m.
  !!
  !! Solved end to end through the `cabledyn` OrcaFlex-style line-object driver
  !! (CD_Run_Line_Static_Driver) on the COMPOSITE line-object path -- mixed line types + mesh
  !! densities in one line, meshed, analytical-catenary seeded, and load-continuation solved,
  !! the same path the 800 m chain-polyester-chain mooring uses. Scored on the fairlead
  !! pretension (the last element's tension) against the Lozon (2025) MoorPy value. Reference
  !! agreement is 4-way: paper 1205 kN / OrcaFlex 11.6c 1199.2 / reference Fortran solver 1212.0 / CableDyn
  !! ~1206 -- all within ~1 %.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Driver, ONLY: CD_Run_Line_Static_Driver, CD_DRIVER_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: FAIR_PAPER = 1205.0_wp   ! Lozon (2025) Table 13 pretension (kN)
  REAL(wp), PARAMETER :: GATE_F = 0.03_wp         ! 3% band (paper/OrcaFlex/reference span ~1 %)
  REAL(wp) :: fair_kn, anch_kn, e_fair, t
  INTEGER :: es, u, ios, nfail, idx, na, nb, n_elem
  LOGICAL :: conv
  CHARACTER(20) :: tag
  CHARACTER(400) :: em, line

  nfail = 0
  CALL write_deck('deck_lozon200.inp')
  CALL CD_Run_Line_Static_Driver('deck_lozon200.inp', 'deck_lozon200.csv', conv, es, em)
  CALL require(es == CD_DRIVER_OK .AND. conv, 'Lozon 200m semitaut mooring deck converged: '//TRIM(em))

  ! parse the CSV: first `elem` row = anchor tension, last `elem` row = fairlead tension (N)
  fair_kn = 0.0_wp; anch_kn = 0.0_wp; n_elem = 0
  OPEN (NEWUNIT=u, FILE='deck_lozon200.csv', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios == 0) THEN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      READ (line, *, IOSTAT=ios) tag
      IF (ios /= 0) CYCLE
      IF (TRIM(tag) == 'elem') THEN
        READ (line, *, IOSTAT=ios) tag, idx, na, nb, t
        IF (ios == 0) THEN
          n_elem = n_elem + 1
          IF (n_elem == 1) anch_kn = t*1.0e-3_wp   ! first element: anchor end
          fair_kn = t*1.0e-3_wp                     ! last element seen: fairlead end
        END IF
      END IF
    END DO
    CLOSE (u)
  END IF
  CALL require(n_elem > 0 .AND. fair_kn > 0.0_wp, 'read deck_lozon200.csv element tensions')

  e_fair = ABS(fair_kn - FAIR_PAPER)/FAIR_PAPER
  WRITE (*, '(A,F8.1,A,F8.1,A)') '  [Lozon-200m semitaut] fairlead = ', fair_kn, ' kN   anchor = ', anch_kn, ' kN'
  WRITE (*, '(A,F6.3,A)') '  fairlead vs Lozon paper pretension 1205 kN: ', 100*e_fair, '%'
  CALL require(e_fair < GATE_F, 'fairlead pretension within 3% of the Lozon (2025) paper value')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Lozon 200m Gulf of Maine semitaut poly+chain mooring static parity'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE write_deck(path)
    !! OrcaFlex-style line-object deck (anchor on the seabed at the origin, fairlead up + across).
    !! Sections anchor -> fairlead: 155 mm chain then 181.8 mm polyester.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: uu, ii
    OPEN (NEWUNIT=uu, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ii)
    WRITE (uu, '(A)') '# Lozon 2025 Gulf of Maine 200 m semitaut mooring: chain + polyester composite'
    WRITE (uu, '(A)') 'gravity 9.80665'
    WRITE (uu, '(A)') 'rho_water 1025.0'
    WRITE (uu, '(A)') 'tension_only F'
    WRITE (uu, '(A)') 'seabed 0.0 1.0e5'
    WRITE (uu, '(A)') 'anchor 0.0 0.0 0.0'
    WRITE (uu, '(A)') 'fairlead 642.0 0.0 186.0'
    WRITE (uu, '(A)') 'line_types 2          # EA  mass_per_len  diameter'
    WRITE (uu, '(A)') '2.058e9 480.93 0.2791 # 1: R4 studless chain 155 mm'
    WRITE (uu, '(A)') '1.42e8  22.42  0.1438 # 2: polyester 181.8 mm (static EA)'
    WRITE (uu, '(A)') 'sections 2            # line_type  length  n_segments'
    WRITE (uu, '(A)') '1 497.7 50            # chain from the anchor'
    WRITE (uu, '(A)') '2 199.8 20            # polyester to the fairlead'
    CLOSE (uu)
  END SUBROUTINE write_deck

END PROGRAM test_l2_lozon200_semitaut
