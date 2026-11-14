! File: tests/test_torsion_coupling_still.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_torsion_coupling_still
  !! A held line under strong torque-tension coupling stays still in its dynamics at the default
  !! dtM (0.05 s) and dynamic tolerance (1e-8). The line: 50 m neutral cable, EA 4.69e8 N, GJ 5e4
  !! N m2, Irn 0.1174 kg m (the nodal twist), 25 elements, stretched by eps = 1.07e-4 between a
  !! held Coupled End A and a Fixed End B, the coupling K = r sqrt(EA GJ). Its static start is exact,
  !! so a step of the held line is a residual at the round-off of its forces: the convergence norm
  !! must place its floor at the rounding of the axial force of the whole axial stiffness (the
  !! kernel's EA - K^2/GJ plus the coupling's K^2/GJ) and of the element torque, whose coupling
  !! share (K/GJ)(l - l0) is formed from coordinates (|K| eps max|x|/l0). Before, at |r| >= 0.85
  !! (and at -0.8 with one end free) a step failed, "Newton did not converge, ||G|| = 2.4e-8 >
  !! tol = 1e-8", within 0.05-0.9 s.
  !!   1. Both ends Rigid in torsion, Pretwist 90 deg, r = 0.85, 0.9, 0.95, 0.99: the run of 2 s
  !!      holds, and its start is the section law T = EA eps + K Phi/L0, M = GJ Phi/L0 + K eps
  !!      (relative 1e-6).
  !!   2. Both ends Rigid, r = -0.8, -0.9: the opposite-sense coupling compresses the line, which
  !!      buckles into a twisted bow; the run of 2 s holds its start.
  !!   3. End B Free in torsion, r = -0.8, -0.9: the stretch twists the line, so T = (EA -
  !!      K^2/GJ) eps and M = 0; the run of 10 s holds.
  !! Holding: every tension and torque channel stays within 1e-6 of the scale of its parts (EA eps +
  !! |K| Phi/L0 for a tension, GJ Phi/L0 + |K| eps for a torque) of its start.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, GJ = 5.0e4_wp, SPAN = 50.0_wp, L0 = 49.9946700778_wp
  REAL(wp), PARAMETER :: PHI = 0.5_wp*PI
  INTEGER :: nfail = 0

  CALL still_case('tcst_p085', 0.85_wp, .FALSE., .TRUE.)
  CALL still_case('tcst_p090', 0.90_wp, .FALSE., .TRUE.)
  CALL still_case('tcst_p095', 0.95_wp, .FALSE., .TRUE.)
  CALL still_case('tcst_p099', 0.99_wp, .FALSE., .TRUE.)
  CALL still_case('tcst_m080', -0.80_wp, .FALSE., .FALSE.)
  CALL still_case('tcst_m090', -0.90_wp, .FALSE., .FALSE.)
  CALL still_case('tcst_fm080', -0.80_wp, .TRUE., .TRUE.)
  CALL still_case('tcst_fm090', -0.90_wp, .TRUE., .TRUE.)
  IF (nfail > 0) THEN
    PRINT '(I0,A)', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  PRINT '(A)', 'all held coupled-line checks passed'

