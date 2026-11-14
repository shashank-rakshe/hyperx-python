! File: tests/test_range_tdp_locator.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_range_tdp_locator
  !! Unit tests of the touchdown locator of CableDyn_RangeOutput on prescribed node
  !! configurations: the monotone quadratic crossing inside the element on convex and concave
  !! stencils, a node reaching the onset height maps to that node from either side (the
  !! location is continuous as a node grounds), and the grounded length TDP<L>Grd is continuous
  !! with the touchdown point.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_RangeOutput, ONLY: CD_RangeLine, CD_Range_TDP_Evaluate, CD_TDP_S, CD_TDP_X, CD_TDP_GRD, CD_TDP_N
  USE CableDyn_SeabedContact, ONLY: CD_SEABED_CONTACT_BLEND
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_convex_stencil()
  CALL case_concave_stencil()
  CALL case_node_at_onset()
  CALL case_grounding_on_a_steep_stencil()
  CALL case_grounded_length_continuity()
  CALL case_end_b()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: CableDyn_RangeOutput touchdown locator'

CONTAINS

  SUBROUTINE expect(got, want, tol, label)
    REAL(wp), INTENT(IN) :: got, want, tol
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. (ABS(got - want) <= tol)) THEN
      WRITE (*, '(A,A,A,ES23.15,A,ES23.15)') 'MISMATCH [', label, ']: got ', got, ' want ', want
      nfail = nfail + 1
    END IF
  END SUBROUTINE expect

  SUBROUTINE locate(clearance, grounded_end, tdp)
    !! Nodes on the x axis at unit spacing, heights = clearance (floor at z = 0).
    REAL(wp), INTENT(IN) :: clearance(:)
    INTEGER, INTENT(IN) :: grounded_end
    REAL(wp), INTENT(OUT) :: tdp(CD_TDP_N)
    TYPE(CD_RangeLine) :: line
    REAL(wp) :: r(3, SIZE(clearance))
    INTEGER :: j
    r = 0.0_wp
    DO j = 1, SIZE(clearance)
      r(1, j) = REAL(j - 1, wp)
      r(3, j) = clearance(j)
    END DO
    line%tdp_ready = .TRUE.
    line%tdp_end = grounded_end
    line%ref_xy = 0.0_wp
    line%ref_dir = [1.0_wp, 0.0_wp]
    CALL CD_Range_TDP_Evaluate(line, r, clearance, tdp)
  END SUBROUTINE locate

  SUBROUTINE case_convex_stencil()
    !! Clearances from the onset height -0.005, 0.01, 1.0 on unit spacing: the line rises sharply
    !! beyond node 2. The unlimited parabola dips below the onset height inside the element;
    !! limited to rise monotonically (zero slope at the grounded node) it crosses once, at
    !! sqrt(0.005/0.015) of the chord, beyond the chord crossing (a third of the way).
    REAL(wp) :: tdp(CD_TDP_N), c(4)
    c = CD_SEABED_CONTACT_BLEND + [-0.005_wp, 0.01_wp, 1.0_wp, 2.0_wp]
    CALL locate(c, 1, tdp)
    CALL expect(tdp(CD_TDP_X), SQRT(0.005_wp/0.015_wp), 1.0e-9_wp, 'convex: the monotone crossing')
    CALL expect(tdp(CD_TDP_GRD), tdp(CD_TDP_S), 1.0e-12_wp, 'convex: grounded length equals the arc from End A')
    ! the same with the first node exactly at the onset height: the TDP is that node
    c(1) = CD_SEABED_CONTACT_BLEND
    CALL locate(c, 1, tdp)
    CALL expect(tdp(CD_TDP_X), 0.0_wp, 1.0e-9_wp, 'convex, node at onset: TDP at the grounded node')
  END SUBROUTINE case_convex_stencil

  SUBROUTINE case_grounding_on_a_steep_stencil()
    !! Node 2 grounds on a stencil that rises sharply beyond node 3 (clearances -0.001, h, 0.01, 1,
    !! 2): the TDP reaches node 2 as h falls to zero from above and stays there as h turns
    !! negative, with no jump while the grounded stencil changes (on the grounded side the
    !! crossing grows as sqrt(-h): continuous but steep, hence the 1e-6 steps).
    REAL(wp) :: tdp(CD_TDP_N), c(5), h, prev
    INTEGER :: k
    prev = -1.0_wp
    DO k = -40, 40
      h = 1.0e-6_wp*REAL(-k, wp)
      c = CD_SEABED_CONTACT_BLEND + [-1.0e-3_wp, h, 0.01_wp, 1.0_wp, 2.0_wp]
      CALL locate(c, 1, tdp)
      IF (prev >= 0.0_wp .AND. ABS(tdp(CD_TDP_X) - prev) > 0.05_wp) THEN
        WRITE (*, '(A,ES12.4,A,ES23.15,A,ES23.15)') 'MISMATCH [steep stencil: TDP jumps] h = ', h, &
          ': ', prev, ' -> ', tdp(CD_TDP_X)
        nfail = nfail + 1
      END IF
      IF (k == 0) CALL expect(tdp(CD_TDP_X), 1.0_wp, 1.0e-9_wp, 'steep stencil: node 2 at the onset height')
      prev = tdp(CD_TDP_X)
    END DO
  END SUBROUTINE case_grounding_on_a_steep_stencil

  SUBROUTINE case_concave_stencil()
    !! A stencil with the line rising more gently: g = -0.5, 0.5, 1.0, 1.5.
    REAL(wp) :: tdp(CD_TDP_N), c(4)
    c = CD_SEABED_CONTACT_BLEND + [-0.5_wp, 0.5_wp, 1.0_wp, 1.5_wp]
    CALL locate(c, 1, tdp)
    ! the parabola crosses before the linear crossing (x = 0.5)
    IF (.NOT. (tdp(CD_TDP_X) > 0.4_wp .AND. tdp(CD_TDP_X) < 0.49_wp)) THEN
      WRITE (*, '(A,ES23.15)') 'MISMATCH [concave: quadratic crossing before the linear one]: x = ', tdp(CD_TDP_X)
      nfail = nfail + 1
    END IF
  END SUBROUTINE case_concave_stencil

  SUBROUTINE case_node_at_onset()
    !! A suspended node that reaches the onset height maps to that node.
    REAL(wp) :: tdp(CD_TDP_N), c(4)
    c = CD_SEABED_CONTACT_BLEND + [-0.5_wp, 1.0e-12_wp, 1.0_wp, 2.0_wp]
    CALL locate(c, 1, tdp)
    CALL expect(tdp(CD_TDP_X), 1.0_wp, 1.0e-6_wp, 'node reaching onset: TDP at that node')
  END SUBROUTINE case_node_at_onset

  SUBROUTINE case_grounded_length_continuity()
    !! Node 2 grounds while node 1 rests: Grd and the arc from End A are continuous (no jump
    !! from 0 to a chord) and equal each other.
    REAL(wp) :: tdp(CD_TDP_N), c(5), h, prev
    INTEGER :: k
    prev = 0.0_wp
    DO k = 0, 12
      h = 0.5_wp*0.5_wp**k
      c = CD_SEABED_CONTACT_BLEND + [-1.0e-3_wp, h, 1.0_wp, 2.0_wp, 3.0_wp]
      CALL locate(c, 1, tdp)
      CALL expect(tdp(CD_TDP_GRD), tdp(CD_TDP_S), 1.0e-12_wp, 'continuity: Grd equals the arc from End A')
      IF (k > 0 .AND. ABS(tdp(CD_TDP_GRD) - prev) > 0.5_wp) THEN
        WRITE (*, '(A,I0)') 'MISMATCH [continuity: jump of Grd while node 2 approaches the seabed] k = ', k
        nfail = nfail + 1
      END IF
      prev = tdp(CD_TDP_GRD)
    END DO
    ! node 2 on the seabed: Grd runs on to the next element, from a value below one chord
    c = CD_SEABED_CONTACT_BLEND + [-1.0e-3_wp, 0.0_wp, 1.0_wp, 2.0_wp, 3.0_wp]
    CALL locate(c, 1, tdp)
    CALL expect(tdp(CD_TDP_GRD), 1.0_wp, 1.0e-5_wp, 'continuity: node 2 at the onset height')
    ! the grounded end itself lifted off: nothing touches
    c = CD_SEABED_CONTACT_BLEND + [1.0e-3_wp, 0.5_wp, 1.0_wp, 2.0_wp, 3.0_wp]
    CALL locate(c, 1, tdp)
    CALL expect(tdp(CD_TDP_GRD), 0.0_wp, 0.0_wp, 'lifted end: Grd = 0')
  END SUBROUTINE case_grounded_length_continuity

  SUBROUTINE case_end_b()
    !! The mirrored configuration gives the same grounded length.
    REAL(wp) :: tdp_a(CD_TDP_N), tdp_b(CD_TDP_N), c(4)
    c = CD_SEABED_CONTACT_BLEND + [-0.005_wp, 0.01_wp, 1.0_wp, 2.0_wp]
    CALL locate(c, 1, tdp_a)
    CALL locate(c(4:1:-1), 2, tdp_b)
    CALL expect(tdp_b(CD_TDP_GRD), tdp_a(CD_TDP_GRD), 1.0e-12_wp, 'End B: grounded length of the mirrored line')
  END SUBROUTINE case_end_b

END PROGRAM test_range_tdp_locator
