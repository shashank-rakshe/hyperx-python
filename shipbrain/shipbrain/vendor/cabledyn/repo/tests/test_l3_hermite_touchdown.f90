! File: tests/test_l3_hermite_touchdown.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_hermite_touchdown
  !! L3-4 finite-EI (bending) touchdown static gate on the PRODUCTION cubic-Hermite bending-cable
  !! path. A stiff submerged power-cable section (EI > 0) is solved to grounded static equilibrium
  !! on the penalty seabed, the regime an EI=0 chain cannot represent: the line touches down
  !! (length > chord) so the touchdown boundary layer -- where bending matters most -- is
  !! exercised. Seeded by the INDEPENDENT analytic grounded catenary (positions + chord unit
  !! tangents); no reference-solver state enters the initial condition.
  !!
  !! Scored against an independent OrcaFlex static solution of the same EI>0 line:
  !! (1) the catenary-dominated END TENSIONS, read as EA(|m|-1) at the end nodes (the material
  !!     tangent magnitude carries the axial stretch; the convention the closed-form axial-drag
  !!     arbiter validated to 0.03%): anchor gate < 5%, fairlead gate < 3%;
  !! (2) the finite-EI DIFFERENTIATOR -- the geometric centreline curvature, with CableDyn's
  !!     nodal curvature resampled onto OrcaFlex's segment-midpoint arc grid (matching result
  !!     locations, so the touchdown peak is compared on physics, not on a half-element sampling
  !!     offset): max-curvature gate < 2%. The material bend moment on this path is EI*kappa by
  !!     construction, so its parity IS the curvature parity (printed, gated once).
  !!
  !! OrcaFlex reference (OrcaFlex 11.6c static run of the same riser; script not in the repository):
  !!   anchor = 11772.6796402543 N, fairlead = 21794.490849446556 N,
  !!   max curvature = 0.01751101809112536 1/m, max bend moment = 2101.322170935044 N.m.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: G = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: EA_V = 7.0e8_wp, EI_V = 1.2e5_wp
  REAL(wp), PARAMETER :: MASS = 120.0_wp, DIAM = 0.35_wp
  REAL(wp), PARAMETER :: WATER_DEPTH = 50.0_wp, TOTAL_LEN = 120.0_wp, ANCHOR_X = 100.0_wp
  ! Same physical contact stiffness as the OrcaFlex-matched legacy case (KN_BASE * DIAM per node
  ! and per tributary length; the Hermite solve multiplies by trib(a) internally).
  REAL(wp), PARAMETER :: KN_BASE = 1.0e5_wp
  INTEGER, PARAMETER :: NE = 60, NN = NE + 1
  REAL(wp), PARAMETER :: ORCA_ANCHOR = 11772.6796402543_wp
  REAL(wp), PARAMETER :: ORCA_FAIRLEAD = 21794.490849446556_wp
  REAL(wp), PARAMETER :: ORCA_CURV_MAX = 0.01751101809112536_wp
  REAL(wp), PARAMETER :: ORCA_MOM_MAX = 2101.322170935044_wp
  REAL(wp), PARAMETER :: ORCA_ANCHOR_RTOL = 0.05_wp
  REAL(wp), PARAMETER :: ORCA_FAIRLEAD_RTOL = 0.03_wp
  REAL(wp), PARAMETER :: BEND_RTOL = 0.02_wp

  REAL(wp) :: anchor(3), fairlead(3)
  REAL(wp), ALLOCATABLE :: l0(:), ea(:), ei(:), w(:), mpl(:), diam_a(:)
  REAL(wp), ALLOCATABLE :: cat_flat(:), seed(:), q(:), curv(:), arc(:)
  INTEGER, ALLOCATABLE :: fixed(:)
  REAL(wp) :: h, grounded_len, res, tang(3), tmag
  REAL(wp) :: t_anchor, t_fair, cd_curv_max, tgt
  REAL(wp) :: anchor_err, fairlead_err, curv_err
  INTEGER :: i, k, e, es, iters, nfail
  CHARACTER(300) :: em

  nfail = 0
  anchor = [ANCHOR_X, 0.0_wp, -WATER_DEPTH]
  fairlead = [0.0_wp, 0.0_wp, 0.0_wp]

  ALLOCATE (l0(NE), ea(NE), ei(NE), w(NE), mpl(NE), diam_a(NE))
  l0 = TOTAL_LEN/REAL(NE, wp)
  ea = EA_V; ei = EI_V; mpl = MASS; diam_a = DIAM
  CALL CD_Submerged_Weight(mpl, diam_a, RHO, G, w, es, em)
  CALL require(es == 0 .AND. ALL(w > 0.0_wp), 'submerged self weight')

  ! Independent analytic grounded-catenary seed: positions from the closed form, material
  ! tangents from normalised node-to-node chords (one-sided at the ends).
  ALLOCATE (cat_flat(3*NN), seed(6*NN), q(6*NN), curv(NN), arc(NN))
  CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, cat_flat, h, grounded_len, es, em)
  CALL require(es == CD_CAT_OK, 'analytical grounded-catenary seed')
  CALL require(grounded_len > 10.0_wp, 'grounded catenary has real touchdown length')
  DO i = 1, NN
    seed(6*(i - 1) + 1:6*(i - 1) + 3) = cat_flat(3*(i - 1) + 1:3*(i - 1) + 3)
    IF (i == 1) THEN
      tang = cat_flat(4:6) - cat_flat(1:3)
    ELSE IF (i == NN) THEN
      tang = cat_flat(3*NN - 2:3*NN) - cat_flat(3*NN - 5:3*NN - 3)
    ELSE
      tang = cat_flat(3*i + 1:3*i + 3) - cat_flat(3*(i - 2) + 1:3*(i - 2) + 3)
    END IF
    seed(6*(i - 1) + 4:6*(i - 1) + 6) = tang/NORM2(tang)
  END DO

  ! Pin both end positions (anchor node 1, fairlead node NN); planar x-z (r_y, m_y everywhere);
  ! material tangents free at both ends (pinned, moment-free ends -- the OrcaFlex end condition).
  ALLOCATE (fixed(6 + 2*NN))
  fixed(1:3) = [1, 2, 3]
  fixed(4:6) = [6*(NN - 1) + 1, 6*(NN - 1) + 2, 6*(NN - 1) + 3]
  k = 6
  DO i = 1, NN
    fixed(k + 1) = 6*(i - 1) + 2; fixed(k + 2) = 6*(i - 1) + 5; k = k + 2
  END DO

  CALL CD_HermiteCable_Static_Solve(l0, ea, ei, w, seed, fixed, -WATER_DEPTH, KN_BASE*DIAM, &
                                    6, 150, 1.0e-7_wp, 0.6_wp, q, curv, res, iters, es, em)
  CALL require(es == CD_HCSTAT_OK, 'Hermite touchdown solve converged: '//TRIM(em))
  WRITE (*, '(A,I0,A,ES10.3)') 'L3-4H solve: ', iters, ' Newton iterations, residual ', res

  ! interior touchdown beyond the pinned anchor: a grounded span must exist
  CALL require(MINVAL([(q(6*(e - 1) + 3), e=2, NE)]) <= -WATER_DEPTH + 0.5_wp, &
               'Hermite solution still has a grounded span')

  ! End tensions from the material-tangent stretch: T = EA (|m| - 1).
  tmag = NORM2(q(4:6))
  t_anchor = EA_V*(tmag - 1.0_wp)
  tmag = NORM2(q(6*(NN - 1) + 4:6*(NN - 1) + 6))
  t_fair = EA_V*(tmag - 1.0_wp)
  anchor_err = ABS(t_anchor - ORCA_ANCHOR)/ORCA_ANCHOR
  fairlead_err = ABS(t_fair - ORCA_FAIRLEAD)/ORCA_FAIRLEAD
  WRITE (*, '(A,F10.3,A,F7.3,A)') 'L3-4H anchor   = ', t_anchor*1.0e-3_wp, ' kN   OrcaFlex err = ', &
    100.0_wp*anchor_err, '%'
  WRITE (*, '(A,F10.3,A,F7.3,A)') 'L3-4H fairlead = ', t_fair*1.0e-3_wp, ' kN   OrcaFlex err = ', &
    100.0_wp*fairlead_err, '%'
  CALL require(anchor_err < ORCA_ANCHOR_RTOL, 'anchor tension within 5% OrcaFlex gate')
  CALL require(fairlead_err < ORCA_FAIRLEAD_RTOL, 'fairlead tension within 3% OrcaFlex gate')

  ! Max curvature, resampled onto OrcaFlex's segment-midpoint arc grid [1, 3, ..., 119].
  DO i = 1, NN
    arc(i) = REAL(i - 1, wp)*l0(1)
  END DO
  cd_curv_max = 0.0_wp
  DO e = 1, NE
    tgt = REAL(2*e - 1, wp)
    cd_curv_max = MAX(cd_curv_max, interp1(tgt, arc, curv))
  END DO
  curv_err = ABS(cd_curv_max - ORCA_CURV_MAX)/ORCA_CURV_MAX
  WRITE (*, '(A,F9.6,A,F7.3,A)') 'L3-4H max curvature = ', cd_curv_max, ' /m   OrcaFlex err = ', &
    100.0_wp*curv_err, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A)') 'L3-4H max bend moment EI*kappa = ', EI_V*cd_curv_max, &
    ' N.m   (OrcaFlex ', ORCA_MOM_MAX, ' N.m; same relative parity as curvature)'
  CALL require(ORCA_CURV_MAX > 1.0e-3_wp .AND. cd_curv_max > 1.0e-3_wp, 'a real bending response is present')
  CALL require(curv_err < BEND_RTOL, 'max curvature within 2% OrcaFlex gate')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-4 finite-EI touchdown parity (tensions + curvature) on the cubic-Hermite path'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', TRIM(label), ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  REAL(wp) FUNCTION interp1(xq, x, y) RESULT(yq)
    !! Clamped piecewise-linear interpolation: x strictly increasing; xq clamped to [x(1), x(n)].
    REAL(wp), INTENT(IN) :: xq, x(:), y(:)
    INTEGER :: n, i
    REAL(wp) :: t
    n = SIZE(x)
    IF (xq <= x(1)) THEN
      yq = y(1); RETURN
    ELSE IF (xq >= x(n)) THEN
      yq = y(n); RETURN
    END IF
    DO i = 1, n - 1
      IF (xq >= x(i) .AND. xq <= x(i + 1)) THEN
        t = (xq - x(i))/(x(i + 1) - x(i))
        yq = y(i) + t*(y(i + 1) - y(i)); RETURN
      END IF
    END DO
    yq = y(n)
  END FUNCTION interp1

END PROGRAM test_l3_hermite_touchdown
