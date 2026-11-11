! File: tests/test_l3_orcaflex_finite_ei_static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_orcaflex_finite_ei_static
  !! L3-4 finite-EI (bending) touchdown static gate for the Fortran core. A stiff
  !! submerged power-cable section (EI > 0) is solved to grounded static equilibrium on
  !! the geometrically-exact Cosserat element via the new non-dimensionalised,
  !! continuation + penalty-seabed path (CableDyn_FiniteEIStatic), the regime an EI=0
  !! chain cannot represent. The line touches down (length > chord) so the touchdown
  !! boundary layer -- where bending matters most -- is exercised.
  !!
  !! Two comparisons against an independent OrcaFlex static solution of the same EI>0 line:
  !! (1) the catenary-dominated END TENSIONS (the coarse check, gate < 5% / < 3%); and the
  !! finite-EI DIFFERENTIATOR -- (2) the geometric centreline curvature (CableDyn node
  !! positions resampled onto OrcaFlex's segment-midpoint arc grid) and (3) the MATERIAL
  !! bend moment EI*|K| from the Cosserat rotational DOFs at the element centres (the
  !! locations OrcaFlex reports its bend moment); both bending maxima gate < 2%.
  !!
  !! Independent-implementation regression targets (an independent finite-EI solver on the
  !! same deck; not part of the repository):
  !!   anchor = 11446.294338823825 N, fairlead = 22025.873334108324 N
  !! OrcaFlex reference (OrcaFlex 11.6c static run of the same riser; script not in the repository):
  !!   anchor = 11772.6796402543 N (gate < 5%), fairlead = 21794.490849446556 N (gate < 3%)
  !! Seed checkpoints (the independent implementation's grounded-catenary seed, same deck):
  !!   reference_tangent = (-1, 0, 0); rot(node 31) ~ (0, 0.49130855, 0);
  !!   rot(node 61) ~ (0, 1.01494938, 0).
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_CosseratStatic, ONLY: CosseratSolverConfig
  USE CableDyn_FiniteEIStatic, ONLY: CD_FiniteEI_Touchdown_Seed, CD_Solve_FiniteEI_Touchdown, &
                                     CD_FiniteEI_Centerline_Curvature, CD_FiniteEI_Element_Bend_Moment, &
                                     CD_FEI_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: G = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: EA_V = 7.0e8_wp, EI_V = 1.2e5_wp, GJ_V = 8.0e4_wp
  REAL(wp), PARAMETER :: MASS = 120.0_wp, DIAM = 0.35_wp
  REAL(wp), PARAMETER :: WATER_DEPTH = 50.0_wp, TOTAL_LEN = 120.0_wp, ANCHOR_X = 100.0_wp
  REAL(wp), PARAMETER :: KN_BASE = 1.0e5_wp
  INTEGER, PARAMETER :: NE = 60
  REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
  ! Reference bit-parity targets + OrcaFlex reference scalars.
  REAL(wp), PARAMETER :: reference_ANCHOR = 11446.294338823825_wp
  REAL(wp), PARAMETER :: reference_FAIRLEAD = 22025.873334108324_wp
  REAL(wp), PARAMETER :: ORCA_ANCHOR = 11772.6796402543_wp
  REAL(wp), PARAMETER :: ORCA_FAIRLEAD = 21794.490849446556_wp
  REAL(wp), PARAMETER :: reference_RTOL = 0.005_wp     ! tight: vs the independent implementation
  REAL(wp), PARAMETER :: ORCA_ANCHOR_RTOL = 0.05_wp
  REAL(wp), PARAMETER :: ORCA_FAIRLEAD_RTOL = 0.03_wp
  ! Bending response: the finite-EI differentiator. reference bit-parity targets
  ! + OrcaFlex reference maxima (resampled onto OrcaFlex's segment-midpoint arc grid).
  REAL(wp), PARAMETER :: reference_CURV_MAX = 0.01737376777190502_wp
  REAL(wp), PARAMETER :: reference_MOM_MAX = 2089.4855416480914_wp
  REAL(wp), PARAMETER :: ORCA_CURV_MAX = 0.01751101809112536_wp
  REAL(wp), PARAMETER :: ORCA_MOM_MAX = 2101.322170935044_wp
  REAL(wp), PARAMETER :: BEND_RTOL = 0.02_wp

  REAL(wp) :: anchor(3), fairlead(3)
  REAL(wp), ALLOCATABLE :: l0(:), ea(:), ei(:), gj(:), w(:), mpl(:), diam_a(:)
  REAL(wp), ALLOCATABLE :: cat_flat(:), cat_pos(:, :), q0(:), nodes_ref(:, :), q(:), tension(:)
  REAL(wp), ALLOCATABLE :: arc(:), curv(:), moment(:)
  REAL(wp) :: h, grounded_len, contact_k, anchor_n, fairlead_n
  REAL(wp) :: reference_anchor_err, reference_fairlead_err, orca_anchor_err, orca_fairlead_err
  REAL(wp) :: cd_curv_max, cd_mom_max, tgt, curv_reference_err, curv_orca_err, mom_reference_err, mom_orca_err
  INTEGER :: ndof, e, es, n_stages, nfail
  LOGICAL :: conv, stalled
  CHARACTER(200) :: em
  TYPE(CosseratSolverConfig) :: cfg

  nfail = 0
  anchor = [ANCHOR_X, 0.0_wp, -WATER_DEPTH]
  fairlead = [0.0_wp, 0.0_wp, 0.0_wp]
  ndof = 3*(NE + 1)

  ALLOCATE (l0(NE), ea(NE), ei(NE), gj(NE), w(NE), mpl(NE), diam_a(NE))
  l0 = TOTAL_LEN/REAL(NE, wp)
  ea = EA_V; ei = EI_V; gj = GJ_V; mpl = MASS; diam_a = DIAM

  CALL CD_Submerged_Weight(mpl, diam_a, RHO, G, w, es, em)
  CALL require(es == 0 .AND. ALL(w > 0.0_wp), 'submerged self weight')

  ! Independent analytic grounded-catenary seed (positions); reference-matched.
  ALLOCATE (cat_flat(ndof), cat_pos(3, NE + 1))
  CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, cat_flat, h, grounded_len, es, em)
  CALL require(es == CD_CAT_OK, 'analytical grounded-catenary seed')
  CALL require(grounded_len > 10.0_wp, 'grounded catenary has real touchdown length')
  cat_pos = RESHAPE(cat_flat, [3, NE + 1])

  ! --- seed checkpoint: tangent-aligned rotations vs the reference ---
  ALLOCATE (q0(6*(NE + 1)), nodes_ref(3, NE + 1))
  CALL CD_FiniteEI_Touchdown_Seed(cat_pos, anchor, fairlead, l0, q0, nodes_ref, es, em)
  CALL require(es == CD_FEI_OK, 'tangent-aligned 6-DOF seed builds')
  ! reference rod runs along (-1,0,0): node 61 sits at -TOTAL_LEN x.
  CALL require(ABS(nodes_ref(1, NE + 1) + TOTAL_LEN) < 1.0e-9_wp .AND. &
               ABS(nodes_ref(2, NE + 1)) < 1.0e-12_wp .AND. ABS(nodes_ref(3, NE + 1)) < 1.0e-12_wp, &
               'reference rod aligned with (-1,0,0)')
  CALL require(ABS(q0(6*30 + 5) - 0.49130854996664214_wp) < 1.0e-6_wp .AND. &
               ABS(q0(6*30 + 4)) < 1.0e-9_wp .AND. ABS(q0(6*30 + 6)) < 1.0e-9_wp, &
               'seed rotation at node 31 matches the reference')
  CALL require(ABS(q0(6*60 + 5) - 1.01494938478021_wp) < 1.0e-6_wp, &
               'seed rotation at fairlead (node 61) matches the reference')

  ! --- finite-EI touchdown solve ---
  contact_k = KN_BASE*DIAM*l0(1)
  cfg%max_iter = 300
  ALLOCATE (q(6*(NE + 1)), tension(NE))
  CALL CD_Solve_FiniteEI_Touchdown(anchor, fairlead, cat_pos, l0, ea, ei, gj, w, &
                                   -WATER_DEPTH, contact_k, cfg, factors, q, nodes_ref, &
                                   tension, conv, stalled, n_stages, es, em)
  CALL require(es == CD_FEI_OK, 'finite-EI touchdown solve errstat: '//TRIM(em))
  CALL require(conv .AND. .NOT. stalled .AND. n_stages == 4, 'finite-EI solve convergence (4 stages)')
  ! interior touchdown beyond the pinned anchor (z DOF 6*nd-3 for nodes 2..NE).
  CALL require(MINVAL([(q(6*(e - 1) + 3), e=2, NE)]) <= -WATER_DEPTH + 0.5_wp, &
               'finite-EI solution still has a grounded span')

  anchor_n = tension(1)
  fairlead_n = tension(NE)
  reference_anchor_err = ABS(anchor_n - reference_ANCHOR)/reference_ANCHOR
  reference_fairlead_err = ABS(fairlead_n - reference_FAIRLEAD)/reference_FAIRLEAD
  orca_anchor_err = ABS(anchor_n - ORCA_ANCHOR)/ORCA_ANCHOR
  orca_fairlead_err = ABS(fairlead_n - ORCA_FAIRLEAD)/ORCA_FAIRLEAD

  WRITE (*, '(A,F10.3,A,F10.3,A,F7.4,A)') 'L3-4 anchor  =', anchor_n*1.0e-3_wp, &
    ' kN  reference err=', 100.0_wp*reference_anchor_err, '%  OrcaFlex err=', 100.0_wp*orca_anchor_err, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A,F7.4,A)') 'L3-4 fairlead=', fairlead_n*1.0e-3_wp, &
    ' kN  reference err=', 100.0_wp*reference_fairlead_err, '%  OrcaFlex err=', 100.0_wp*orca_fairlead_err, '%'

  CALL require(reference_anchor_err < reference_RTOL, &
               'anchor tension matches the independent implementation (0.5% band)')
  CALL require(reference_fairlead_err < reference_RTOL, &
               'fairlead tension matches the independent implementation (0.5% band)')
  CALL require(orca_anchor_err < ORCA_ANCHOR_RTOL, 'anchor tension within 5% OrcaFlex gate')
  CALL require(orca_fairlead_err < ORCA_FAIRLEAD_RTOL, 'fairlead tension within 3% OrcaFlex gate')

  ! --- bending response (the finite-EI differentiator): geometric curvature + material moment ---
  ALLOCATE (arc(NE - 1), curv(NE - 1), moment(NE))
  CALL CD_FiniteEI_Centerline_Curvature(q, NE + 1, arc, curv, es, em)
  CALL require(es == CD_FEI_OK, 'centreline curvature extraction')
  ! Resample CableDyn's interior-node curvature onto OrcaFlex's segment-midpoint arc grid
  ! [1, 3, ..., 119] (clamped linear interp), then take the max -- matching result locations,
  ! so the touchdown peak is compared on physics, not on a half-element sampling offset.
  cd_curv_max = 0.0_wp
  DO e = 1, NE
    tgt = REAL(2*e - 1, wp)
    cd_curv_max = MAX(cd_curv_max, interp1(tgt, arc, curv))
  END DO
  CALL CD_FiniteEI_Element_Bend_Moment(q, nodes_ref, ei, moment, es, em)
  CALL require(es == CD_FEI_OK, 'material bend-moment extraction')
  cd_mom_max = MAXVAL(moment)

  curv_reference_err = ABS(cd_curv_max - reference_CURV_MAX)/reference_CURV_MAX
  curv_orca_err = ABS(cd_curv_max - ORCA_CURV_MAX)/ORCA_CURV_MAX
  mom_reference_err = ABS(cd_mom_max - reference_MOM_MAX)/reference_MOM_MAX
  mom_orca_err = ABS(cd_mom_max - ORCA_MOM_MAX)/ORCA_MOM_MAX

  WRITE (*, '(A,F9.6,A,F7.4,A,F7.4,A)') 'L3-4 max curvature =', cd_curv_max, &
    ' /m  reference err=', 100.0_wp*curv_reference_err, '%  OrcaFlex err=', 100.0_wp*curv_orca_err, '%'
  WRITE (*, '(A,F10.3,A,F7.4,A,F7.4,A)') 'L3-4 max material bend moment =', cd_mom_max, &
    ' N.m  reference err=', 100.0_wp*mom_reference_err, '%  OrcaFlex err=', 100.0_wp*mom_orca_err, '%'

  CALL require(ORCA_CURV_MAX > 1.0e-3_wp .AND. cd_curv_max > 1.0e-3_wp, 'a real bending response is present')
  CALL require(curv_reference_err < reference_RTOL, 'max curvature matches the independent implementation (0.5% band)')
  CALL require(mom_reference_err < reference_RTOL, &
               'max material bend moment matches the independent implementation (0.5% band)')
  CALL require(curv_orca_err < BEND_RTOL, 'max curvature within 2% OrcaFlex gate')
  CALL require(mom_orca_err < BEND_RTOL, 'max material bend moment within 2% OrcaFlex gate')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L3-4 finite-EI touchdown parity (tensions + curvature + bend moment) on the Fortran core'

  DEALLOCATE (l0, ea, ei, gj, w, mpl, diam_a, cat_flat, cat_pos, q0, nodes_ref, q, tension)
  DEALLOCATE (arc, curv, moment)

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
    !! Clamped piecewise-linear interpolation (np.interp semantics): x strictly
    !! increasing; xq below x(1) -> y(1), above x(n) -> y(n).
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

END PROGRAM test_l3_orcaflex_finite_ei_static
