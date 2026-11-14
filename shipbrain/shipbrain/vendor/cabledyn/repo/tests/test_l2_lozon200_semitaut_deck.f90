! File: tests/test_l2_lozon200_semitaut_deck.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l2_lozon200_semitaut_deck
  !! Regression for the seabed-stiffness continuation fix: the Lozon (2025) Gulf of Maine 200 m
  !! SEMITAUT poly+chain mooring solved through the legacy-compatible deck path (CD_Run_Deck_Driver)
  !! with the PHYSICAL stiff seabed penalty (kBot = 3e6 Pa/m). Before the fix, a stiff penalty at
  !! full strength on the cold catenary seed ill-conditioned the contact Newton for this composite
  !! semitaut (a short grounded chain run under a taut polyester section): the solve returned a
  !! non-converged ~352 kN. The continuation now ramps the seabed penalty with the load, so the
  !! solve converges to the true equilibrium.
  !!
  !! Companion to `l2_lozon200_semitaut` (the OrcaFlex-style line-object path): both entry points
  !! must reach the same fairlead pretension. Scored on the fairlead against the Lozon paper
  !! (Table 13, 1205 kN); the deck-path value ~1204 kN also matches OrcaFlex 11.6c 1199.2 and
  !! the reference Fortran solver 1212.0 to ~1 %.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: FAIR_PAPER = 1205.0_wp, GATE_F = 0.03_wp
  REAL(wp) :: fair_kn, anch_kn, e_fair, t
  INTEGER :: es, u, ios, nfail
  LOGICAL :: conv
  CHARACTER(300) :: em, buf

  nfail = 0
  CALL write_deck('deck_lozon200_md.dat')
  CALL CD_Run_Deck_Driver('deck_lozon200_md.dat', 'deck_lozon200_md', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'stiff-seabed semitaut deck converged: '//TRIM(em))

  fair_kn = 0.0_wp; anch_kn = 0.0_wp
  OPEN (NEWUNIT=u, FILE='deck_lozon200_md.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios == 0) THEN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    IF (ios == 0) READ (buf, *, IOSTAT=ios) t, fair_kn, anch_kn
    CLOSE (u)
    fair_kn = fair_kn*1.0e-3_wp; anch_kn = anch_kn*1.0e-3_wp
  END IF
  CALL require(ios == 0 .AND. fair_kn > 0.0_wp, 'read deck_lozon200_md.out (FairTen1, AnchTen1)')

  e_fair = ABS(fair_kn - FAIR_PAPER)/FAIR_PAPER
  WRITE (*, '(A,F8.1,A,F8.1,A)') '  [Lozon-200m semitaut, deck path, kBot=3e6] fairlead = ', fair_kn, &
    ' kN   anchor = ', anch_kn, ' kN'
  WRITE (*, '(A,F6.3,A)') '  fairlead vs Lozon paper pretension 1205 kN: ', 100*e_fair, '%'
  CALL require(e_fair < GATE_F, 'fairlead pretension within 3% of the Lozon (2025) paper value')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Lozon 200m semitaut poly+chain converges through the deck path at physical kBot'

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
    !! Legacy-compatible deck: composite poly+chain line, fairlead Coupled, anchor Fixed, stiff seabed.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: uu, ii
    OPEN (NEWUNIT=uu, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ii)
    WRITE (uu, '(A)') 'Lozon 200m Gulf of Maine semitaut poly+chain, legacy-style deck, static IC'
    WRITE (uu, '(A)') '--- LINE TYPES ---'
    WRITE (uu, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (uu, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (uu, '(A)') 'poly_182 0.1438 22.42 1.42e8 -1.0 0.0 1.6 1.0 1.0 0.1'
    WRITE (uu, '(A)') 'chain_155 0.2791 480.93 2.058e9 -1.0 0.0 2.4 1.0 1.0 0.0'
    WRITE (uu, '(A)') '--- POINTS ---'
    WRITE (uu, '(A)') 'ID Type X Y Z'
    WRITE (uu, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (uu, '(A)') '1 Fixed 700.0 0.0 -200.0'
    WRITE (uu, '(A)') '2 Coupled 58.0 0.0 -14.0'
    WRITE (uu, '(A)') '--- LINES ---'
    WRITE (uu, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (uu, '(A)') '(-) (-) (-) (-)'
    WRITE (uu, '(A)') '1 2 1 -'
    WRITE (uu, '(A)') '--- SECTIONS ---'
    WRITE (uu, '(A)') 'LineID LineType Length NumSegs'
    WRITE (uu, '(A)') '(-) (-) (m) (-)'
    WRITE (uu, '(A)') '1 poly_182 199.8 20'
    WRITE (uu, '(A)') '1 chain_155 497.7 50'
    WRITE (uu, '(A)') '--- OPTIONS ---'
    WRITE (uu, '(A)') '9.80665 g'
    WRITE (uu, '(A)') '1025.0 rhoW'
    WRITE (uu, '(A)') '200.0 WtrDpth'
    WRITE (uu, '(A)') '3.0e6 kBot'
    WRITE (uu, '(A)') '--- OUTPUTS ---'
    WRITE (uu, '(A)') 'FairTen1 AnchTen1'
    WRITE (uu, '(A)') '--- need this line ---'
    CLOSE (uu)
  END SUBROUTINE write_deck

END PROGRAM test_l2_lozon200_semitaut_deck
