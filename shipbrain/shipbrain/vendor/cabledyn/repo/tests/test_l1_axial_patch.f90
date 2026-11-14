! File: tests/test_l1_axial_patch.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l1_axial_patch
  !! L1-1 patch test (pure axial), scored on the Fortran EI=0 element against the
  !! closed form. A single 2-node element with node 1 at the origin and node 2
  !! displaced by Delta_z along +z is a uniform axial stretch eps = Delta_z / L0 with
  !! no shear/bending/torsion; the internal axial force must equal EA*eps to the
  !! machine-precision gate, equal-and-opposite at the two nodes, with zero off-axis
  !! components. Mirrors the L1-1 benchmark (VALIDATION_SPEC.md).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_CableElem, ONLY: CD_Compute_Cable_Element
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L0 = 1.0_wp, EA = 1.0e3_wp, DZ = 1.0e-4_wp
  REAL(wp), PARAMETER :: GATE = 1.0e-10_wp     ! VALIDATION_SPEC L1-1 machine-precision gate
  INTEGER  :: nfail, es
  REAL(wp) :: nodes(6), Kt(6, 6), fint(6), tension, eps, want, rel, off
  CHARACTER(120) :: em
  nfail = 0

  nodes = [0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, L0 + DZ]   ! node 2 stretched +z
  CALL CD_Compute_Cable_Element(nodes, EA, L0, .FALSE., Kt, fint, tension, es, em)
  CALL require(es == 0, 'elem-ErrStat')

  eps = DZ/L0
  want = EA*eps
  ! axial force on node 2 (+z dof) = +T = EA*eps
  rel = ABS(fint(6) - want)/ABS(want)
  WRITE (*, '(A,ES12.4,A,ES12.4,A,ES12.4)') 'L1-1 axial: f_z = ', fint(6), '  EA*eps = ', want, &
    '  rel err = ', rel
  CALL require(rel < GATE, 'L1-1:axial-force-eq-EA-eps')
  ! equal and opposite on node 1
  CALL require(ABS(fint(3) + want)/ABS(want) < GATE, 'L1-1:reaction-equal-opposite')
  ! off-axis (x,y of both nodes) must vanish
  off = MAX(ABS(fint(1)), ABS(fint(2)), ABS(fint(4)), ABS(fint(5)))
  CALL require(off < GATE*ABS(want) + 1.0e-12_wp, 'L1-1:no-off-axis-force')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Fortran EI=0 element matches the analytical axial patch (L1-1)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', label, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l1_axial_patch
