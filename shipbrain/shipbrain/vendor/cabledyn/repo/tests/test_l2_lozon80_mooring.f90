! File: tests/test_l2_lozon80_mooring.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l2_lozon80_mooring
  !! L2 static parity on the shallow (80 m) reference site of Lozon et al. (2025): one of the
  !! three 120-deg all-chain catenary mooring lines of the IEA-15 MW / UMaine VolturnUS-S
  !! semi-submersible. Studless chain (chain_160: diameter 0.288 m, dry mass 512 kg/m,
  !! EA 2.19e9 N, 364.5 m), fairlead at radius 58 m / z = -14 m, anchor on the seabed at
  !! radius 400 m / z = -79.732 m -> horizontal span 342 m, height 65.732 m.
  !!
  !! Solved end to end through the `cabledyn` text-deck driver (the user-facing path).
  !! Scored on the CONVENTION-FREE horizontal force: the anchor tension (= the catenary
  !! horizontal force H, constant along the line) against the independent closed-form
  !! catenary, and the fairlead top-segment tension against the reference lumped-mass
  !! solver's fairlead value. (The reference reports the fairlead NODE tension; the
  !! top-segment tension is lower by ~w x half-segment, so the wider band on the fairlead is
  !! the readout convention, not a model gap -- H is the clean metric.)
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  ! References (kN): closed-form catenary horizontal force (anchor) and the reference
  ! lumped-mass solver fairlead tension (FAIRTEN, node); anchor gate 2%, fairlead gate 5%.
  REAL(wp), PARAMETER :: ANCH_CAT = 456.1_wp, FAIR_REF = 756.3_wp
  REAL(wp), PARAMETER :: GATE_A = 0.02_wp, GATE_F = 0.05_wp
  REAL(wp) :: fair_kn, anch_kn, e_anch, e_fair, t
  INTEGER :: es, u, ios, nfail
  LOGICAL :: conv
  CHARACTER(300) :: em, buf

  nfail = 0
  CALL write_deck('deck_lozon80.dat')
  CALL CD_Run_Deck_Driver('deck_lozon80.dat', 'deck_lozon80', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'Lozon 80m mooring deck converged: '//TRIM(em))

  fair_kn = 0.0_wp; anch_kn = 0.0_wp
  OPEN (NEWUNIT=u, FILE='deck_lozon80.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios == 0) THEN
    READ (u, '(A)', IOSTAT=ios) buf     ! # comment
    READ (u, '(A)', IOSTAT=ios) buf     ! header
    READ (u, '(A)', IOSTAT=ios) buf     ! t=0 data row
    IF (ios == 0) READ (buf, *, IOSTAT=ios) t, fair_kn, anch_kn
    CLOSE (u)
    fair_kn = fair_kn*1.0e-3_wp; anch_kn = anch_kn*1.0e-3_wp
  END IF
  CALL require(ios == 0 .AND. fair_kn > 0.0_wp, 'read deck_lozon80.out (FairTen1, AnchTen1)')

  e_anch = ABS(anch_kn - ANCH_CAT)/ANCH_CAT
  e_fair = ABS(fair_kn - FAIR_REF)/FAIR_REF
  WRITE (*, '(A,F8.1,A,F8.1,A)') '  [Lozon-80m] fairlead(top-seg) = ', fair_kn, ' kN   anchor(H) = ', anch_kn, ' kN'
  WRITE (*, '(A,F6.3,A,F6.3,A)') '  anchor vs closed-form catenary H ', 100*e_anch, '% ; fairlead vs reference ', &
    100*e_fair, '%'
  CALL require(e_anch < GATE_A, 'anchor tension within 2% of the closed-form catenary horizontal force')
  CALL require(e_fair < GATE_F, 'fairlead top-segment tension within 5% of the reference fairlead value')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Lozon 80m IEA-15MW VolturnUS-S catenary mooring static parity'

CONTAINS

  SUBROUTINE write_deck(path)
    !! One 80 m all-chain catenary line (fairlead radius 58 / z=-14 -> anchor radius 400 / z=-79.732).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: uu, ii
    OPEN (NEWUNIT=uu, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ii)
    WRITE (uu, '(A)') 'Lozon 80m IEA-15MW VolturnUS-S all-chain mooring, static IC'
    WRITE (uu, '(A)') '--- LINE TYPES ---'
    WRITE (uu, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (uu, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (uu, '(A)') 'chain_160 0.288 512.0 2.19e9 -1.0 0.0 2.4 1.0 1.0 0.0'
    WRITE (uu, '(A)') '--- POINTS ---'
    WRITE (uu, '(A)') 'ID Type X Y Z'
    WRITE (uu, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (uu, '(A)') '1 Fixed 400.0 0.0 -79.732'
    WRITE (uu, '(A)') '2 Coupled 58.0 0.0 -14.0'
    WRITE (uu, '(A)') '--- LINES ---'
    WRITE (uu, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (uu, '(A)') '(-) (-) (-) (-)'
    WRITE (uu, '(A)') '1 2 1 -'
    WRITE (uu, '(A)') '--- SECTIONS ---'
    WRITE (uu, '(A)') 'LineID LineType Length NumSegs'
    WRITE (uu, '(A)') '(-) (-) (m) (-)'
    WRITE (uu, '(A)') '1 chain_160 364.5 40'
    WRITE (uu, '(A)') '--- OPTIONS ---'
    WRITE (uu, '(A)') '9.80665 g'
    WRITE (uu, '(A)') '1025.0 rhoW'
    WRITE (uu, '(A)') '79.732 WtrDpth'
    WRITE (uu, '(A)') '3.0e6 kBot'
    WRITE (uu, '(A)') '--- OUTPUTS ---'
    WRITE (uu, '(A)') 'FairTen1 AnchTen1'
    WRITE (uu, '(A)') '--- need this line ---'
    CLOSE (uu)
  END SUBROUTINE write_deck

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l2_lozon80_mooring
