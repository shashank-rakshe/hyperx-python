! File: tests/test_torsion_body_passes.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_torsion_body_passes
  !! The static passes of a finite-EI cable restrained in torsion between two moored Rigid6 bodies
  !! (bodyIC static) converge at every pretwist. The bodies (20 t, three mooring legs each) are each
  !! other turned 180 deg about the vertical axis between them; the cable (64 m, 40
  !! elements, EA 5e8 N, EI 2e4 N m2, GJ 5e4 N m2) is clamped (Rigid) or bending-pinned at both
  !! ends and Rigid in torsion, with the pretwist at End B. The passes compare the change of the
  !! cable's end loads with 1e-10 of their scale, but each pass balances the bodies only to the
  !! core solve's tolerance, 1e-9 of its own scale (the bodies' net weight, 13 times the cable end
  !! force here): the change could not fall below 1-4e-9 and the passes stopped after 60 at 360
  !! deg (Rigid) and 300 deg (Pinned), the torque settled to six digits from the fourth pass. The
  !! passes now stop at the resolution the core leaves (four times its residual load).
  !!   1. Rigid ends, 360 deg, and Pinned ends, 300 deg (both failed): the static start is
  !!      found;
  !!   2. it is the symmetric equilibrium (the deck's symmetry, which the passes do not impose):
  !!      body 2's pose is body 1's turned 180 deg about the vertical axis, to 1e-6 m and deg, and
  !!      the end tensions are equal to 1e-6;
  !!   3. a still run of 0.5 s holds it: the poses within 2e-6 m and deg, the torque within 1e-6 of
  !!      its start.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  INTEGER :: nfail = 0

  CALL pair_case('tbp_rigid_360', 'Rigid', 360)
  CALL pair_case('tbp_pinned_300', 'Pinned', 300)
  IF (nfail > 0) THEN
    PRINT '(I0,A)', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  PRINT '(A)', 'all torsion body-pass checks passed'

CONTAINS

  SUBROUTINE pair_case(root, conn, pretwist)
    !! Run the pair, then the symmetry and stillness gates on its .out (Body1/Body2 P/R, FairTen7,
    !! AnchTen7, Torq7N1).
    CHARACTER(*), INTENT(IN) :: root, conn
    INTEGER, INTENT(IN) :: pretwist
    REAL(wp) :: row(16), first(16), drift(16), sym
    INTEGER :: u, ios, es, nrow
    LOGICAL :: conv
    CHARACTER(512) :: em
    CHARACTER(4096) :: buf
    CALL write_pair(root//'.dat', conn, pretwist)
    CALL CD_Run_Deck_Driver(root//'.dat', root, conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, root//': the static passes converge and the run ends: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE=root//'.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    READ (u, '(A)') buf
    READ (u, '(A)') buf
    nrow = 0
    drift = 0.0_wp
    DO
      READ (u, *, IOSTAT=ios) row
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      IF (nrow == 1) first = row
      drift = MAX(drift, ABS(row - first))
    END DO
    CLOSE (u)
    ! body 2 = body 1 turned 180 deg about z: (x, y, z) -> (-x, -y, z), rotations (rx, ry, rz) ->
    ! (-rx, -ry, rz)
    sym = MAXVAL(ABS([first(2) + first(8), first(3) + first(9), first(4) - first(10), first(5) + first(11), &
                      first(6) + first(12), first(7) - first(13)]))
    PRINT '(A,ES10.3,A,ES10.3,A,ES10.3,A,ES14.7,A)', '  '//root//': symmetry ', sym, ', pose drift ', &
      MAXVAL(drift(2:13)), ', torque drift ', drift(16), ' (torque ', first(16), ' N m)'
    CALL require(sym <= 1.0e-6_wp, root//': the start is the mirror-symmetric equilibrium')
    CALL require(ABS(first(14) - first(15)) <= 1.0e-6_wp*first(14), root//': equal end tensions')
    CALL require(ABS(row(1) - 0.5_wp) < 1.0e-9_wp .AND. MAXVAL(drift(2:13)) <= 2.0e-6_wp, &
                 root//': the still run holds the poses')
    CALL require(drift(16) <= 1.0e-6_wp*ABS(first(16)), root//': the still run holds the torque')
  END SUBROUTINE pair_case

  SUBROUTINE write_pair(path, conn, pretwist)
    !! The two moored bodies at x = -30 and 30 m, the cable between their points 13 and 14.
    CHARACTER(*), INTENT(IN) :: path, conn
    INTEGER, INTENT(IN) :: pretwist
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'torsion body passes'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 0 0 0 0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cab 0.2 60 500000000 -1 20000 100000000 50000 1 0.3 1.2 0 1 0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 -30 0 -20 0 0 0 20000 40 0 2000000 2000000 8 0.5 35000 35000 35000'
    WRITE (u, '(A)') '2 Rigid6 30 0 -20 0 0 0 20000 40 0 2000000 2000000 8 0.5 35000 35000 35000'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 -1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '2 Body1 0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '3 Body1 0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -70.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed -10.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed -10.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '7 Body2 1.5 0.0 -2.0 0 0 0 0'
    WRITE (u, '(A)') '8 Body2 -0.75 1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '9 Body2 -0.75 -1.299 -2.0 0 0 0 0'
    WRITE (u, '(A)') '10 Fixed 70.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '11 Fixed 10.0 34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '12 Fixed 10.0 -34.641 -100.0 0 0 0 0'
    WRITE (u, '(A)') '13 Body1 0.0 0.0 -3.0 0 0 0 0'
    WRITE (u, '(A)') '14 Body2 0.0 0.0 -3.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    DO k = 1, 3
      WRITE (u, '(I0,A,I0,A,I0,A)') k, ' ', k, ' ', k + 3, ' -'
    END DO
    DO k = 4, 6
      WRITE (u, '(I0,A,I0,A,I0,A)') k, ' ', k + 3, ' ', k + 6, ' -'
    END DO
    WRITE (u, '(A)') '7 13 14 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    DO k = 1, 6
      WRITE (u, '(I0,A)') k, ' poly 86.85 20'
    END DO
    WRITE (u, '(A)') '7 cab 64 40'
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '7 A '//conn//' 0.7071067811865476 0.0 -0.7071067811865476 Rigid 0 1 0 0'
    WRITE (u, '(A,I0)') '7 B '//conn//' 0.7071067811865476 0.0 0.7071067811865476 Rigid 0 1 0 ', pretwist
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '0.5 TMax'
    WRITE (u, '(A)') 'static bodyIC'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    DO k = 1, 2
      WRITE (u, '(A,I0,A)') 'Body', k, 'Px'
      WRITE (u, '(A,I0,A)') 'Body', k, 'Py'
      WRITE (u, '(A,I0,A)') 'Body', k, 'Pz'
      WRITE (u, '(A,I0,A)') 'Body', k, 'Rx'
      WRITE (u, '(A,I0,A)') 'Body', k, 'Ry'
      WRITE (u, '(A,I0,A)') 'Body', k, 'Rz'
    END DO
    WRITE (u, '(A)') 'FairTen7'
    WRITE (u, '(A)') 'AnchTen7'
    WRITE (u, '(A)') 'Torq7N1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_pair

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
END PROGRAM test_torsion_body_passes