CONTAINS

  SUBROUTINE still_case(root, r, free_b, straight)
    !! Run the case, check the start against the section law (straight) and the run's stillness.
    CHARACTER(*), INTENT(IN) :: root
    REAL(wp), INTENT(IN) :: r
    LOGICAL, INTENT(IN) :: free_b, straight
    REAL(wp) :: k, eps, t_ref, m_ref, t_sc, m_sc, row(5), first(5), dev(4)
    INTEGER :: u, ios, es, nrow
    LOGICAL :: conv
    CHARACTER(512) :: em
    CHARACTER(4096) :: buf
    CHARACTER(160) :: what
    k = r*SQRT(EA*GJ)
    eps = SPAN/L0 - 1.0_wp
    CALL write_case(root//'.dat', k, free_b)
    CALL CD_Run_Deck_Driver(root//'.dat', root, conv, es, em)
    IF (free_b) THEN
      WRITE (what, '(A,F6.2,A)') root//' (K/sqrt(EA GJ) = ', r, ', End B free)'
    ELSE
      WRITE (what, '(A,F6.2,A)') root//' (K/sqrt(EA GJ) = ', r, ', both Rigid)'
    END IF
    CALL require(es == CD_DECKDRV_OK .AND. conv, TRIM(what)//' runs: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    IF (free_b) THEN
      t_ref = (EA - k*k/GJ)*eps
      m_ref = 0.0_wp
      t_sc = EA*eps
      m_sc = ABS(k)*eps
    ELSE
      t_ref = EA*eps + k*PHI/L0
      m_ref = GJ*PHI/L0 + k*eps
      t_sc = EA*eps + ABS(k)*PHI/L0
      m_sc = GJ*PHI/L0 + ABS(k)*eps
    END IF
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    READ (u, '(A)') buf
    READ (u, '(A)') buf
    nrow = 0
    dev = 0.0_wp
    first = 0.0_wp
    DO
      READ (u, *, IOSTAT=ios) row
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      IF (nrow == 1) first = row
      dev = MAX(dev, ABS(row(2:5) - first(2:5)))
    END DO
    CLOSE (u)
    PRINT '(A,ES11.3,A,4ES12.4)', '  '//root//': t_end ', row(1), ' s, max |change| T_A T_B M_A M_B ', dev
    CALL require(ABS(row(1) - MERGE(10.0_wp, 2.0_wp, free_b)) < 1.0e-9_wp, TRIM(what)//' reaches TMax')
    CALL require(MAXVAL(dev(1:2)) <= 1.0e-6_wp*t_sc .AND. MAXVAL(dev(3:4)) <= 1.0e-6_wp*m_sc, &
                 TRIM(what)//' holds its start')
    IF (straight) THEN
      PRINT '(A,4ES16.8)', '    start T, M and the section law ', first(2), first(4), t_ref, m_ref
      CALL require(ABS(first(2) - t_ref) <= 1.0e-6_wp*t_sc .AND. ABS(first(3) - t_ref) <= 1.0e-6_wp*t_sc, &
                   TRIM(what)//' starts at the section tension')
      CALL require(ABS(first(4) - m_ref) <= 1.0e-6_wp*m_sc .AND. ABS(first(5) - m_ref) <= 1.0e-6_wp*m_sc, &
                   TRIM(what)//' starts at the section torque')
    END IF
  END SUBROUTINE still_case

  SUBROUTINE write_case(path, k, free_b)
    !! The held line: End A Coupled at the origin (no motion), End B Fixed 50 m along +x, both
    !! ends clamped along x; torsion Rigid at End A and Rigid (Pretwist 90 deg) or Free at End B.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: k
    LOGICAL, INTENT(IN) :: free_b
    INTEGER :: u
    CHARACTER(64) :: gjcol
    WRITE (gjcol, '(ES12.5,A,ES17.10)') GJ, '|', k
    gjcol = remove_blanks(gjcol)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'held line under torque-tension coupling'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cab 0.16 20.6088478075 469000000 -0.8 20000 90000000 '//TRIM(gjcol)// &
      ' 0.0587 0.1174 1.2 0.1 1 0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0 0 -50 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 50 0 -50 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 49.9946700778 25'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A Rigid 1 0 0 Rigid 0 1 0 0'
    IF (free_b) THEN
      WRITE (u, '(A)') '1 B Rigid 1 0 0 Free 0 1 0 0'
    ELSE
      WRITE (u, '(A)') '1 B Rigid 1 0 0 Rigid 0 1 0 90'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') MERGE('10 TMax', ' 2 TMax', free_b)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') 'AnchTen1'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') 'Torq1N26'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_case

  PURE FUNCTION remove_blanks(s) RESULT(r)
    CHARACTER(*), INTENT(IN) :: s
    CHARACTER(LEN(s)) :: r
    INTEGER :: i, k
    r = ''
    k = 0
    DO i = 1, LEN(s)
      IF (s(i:i) /= ' ') THEN
        k = k + 1
        r(k:k) = s(i:i)
      END IF
    END DO
  END FUNCTION remove_blanks

  SUBROUTINE require(ok, what)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: what
    IF (ok) THEN
      PRINT '(A)', 'PASS: '//what
    ELSE
      PRINT '(A)', 'FAIL: '//what
      nfail = nfail + 1
    END IF
  END SUBROUTINE require
END PROGRAM test_torsion_coupling_still
