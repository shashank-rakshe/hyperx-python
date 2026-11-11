! File: tests/test_hermite_automesh.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_automesh
  !! Gate for the metric-gated mesh-economics entry (CD_HermiteCable_Static_Solve_AutoMesh):
  !! solve at a coarse mesh, then auto-refine to the minimum safe mesh only where the resolution
  !! metric demands it.
  !!
  !! Rig: a net-heavy planar bending catenary (pinned endpoints, slack) whose coarse discretisation
  !! carries a large h*kappa.
  !!
  !! Cases:
  !!   1. TIGHT target -> the coarse mesh is fragile, AutoMesh refines (applied_scale > 1) until the
  !!      diagnosis clears (or the cap), and the refined mesh's h*kappa is at/under the target.
  !!   2. NO over-refinement: a target the base mesh already satisfies returns it unchanged
  !!      (applied_scale = 1), bit-identical to a plain CD_HermiteCable_Static_Solve.
  !!   3. max_scale = 1 disables refinement even when fragile (applied_scale = 1).
  !!   4. EQUIVALENCE: the auto-refined state equals a manual Refine_Mesh + polish at the same mesh.
  !!   5. Physical multi-island contact is accepted at the refinement cap.
  !!   6. Tension-controlled end layers trigger refinement through the EI-aware diagnosis.
  !!   7. FAIL-CLOSED: max_scale < 1 is rejected.
  !!   8. LOCAL refinement (local_refinement): a line with one coarse section is refined where its
  !!      h*kappa fails, graded into the fine section, within the per-element cap, and agrees with
  !!      the global refinement; a resolved mesh, max_scale = 1 and the end-layer rig behave as
  !!      in the global mode; the element limit takes bending-length levels before h*kappa
  !!      levels; the per-element diagnosis outputs are consistent.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, &
                                         CD_HermiteCable_Static_Solve_AutoMesh, &
                                         CD_HermiteCable_Refine_Mesh, &
                                         CD_HermiteCable_Resolution_Metrics, &
                                         CD_HermiteCable_Trivial_Seed, &
                                         CD_HermiteResolutionType, CD_HCSTAT_OK, CD_HCSTAT_BADINPUT, &
                                         CD_HCSTAT_NOCONVERGE
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_refines_when_fragile()
  CALL case_no_over_refine()
  CALL case_maxscale_one()
  CALL case_equivalence()
  CALL case_initial_polish()
  CALL case_boundary_layer_refinement()
  CALL case_required_resolution_cap()
  CALL case_resolved_multi_island_cap()
  CALL case_fail_closed()
  CALL case_local_refinement()
  CALL case_local_unchanged()
  CALL case_local_boundary_layer()
  CALL case_local_element_limit()
  CALL case_metrics_element_outputs()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI auto-mesh (refine-when-fragile, no-over-refine, cap, equivalence, fail-closed)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  !> Build a net-heavy planar bending catenary rig on ne elements: pinned endpoints, slack, y (and
  !> m_y) fixed for a planar solve. Deep seabed => no contact.
  SUBROUTINE build_rig(ne, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EA(:), EI(:), w(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed(:)
    INTEGER, INTENT(OUT) :: nfix
    REAL(wp), INTENT(OUT) :: seabed_z
    REAL(wp), PARAMETER :: LTOT = 100.0_wp, CHORD = 90.0_wp
    REAL(wp) :: p_a(3), p_b(3)
    INTEGER :: nn, i, es
    CHARACTER(160) :: em
    nn = ne + 1
    ALLOCATE (l0(ne), EA(ne), EI(ne), w(ne), seed(6*nn), fixed(6 + 2*nn))
    l0 = LTOT/REAL(ne, wp)
    EA = 1.0e8_wp; EI = 1.0e4_wp; w = 100.0_wp
    seabed_z = -1000.0_wp
    p_a = [0.0_wp, 0.0_wp, 0.0_wp]
    p_b = [CHORD, 0.0_wp, 0.0_wp]
    CALL CD_HermiteCable_Trivial_Seed(p_a, p_b, l0, seabed_z, seed, es, em)
    IF (es /= CD_HCSTAT_OK) WRITE (*, '(A)') '  (seed error) '//TRIM(em)
    ! pin both endpoint positions + fix every node's planar y position and y tangent
    nfix = 0
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
    DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
    DO i = 1, nn
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
      nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
    END DO
  END SUBROUTINE build_rig

  SUBROUTINE case_refines_when_fragile()
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, es
    REAL(wp) :: seabed_z, res
    CHARACTER(200) :: em
    CALL build_rig(10, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    ! tight target 0.05: the 10 m coarse mesh carries h*kappa well above it -> must refine
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.05_wp, 0.5_wp, 8, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em)
    IF (es /= CD_HCSTAT_OK) WRITE (*, '(A)') '  (automesh error) '//TRIM(em)
    CALL check(es == CD_HCSTAT_OK, 'fragile: solve ok')
    CALL check(scale > 1, 'fragile: refined (applied_scale > 1)')
    CALL check(SIZE(l0o) == 10*scale, 'fragile: mesh grew by applied_scale')
    CALL check(SIZE(qo) == 6*(SIZE(l0o) + 1), 'fragile: q sized to refined mesh')
    ! either the diagnosis cleared, or the cap was hit; in both cases h*kappa must have improved
    CALL check(.NOT. dg%fragile .OR. scale == 8, 'fragile: cleared or capped')
    CALL check(ALL(fixo >= 1) .AND. ALL(fixo <= 6*(SIZE(l0o) + 1)), 'fragile: refined constraints in range')
  END SUBROUTINE case_refines_when_fragile

  SUBROUTINE case_no_over_refine()
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    REAL(wp), ALLOCATABLE :: qd(:), curvd(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, itd, es
    REAL(wp) :: seabed_z, res, resd
    CHARACTER(200) :: em
    CALL build_rig(64, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    ! This case isolates the no-over-refinement contract. Raise EI so the native
    ! end elements also resolve sqrt(EI/T), rather than satisfying h*kappa alone.
    EI = 1.0e6_wp
    ! loose target 0.2 that the fine 64-element mesh already satisfies -> no refinement
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.2_wp, 0.5_wp, 8, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em)
    CALL check(es == CD_HCSTAT_OK, 'resolved: solve ok')
    CALL check(scale == 1, 'resolved: no over-refinement (applied_scale = 1)')
    CALL check(.NOT. dg%fragile, 'resolved: not fragile')
    ! and the returned state is exactly a plain solve on the same mesh
    ALLOCATE (qd(6*65), curvd(65))
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                      8, 120, 1.0e-8_wp, 0.7_wp, qd, curvd, resd, itd, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. nan_max_abs(qo - qd) < 1.0e-12_wp, 'resolved: matches plain solve to 1e-12')
  END SUBROUTINE case_no_over_refine

  SUBROUTINE case_maxscale_one()
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, es
    REAL(wp) :: seabed_z, res
    CHARACTER(200) :: em
    CALL build_rig(10, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    ! fragile at 10 elements but max_scale = 1 forbids refinement
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.05_wp, 0.5_wp, 1, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em)
    CALL check(es == CD_HCSTAT_OK, 'cap1: solve ok')
    CALL check(scale == 1 .AND. SIZE(l0o) == 10, 'cap1: no refinement with max_scale = 1')
  END SUBROUTINE case_maxscale_one

  SUBROUTINE case_equivalence()
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    REAL(wp), ALLOCATABLE :: qbase(:), curvbase(:)
    REAL(wp), ALLOCATABLE :: l0r(:), qr(:), EAr(:), EIr(:), wr(:), qman(:), curvman(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:), fixr(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, es, j, parent, nn0
    REAL(wp) :: seabed_z, res
    CHARACTER(200) :: em
    ! AutoMesh with target 0.06 and cap 2 => exactly one doubling of the 10-element mesh.
    CALL build_rig(10, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.06_wp, 0.5_wp, 2, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. scale == 2, 'equiv: one doubling')

    ! Reproduce manually: base solve, Refine_Mesh x2, replicate props, polish.
    nn0 = 11
    ALLOCATE (qbase(6*nn0), curvbase(nn0))
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                      8, 120, 1.0e-8_wp, 0.7_wp, qbase, curvbase, res, its, es, em)
    CALL CD_HermiteCable_Refine_Mesh(l0, qbase, fixed(1:nfix), 2, l0r, qr, fixr, es, em, inherit_dofs=[2, 5])
    ALLOCATE (EAr(SIZE(l0r)), EIr(SIZE(l0r)), wr(SIZE(l0r)), qman(SIZE(qr)), curvman(SIZE(l0r) + 1))
    DO j = 1, SIZE(l0r)
      parent = (j - 1)/2 + 1
      EAr(j) = EA(parent); EIr(j) = EI(parent); wr(j) = w(parent)
    END DO
    CALL CD_HermiteCable_Static_Solve(l0r, EAr, EIr, wr, qr, fixr, seabed_z, 0.0_wp, &
                                      1, 120, 1.0e-8_wp, 0.7_wp, qman, curvman, res, its, es, em, n_buoy_steps=1)
    CALL check(es == CD_HCSTAT_OK, 'equiv: manual polish ok')
    CALL check(SIZE(qo) == SIZE(qman), 'equiv: same size')
    CALL check(nan_max_abs(qo - qman) < 1.0e-10_wp, 'equiv: auto == manual refine+polish')
  END SUBROUTINE case_equivalence

  SUBROUTINE case_initial_polish()
    !! An already-converged net-buoyant state must enter AutoMesh at full load.
    !! Replaying the default 40-stage buoyancy ramp is both unnecessary and can
    !! select a different nonlinear equilibrium branch.
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:), qsol(:), curvsol(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, its_cold, es
    REAL(wp) :: seabed_z, res, res_cold
    CHARACTER(200) :: em

    CALL build_rig(32, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    w(13:20) = -100.0_wp
    ALLOCATE (qsol(SIZE(seed)), curvsol(33))
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                      8, 120, 1.0e-8_wp, 0.7_wp, qsol, curvsol, res_cold, &
                                      its_cold, es, em)
    CALL check(es == CD_HCSTAT_OK, 'initial polish: net-buoyant reference solve ok')
    IF (es /= CD_HCSTAT_OK) RETURN

    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, qsol, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 1.0_wp, 0.5_wp, 1, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               initial_polish=.TRUE.)
    CALL check(es == CD_HCSTAT_OK, 'initial polish: AutoMesh solve ok')
    CALL check(scale == 1, 'initial polish: diagnosis-only mesh unchanged')
    CALL check(nan_max_abs(qo - qsol) < 1.0e-6_wp, 'initial polish: converged branch unchanged')
    CALL check(its < its_cold, 'initial polish: cold buoyancy continuation not replayed')
  END SUBROUTINE case_initial_polish

  SUBROUTINE case_boundary_layer_refinement()
    !! A fully prescribed straight element has zero curvature, but its element
    !! length is too large relative to sqrt(EI/T). AutoMesh must pass EI into the
    !! resolution diagnosis and refine once even though h*kappa is exactly zero.
    INTEGER, PARAMETER :: NE = 1, NN = 2, NDOF = 6*NN
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER :: fixed(NDOF), i, scale, its, es
    INTEGER, ALLOCATABLE :: fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    REAL(wp) :: res
    CHARACTER(240) :: em

    l0 = 2.0_wp
    EA = 1.0e6_wp
    EI = 1.21e4_wp
    w = 0.0_wp
    seed = 0.0_wp
    seed(4) = 1.01_wp
    seed(7) = 2.02_wp
    seed(10) = 1.01_wp
    DO i = 1, NDOF
      fixed(i) = i
    END DO

    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed, -1.0e4_wp, 0.0_wp, &
                                               1, 5, 1.0e-10_wp, 1.0_wp, 1.0_wp, 0.0_wp, 2, &
                                               [1, 2, 3, 4, 5, 6], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, &
                                               res, its, es, em, require_resolved=.TRUE.)
    CALL check(es == CD_HCSTAT_OK, 'boundary AutoMesh: solve and refinement succeed')
    CALL check(scale == 2 .AND. SIZE(l0o) == 2, &
               'boundary AutoMesh: unresolved end layer triggers one refinement')
    CALL check(.NOT. dg%boundary_unresolved .AND. .NOT. dg%fragile, &
               'boundary AutoMesh: refined end layer satisfies resolution target')
    CALL check(dg%hop_boundary_ratio < 1.0_wp .AND. dg%end_boundary_ratio < 1.0_wp, &
               'boundary AutoMesh: both end ratios use propagated EI')
  END SUBROUTINE case_boundary_layer_refinement

  SUBROUTINE case_required_resolution_cap()
    !! Production adaptive meshing is a promise to deliver a resolved state, not
    !! merely to spend the allowed refinement budget. If the cap is exhausted while
    !! the diagnostic remains fragile, fail closed with the measured reason.
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, es
    REAL(wp) :: seabed_z, res
    CHARACTER(240) :: em

    CALL build_rig(10, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 1.0e-3_wp, 0.5_wp, 1, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               require_resolved=.TRUE.)
    CALL check(es == CD_HCSTAT_NOCONVERGE, 'required resolution: exhausted cap fails closed')
    CALL check(INDEX(em, 'refinement cap') > 0 .AND. INDEX(em, 'h*kappa') > 0, &
               'required resolution: diagnostic names cap and measured metric')

    ! Isolate the resolved cap-one branch from the end-layer screen as well as the
    ! deliberately loose curvature target used below.
    EI = 1.0e7_wp
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 1.0_wp, 0.5_wp, 1, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               require_resolved=.TRUE.)
    CALL check(es == CD_HCSTAT_OK .AND. .NOT. dg%fragile, &
               'required resolution: resolved cap-one mesh remains accepted')
  END SUBROUTINE case_required_resolution_cap

  SUBROUTINE case_resolved_multi_island_cap()
    !! The require_resolved contract must reject unresolved curvature/contact
    !! chatter, not a legitimate topology with two adequately sampled grounded runs.
    INTEGER, PARAMETER :: NE = 7, NN = NE + 1, NDOF = 6*NN
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF), znode(NN)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER :: fixed(NDOF), i, scale, its, es
    INTEGER, ALLOCATABLE :: fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    REAL(wp) :: res
    CHARACTER(240) :: em

    l0 = 1.0_wp; EA = 1.0e6_wp; EI = 1.0e2_wp; w = 0.0_wp
    seed = 0.0_wp
    znode = [0.0_wp, 0.0_wp, 0.01_wp, 0.01_wp, 0.01_wp, 0.01_wp, 0.0_wp, 0.0_wp]
    DO i = 1, NN
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)
      seed(6*(i - 1) + 3) = znode(i)
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    DO i = 1, NDOF
      fixed(i) = i
    END DO

    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed, 0.0_wp, 0.0_wp, &
                                               1, 5, 1.0e-8_wp, 1.0_wp, 1.0_wp, 0.005_wp, 1, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               require_resolved=.TRUE.)
    CALL check(es == CD_HCSTAT_OK, 'multi-island cap: resolved topology accepted')
    CALL check(scale == 1 .AND. dg%n_islands == 2, &
               'multi-island cap: mesh and physical island count retained')
    CALL check(.NOT. dg%contact_chatter .AND. .NOT. dg%fragile, &
               'multi-island cap: broad grounded runs are resolved')
  END SUBROUTINE case_resolved_multi_island_cap

  SUBROUTINE case_fail_closed()
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, es
    REAL(wp) :: seabed_z, res
    CHARACTER(200) :: em
    CALL build_rig(8, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.1_wp, 0.5_wp, 0, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: max_scale < 1 rejected')
    ! Size-mismatch fail-closed: a property array whose length /= SIZE(l0) must return BADINPUT,
    ! not hit a non-conforming whole-array copy in the wrapper before the inner solve.
    ! max_scale = 8 is valid here, so the size check -- not the max_scale check -- must reject it.
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA(1:SIZE(EA) - 1), EI, w, seed, fixed(1:nfix), &
                                               seabed_z, 0.0_wp, 8, 120, 1.0e-8_wp, 0.7_wp, 0.1_wp, &
                                               0.5_wp, 8, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: EA size /= SIZE(l0) rejected (no OOB copy)')
  END SUBROUTINE case_fail_closed

  !> The rig of build_rig on a two-section mesh: NC coarse elements over the first 30 m and NF
  !> fine 1 m elements over the remaining 70 m (the deck mesh of a line with one coarse section).
  SUBROUTINE build_two_section_rig(nc, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    INTEGER, INTENT(IN) :: nc
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), EA(:), EI(:), w(:), seed(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed(:)
    INTEGER, INTENT(OUT) :: nfix
    REAL(wp), INTENT(OUT) :: seabed_z
    INTEGER, PARAMETER :: NF = 70
    INTEGER :: ne
    CALL build_rig(nc + NF, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    ne = nc + NF
    l0(1:nc) = 30.0_wp/REAL(nc, wp)
    l0(nc + 1:ne) = 1.0_wp
    BLOCK
      INTEGER :: es
      CHARACTER(160) :: em
      CALL CD_HermiteCable_Trivial_Seed([0.0_wp, 0.0_wp, 0.0_wp], [90.0_wp, 0.0_wp, 0.0_wp], l0, seabed_z, &
                                        seed, es, em)
      IF (es /= CD_HCSTAT_OK) WRITE (*, '(A)') '  (seed error) '//TRIM(em)
    END BLOCK
  END SUBROUTINE build_two_section_rig

  SUBROUTINE case_local_refinement()
    !! Three coarse 10 m elements beside seventy 1 m elements. The local mode refines the coarse
    !! section (and grades into the fine one) instead of multiplying the whole line, keeps every
    !! element a power-of-two child of its caller element within the cap, meets the target, and
    !! reaches the equilibrium of the global refinement.
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    REAL(wp), ALLOCATABLE :: l0g(:), EAg(:), EIg(:), wg(:), qg(:), curvg(:), sg(:), so(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:), fixg(:)
    TYPE(CD_HermiteResolutionType) :: dg, dgg
    INTEGER :: nfix, scale, scaleg, its, es, e, k, ng, no
    REAL(wp) :: seabed_z, res, ratio, dmax, xg, deck_ratio
    LOGICAL :: dyadic, graded
    CHARACTER(240) :: em
    CALL build_two_section_rig(3, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.12_wp, 0.0_wp, 16, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               local_refinement=.TRUE.)
    IF (es /= CD_HCSTAT_OK) WRITE (*, '(A)') '  (local automesh error) '//TRIM(em)
    CALL check(es == CD_HCSTAT_OK, 'local: solve ok')
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL check(scale > 1, 'local: refined')
    CALL check(dg%h_kappa_peak <= 0.12_wp, 'local: h*kappa target met')
    CALL check(ABS(SUM(l0o) - SUM(l0)) <= 1.0e-12_wp*SUM(l0), 'local: rest length preserved')
    ! Every element is a 2^-k child (k <= 4) of the caller element that contains it.
    dyadic = .TRUE.
    xg = 0.0_wp
    DO e = 1, SIZE(l0o)
      ratio = MERGE(10.0_wp, 1.0_wp, xg + 0.5_wp*l0o(e) < 30.0_wp)/l0o(e)
      k = NINT(LOG(ratio)/LOG(2.0_wp))
      IF (k < 0 .OR. k > 4 .OR. ABS(ratio - 2.0_wp**k) > 1.0e-9_wp*ratio) dyadic = .FALSE.
      xg = xg + l0o(e)
    END DO
    CALL check(dyadic, 'local: elements are power-of-two children within the cap')
    ! Graded: neighbours differ by at most twice, except across the deck's own 10:1 jump
    ! (the node at 30 m between a 10 m and a 1 m caller element), where the jump is at most it.
    graded = .TRUE.
    xg = 0.0_wp
    DO e = 1, SIZE(l0o) - 1
      ratio = MAX(l0o(e)/l0o(e + 1), l0o(e + 1)/l0o(e))
      xg = xg + l0o(e)
      deck_ratio = MERGE(10.0_wp, 1.0_wp, ABS(xg - 30.0_wp) < 1.0e-9_wp)
      IF (ratio > MAX(2.0_wp, deck_ratio)*(1.0_wp + 1.0e-12_wp)) graded = .FALSE.
    END DO
    CALL check(graded, 'local: new neighbour length jumps at most 2x (the deck jump excepted)')
    ! The far end of the fine section is not touched.
    CALL check(ALL(ABS(l0o(SIZE(l0o) - 19:) - 1.0_wp) < 1.0e-12_wp), 'local: resolved fine section unchanged')
    ! Same equilibrium as the global refinement, on far fewer elements.
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.12_wp, 0.0_wp, 16, [2, 5], &
                                               l0g, EAg, EIg, wg, qg, curvg, fixg, scaleg, dgg, res, its, es, em)
    CALL check(es == CD_HCSTAT_OK, 'local: global reference ok')
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL check(SIZE(l0o) < SIZE(l0g), 'local: fewer elements than the global refinement')
    ng = SIZE(l0g) + 1
    no = SIZE(l0o) + 1
    ALLOCATE (sg(ng), so(no))
    sg(1) = 0.0_wp
    DO e = 2, ng
      sg(e) = sg(e - 1) + l0g(e - 1)
    END DO
    so(1) = 0.0_wp
    DO e = 2, no
      so(e) = so(e - 1) + l0o(e - 1)
    END DO
    dmax = 0.0_wp
    DO e = 1, no
      DO k = 1, 3, 2
        dmax = MAX(dmax, ABS(qo(6*(e - 1) + k) - interp(so(e), sg, qg(k::6))))
      END DO
    END DO
    CALL check(dmax < 1.0e-3_wp*SUM(l0), 'local: equilibrium within 1e-3 of the line length of the global one')
  END SUBROUTINE case_local_refinement

  REAL(wp) FUNCTION interp(x, xs, ys)
    !! Piecewise-linear interpolation of ys(xs) at x (xs ascending).
    REAL(wp), INTENT(IN) :: x, xs(:), ys(:)
    INTEGER :: i
    interp = ys(SIZE(ys))
    DO i = 2, SIZE(xs)
      IF (x <= xs(i)) THEN
        interp = ys(i - 1) + (ys(i) - ys(i - 1))*(x - xs(i - 1))/(xs(i) - xs(i - 1))
        RETURN
      END IF
    END DO
  END FUNCTION interp

  SUBROUTINE case_local_unchanged()
    !! The local mode changes nothing when no refinement runs: a resolved mesh is returned
    !! bit-identical to the global mode, and max_scale = 1 disables the local passes too.
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    REAL(wp), ALLOCATABLE :: l0g(:), EAg(:), EIg(:), wg(:), qg(:), curvg(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:), fixg(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, es
    REAL(wp) :: seabed_z, res
    CHARACTER(200) :: em
    CALL build_rig(64, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    EI = 1.0e6_wp
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.2_wp, 0.5_wp, 8, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               local_refinement=.TRUE.)
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.2_wp, 0.5_wp, 8, [2, 5], &
                                               l0g, EAg, EIg, wg, qg, curvg, fixg, scale, dg, res, its, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. scale == 1 .AND. SIZE(qo) == SIZE(qg), 'local unchanged: resolved mesh kept')
    IF (SIZE(qo) == SIZE(qg)) &
      CALL check(nan_max_abs(qo - qg) <= 0.0_wp, 'local unchanged: bit-identical to the global mode')
    CALL build_rig(10, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 120, 1.0e-8_wp, 0.7_wp, 0.05_wp, 0.5_wp, 1, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               local_refinement=.TRUE.)
    CALL check(es == CD_HCSTAT_OK .AND. scale == 1 .AND. SIZE(l0o) == 10, &
               'local unchanged: no refinement with max_scale = 1')
  END SUBROUTINE case_local_unchanged

  SUBROUTINE case_local_boundary_layer()
    !! The end-layer rig of case_boundary_layer_refinement in the local mode: the single
    !! element is split once and the layer is resolved.
    INTEGER, PARAMETER :: NE = 1, NN = 2, NDOF = 6*NN
    REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER :: fixed(NDOF), i, scale, its, es
    INTEGER, ALLOCATABLE :: fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    REAL(wp) :: res
    CHARACTER(240) :: em
    l0 = 2.0_wp; EA = 1.0e6_wp; EI = 1.21e4_wp; w = 0.0_wp
    seed = 0.0_wp
    seed(4) = 1.01_wp; seed(7) = 2.02_wp; seed(10) = 1.01_wp
    DO i = 1, NDOF
      fixed(i) = i
    END DO
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed, -1.0e4_wp, 0.0_wp, &
                                               1, 5, 1.0e-10_wp, 1.0_wp, 1.0_wp, 0.0_wp, 2, &
                                               [1, 2, 3, 4, 5, 6], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, &
                                               res, its, es, em, require_resolved=.TRUE., local_refinement=.TRUE.)
    CALL check(es == CD_HCSTAT_OK .AND. scale == 2 .AND. SIZE(l0o) == 2, 'local boundary: end layer split once')
    CALL check(.NOT. dg%boundary_unresolved, 'local boundary: end layer resolved')
  END SUBROUTINE case_local_boundary_layer

  SUBROUTINE case_local_element_limit()
    !! A pass that would exceed the element limit gives up bending-length levels before h*kappa
    !! levels. The limit is lowered to 900 (max_elements) so that a small, well-conditioned line
    !! reaches it: 60 elements of 1.67 m with EI = 5 (half the bending length is 18 cm) all ask
    !! for 16 children by the bending-length rule (960 elements), and with the h*kappa target
    !! 3e-3 the elements about the sag ask for 16 by h*kappa as well. Taking one level less
    !! everywhere (8x) would leave the sag above the target with no pass able to split it
    !! further within the limit; keeping its h*kappa levels and giving the bending-length rule
    !! one level meets the target in one pass. (At the default limit of 8192 the same test needs
    !! a string-like line on about 7000 elements, whose polish can settle on a folded
    !! equilibrium depending on round-off.)
    INTEGER, PARAMETER :: NE = 60, LIMIT = 900
    REAL(wp), PARAMETER :: TARGET = 3.0e-3_wp
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:)
    REAL(wp), ALLOCATABLE :: l0o(:), EAo(:), EIo(:), wo(:), qo(:), curvo(:)
    INTEGER, ALLOCATABLE :: fixed(:), fixo(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, scale, its, es
    REAL(wp) :: seabed_z, res, h
    CHARACTER(240) :: em
    CALL build_rig(NE, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    EI = 5.0_wp
    h = l0(1)
    CALL CD_HermiteCable_Static_Solve_AutoMesh(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                               8, 300, 1.0e-8_wp, 0.7_wp, TARGET, 0.0_wp, 16, [2, 5], &
                                               l0o, EAo, EIo, wo, qo, curvo, fixo, scale, dg, res, its, es, em, &
                                               local_refinement=.TRUE., max_elements=LIMIT)
    IF (es /= CD_HCSTAT_OK) WRITE (*, '(A)') '  (local limit automesh error) '//TRIM(em)
    WRITE (*, '(A,I0,A,I0,A,ES10.3)') '  local limit: ', SIZE(l0o), ' elements, ', its, ' Newton iterations, |R| ', res
    CALL check(es == CD_HCSTAT_OK, 'local limit: solve ok')
    IF (es /= CD_HCSTAT_OK) RETURN
    CALL check(SIZE(l0o) <= LIMIT .AND. SIZE(l0o) > 8*NE, 'local limit: within the limit, beyond 8x')
    CALL check(ABS(MINVAL(l0o) - h/16.0_wp) <= 1.0e-12_wp*h, 'local limit: h*kappa needs keep 16 children')
    CALL check(ABS(MAXVAL(l0o) - h/8.0_wp) <= 1.0e-12_wp*h, 'local limit: bending-length needs give a level')
    CALL check(dg%h_kappa_peak <= TARGET, 'local limit: h*kappa target met')
  END SUBROUTINE case_local_element_limit

  SUBROUTINE case_metrics_element_outputs()
    !! The per-element outputs of the resolution diagnosis: the h*kappa field peaks at
    !! h_kappa_peak, and its length is checked.
    REAL(wp), ALLOCATABLE :: l0(:), EA(:), EI(:), w(:), seed(:), q(:), curv(:), hk(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    LOGICAL, ALLOCATABLE :: chat(:)
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: nfix, its, es
    REAL(wp) :: seabed_z, res
    CHARACTER(200) :: em
    CALL build_rig(10, l0, EA, EI, w, seed, fixed, nfix, seabed_z)
    ALLOCATE (q(SIZE(seed)), curv(11), hk(10), chat(11))
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed(1:nfix), seabed_z, 0.0_wp, &
                                      8, 120, 1.0e-8_wp, 0.7_wp, q, curv, res, its, es, em)
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, seabed_z, 0.5_wp, 0.12_wp, dg, es, em, EA=EA, EI=EI, &
                                            elem_h_kappa=hk, chatter_node=chat)
    CALL check(es == CD_HCSTAT_OK, 'metrics outputs: ok')
    CALL check(ABS(MAXVAL(hk) - dg%h_kappa_peak) <= 0.0_wp .AND. MAXLOC(hk, 1) == dg%h_kappa_elem, &
               'metrics outputs: element h*kappa peaks at h_kappa_peak')
    CALL check(.NOT. ANY(chat) .AND. .NOT. dg%contact_chatter, 'metrics outputs: no chatter off the seabed')
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, seabed_z, 0.5_wp, 0.12_wp, dg, es, em, elem_h_kappa=hk(1:9))
    CALL check(es == CD_HCSTAT_BADINPUT, 'metrics outputs: short elem_h_kappa rejected')
  END SUBROUTINE case_metrics_element_outputs

  SUBROUTINE check(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') '  FAIL: '//label
    END IF
  END SUBROUTINE check

END PROGRAM test_hermite_automesh
