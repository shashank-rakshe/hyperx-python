! File: tests/test_hermite_resolution.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_resolution
  !! Gate for the finite-EI mesh-resolution diagnosis (CD_HermiteCable_Resolution_Metrics):
  !! the preflight metric that flags an under-resolved lazy-wave arch / touchdown mesh and
  !! recommends a global refinement factor, the trigger the adaptive mesh policy acts on. The
  !! metric derives element curvature from the DOFs by sampling the element interior, so the
  !! test drives it with geometry of known curvature.
  !!
  !! Cases:
  !!   1. Circular-arc meshes (element curvature 1/R, h*kappa ~ arc angle per element) exercise
  !!      the h*kappa ladder, the power-of-two rec_scale, the cap, and the fragile flag.
  !!   2. A single element with opposed endpoint tangents: nearly straight at its nodes but
  !!      bowing in the interior -- the metric must report the interior peak, not the endpoint
  !!      values (the localized-arch fail-open the interior sampling exists to close).
  !!   3. A straight mesh (zero curvature) is never fragile.
  !!   4. Two resolved grounded runs are retained as physical multi-island contact, while an
  !!      isolated interior contact/gap node is diagnosed as mesh-scale chatter.
  !!   5. Mixed axial stiffness is screened by element strain, not by one global force band.
  !!   6. fail-closed on bad sizes, non-finite inputs, and out-of-range parameters.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Resolution_Metrics, &
                                         CD_HermiteResolutionType, CD_HC_HKAPPA_TARGET, &
                                         CD_HC_BOUNDARY_TARGET, CD_HC_REFINE_CAP, &
                                         CD_HCSTAT_OK, CD_HCSTAT_BADINPUT
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Curvature
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Init_Bathymetry, CD_End_Bathymetry, CD_BATHY_OK
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER :: nfail
  nfail = 0

  CALL case_arc_ladder()
  CALL case_interior_peak()
  CALL case_narrow_spike()
  CALL case_straight()
  CALL case_boundary_layer()
  CALL case_mixed_stiffness_tension_screen()
  CALL case_contact_islands()
  CALL case_structured_bathymetry_contact()
  CALL case_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI resolution metrics (arc ladder, interior peak, straight, islands, fail-closed)'

CONTAINS

  !> Build a circular-arc mesh: ne elements each spanning dtheta of a circle of radius R, in the
  !> x-z plane starting at the origin. Nodes carry the unit circle tangent m = dr/ds, so the
  !> element curvature is 1/R and l0 = R*dtheta, giving h*kappa ~ dtheta.
  SUBROUTINE build_arc(ne, R, dtheta, l0, q)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(IN) :: R, dtheta
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), q(:)
    INTEGER :: i, nn
    REAL(wp) :: th
    nn = ne + 1
    ALLOCATE (l0(ne), q(6*nn))
    l0 = R*dtheta
    DO i = 1, nn
      th = REAL(i - 1, wp)*dtheta
      q(6*(i - 1) + 1) = R*SIN(th)
      q(6*(i - 1) + 2) = 0.0_wp
      q(6*(i - 1) + 3) = R*(1.0_wp - COS(th))
      q(6*(i - 1) + 4) = COS(th)
      q(6*(i - 1) + 5) = 0.0_wp
      q(6*(i - 1) + 6) = SIN(th)
    END DO
  END SUBROUTINE build_arc

  SUBROUTINE case_arc_ladder()
    !! Element curvature 1/R with h*kappa ~ dtheta: the fragile flag and the power-of-two
    !! rec_scale track dtheta against the 0.12 target; kappa_peak recovers 1/R.
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: es
    REAL(wp), ALLOCATABLE :: l0(:), q(:)
    CHARACTER(160) :: em
    REAL(wp), PARAMETER :: R = 10.0_wp

    ! adequate: dtheta 0.08 -> h*kappa ~ 0.08 < 0.12
    CALL build_arc(6, R, 0.08_wp, l0, q)
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_OK, 'arc: adequate ok')
    CALL check(ABS(dg%kappa_peak - 1.0_wp/R) < 0.05_wp/R, 'arc: kappa_peak ~ 1/R')
    CALL check(dg%h_kappa_peak < CD_HC_HKAPPA_TARGET, 'arc: 0.08 below target')
    CALL check(.NOT. dg%fragile .AND. dg%rec_scale == 1, 'arc: 0.08 not fragile, rec 1')
    CALL check(dg%n_contact == 0 .AND. dg%n_islands == 0, 'arc: suspended, no contact')
    DEALLOCATE (l0, q)

    ! 2x under-resolved: dtheta 0.20 -> 0.12 < h*kappa <= 0.24 -> rec 2
    CALL build_arc(6, R, 0.20_wp, l0, q)
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(dg%fragile .AND. dg%rec_scale == 2, 'arc: 0.20 fragile, rec 2')
    DEALLOCATE (l0, q)

    ! 4x under-resolved: dtheta 0.35 -> 0.24 < h*kappa <= 0.48 -> rec 4
    CALL build_arc(6, R, 0.35_wp, l0, q)
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(dg%rec_scale == 4, 'arc: 0.35 rec 4')
    DEALLOCATE (l0, q)

    ! pathological: dtheta 1.0 -> h*kappa ~ 1 -> rec_scale saturates at the cap
    CALL build_arc(4, R, 1.0_wp, l0, q)
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(dg%rec_scale == CD_HC_REFINE_CAP, 'arc: cap saturates')
    DEALLOCATE (l0, q)
  END SUBROUTINE case_arc_ladder

  SUBROUTINE case_interior_peak()
    !! A single element with opposed endpoint tangents bows in the middle. Its curvature peaks
    !! in the interior, above the endpoint values, so a nodal-only reduction would miss it. The
    !! metric samples the interior, so kappa_peak must exceed the endpoint curvatures.
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: es, ec
    REAL(wp) :: l0(1), q(12), k0, k1, kmid
    CHARACTER(160) :: em, emc
    ! r1=(0,0,0) m1=(1,0,0.6); r2=(1,0,0) m2=(1,0,-0.6): tangents tilt up then down -> a bump.
    q = 0.0_wp
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]; q(4:6) = [1.0_wp, 0.0_wp, 0.6_wp]
    q(7:9) = [1.0_wp, 0.0_wp, 0.0_wp]; q(10:12) = [1.0_wp, 0.0_wp, -0.6_wp]
    l0(1) = 1.0_wp
    CALL CD_HermiteCable_Curvature(q, l0(1), 0.0_wp, k0, ec, emc)
    CALL CD_HermiteCable_Curvature(q, l0(1), 1.0_wp, k1, ec, emc)
    CALL CD_HermiteCable_Curvature(q, l0(1), 0.5_wp, kmid, ec, emc)
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_OK, 'interior: ok')
    CALL check(kmid > k0 .AND. kmid > k1, 'interior: bump peaks in the interior')
    ! The metric's sampled peak captures at least the midpoint curvature, and exceeds the
    ! endpoint values an endpoint-only reduction would have used.
    CALL check(dg%kappa_peak >= kmid - 1.0e-9_wp, 'interior: metric captures the interior peak')
    CALL check(dg%kappa_peak > MAX(k0, k1) + 1.0e-9_wp, 'interior: peak exceeds endpoint curvatures')
    CALL check(ABS(dg%h_kappa_peak - l0(1)*dg%kappa_peak) < 1.0e-9_wp, 'interior: h*kappa = l0*peak')
  END SUBROUTINE case_interior_peak

  SUBROUTINE case_narrow_spike()
    !! A near-degenerate element (large, nearly opposed endpoint tangents) whose curvature
    !! spikes very narrowly in the interior, between the coarse sample stations. The adaptive
    !! peak-finder must locate it so the element is flagged fragile rather than passed as safe.
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: es, ec
    REAL(wp) :: l0(1), q(12), kmid
    CHARACTER(160) :: em, emc
    q = [0.0_wp, 0.0_wp, 0.0_wp, -3.126_wp, 0.0_wp, -0.309_wp, &
         1.0_wp, 0.0_wp, 0.0_wp, 3.454_wp, 0.0_wp, -0.032_wp]
    l0(1) = 1.0_wp
    ! the spike sits near u ~ 0.3115, away from any coarse fixed grid point
    CALL CD_HermiteCable_Curvature(q, l0(1), 0.3115_wp, kmid, ec, emc)
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_OK, 'spike: ok')
    CALL check(kmid > 1.0_wp, 'spike: interior curvature is a large spike')
    CALL check(dg%h_kappa_peak > CD_HC_HKAPPA_TARGET, 'spike: h*kappa over target')
    CALL check(dg%fragile, 'spike: flagged fragile')
  END SUBROUTINE case_narrow_spike

  SUBROUTINE case_straight()
    !! A straight, evenly-tangent mesh has zero curvature everywhere: never fragile.
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: es, i, nn, ne
    REAL(wp), ALLOCATABLE :: l0(:), q(:)
    CHARACTER(160) :: em
    ne = 8; nn = ne + 1
    ALLOCATE (l0(ne), q(6*nn))
    l0 = 1000.0_wp
    q = 0.0_wp
    DO i = 1, nn
      q(6*(i - 1) + 1) = REAL(i - 1, wp)   ! x = 0,1,2,...
      q(6*(i - 1) + 3) = 5.0_wp            ! z = 5 (suspended)
      q(6*(i - 1) + 4) = 1.0_wp            ! tangent along +x
    END DO
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_OK, 'straight: ok')
    CALL check(dg%h_kappa_peak < 1.0e-9_wp, 'straight: zero curvature')
    CALL check(.NOT. dg%fragile .AND. dg%rec_scale == 1, 'straight: not fragile')
    CALL check(dg%n_contact == 0, 'straight: no contact')
  END SUBROUTINE case_straight

  SUBROUTINE case_boundary_layer()
    !! A stretched straight member has no curvature, so only h/sqrt(EI/T) can
    !! identify an unresolved tension-controlled end layer.
    TYPE(CD_HermiteResolutionType) :: dg
    REAL(wp) :: l0(1), q(12), EA(1), EI(1)
    INTEGER :: es
    CHARACTER(160) :: em

    EA = 1.0e6_wp
    EI = 1.0e4_wp
    q = 0.0_wp
    q(4) = 1.01_wp
    q(10) = 1.01_wp

    l0 = 2.0_wp
    q(7) = 2.02_wp
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, &
                                            CD_HC_HKAPPA_TARGET, dg, es, em, EA=EA, EI=EI)
    CALL check(es == CD_HCSTAT_OK, 'boundary: unresolved case evaluated')
    CALL check(ABS(dg%hop_axial - 1.0e4_wp) < 1.0e-6_wp, 'boundary: endpoint tension recovered')
    CALL check(dg%hop_boundary_ratio > CD_HC_BOUNDARY_TARGET, 'boundary: h/sqrt(EI/T) exceeds target')
    CALL check(dg%boundary_unresolved .AND. dg%fragile .AND. dg%rec_scale == 2, &
               'boundary: unresolved end layer requests twofold refinement')

    l0 = 0.5_wp
    q(7) = 0.505_wp
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, &
                                            CD_HC_HKAPPA_TARGET, dg, es, em, EA=EA, EI=EI)
    CALL check(es == CD_HCSTAT_OK, 'boundary: resolved case evaluated')
    CALL check(.NOT. dg%boundary_unresolved .AND. .NOT. dg%fragile, &
               'boundary: sub-target end layer accepted')
  END SUBROUTINE case_boundary_layer

  SUBROUTINE case_mixed_stiffness_tension_screen()
    !! The stiff element carries the most negative force but remains inside two
    !! microstrain. The softer element carries only a few newtons of compression,
    !! yet exceeds two microstrain and must therefore control the tensile screen.
    TYPE(CD_HermiteResolutionType) :: dg
    REAL(wp) :: l0(2), q(18), EA(2)
    INTEGER :: es
    CHARACTER(160) :: em

    l0 = 1.0_wp
    EA = [1.0e9_wp, 1.0e6_wp]
    q = 0.0_wp
    q(1) = 0.0_wp
    q(7) = 0.999999_wp
    q(13) = 1.999994_wp
    q(4) = 0.999999_wp
    q(10) = 0.999999_wp
    q(16) = 0.999995_wp

    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.5_wp, &
                                            CD_HC_HKAPPA_TARGET, dg, es, em, EA=EA)
    CALL check(es == CD_HCSTAT_OK, 'mixed EA: tension screen evaluated')
    CALL check(dg%axial_min_elem == 1, 'mixed EA: stiff section carries minimum force')
    CALL check(dg%axial_strain_min_elem == 2, 'mixed EA: soft section controls minimum strain')
    CALL check(dg%axial_compression, 'mixed EA: soft-section compression is detected')
    CALL check(dg%axial_strain_min < -2.0e-6_wp, 'mixed EA: local strain exceeds tolerance')
    CALL check(ABS(dg%axial_tolerance - 2.0_wp) < 1.0e-10_wp, &
               'mixed EA: force tolerance uses soft-section EA')
  END SUBROUTINE case_mixed_stiffness_tension_screen

  SUBROUTINE case_contact_islands()
    !! Broad separated grounded runs are a valid physical topology. Only a contact
    !! classification that toggles over one interior node is unresolved mesh-scale chatter.
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: es, i, nn, ne
    REAL(wp), ALLOCATABLE :: l0(:), q(:)
    CHARACTER(160) :: em
    REAL(wp) :: znode(8)
    ne = 7; nn = 8
    ALLOCATE (l0(ne), q(6*nn))
    l0 = 1.0_wp
    q = 0.0_wp
    ! Nodes 1-2 and 7-8 are two resolved grounded runs. The small lift keeps
    ! h*kappa below target; physical multi-island contact must not force refinement.
    znode = [0.0_wp, 0.0_wp, 0.01_wp, 0.01_wp, 0.01_wp, 0.01_wp, 0.0_wp, 0.0_wp]
    DO i = 1, nn
      q(6*(i - 1) + 1) = 1000.0_wp*REAL(i - 1, wp)   ! x along the run
      q(6*(i - 1) + 3) = znode(i)
      q(6*(i - 1) + 4) = 1.0_wp            ! horizontal tangent keeps the centreline non-degenerate
    END DO
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, 0.005_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_OK, 'islands: ok')
    CALL check(dg%n_contact == 4, 'islands: 4 contact nodes')
    CALL check(dg%n_islands == 2, 'islands: 2 islands')
    CALL check(.NOT. dg%contact_chatter, 'islands: broad grounded runs are not chatter')
    CALL check(.NOT. dg%fragile, 'islands: physical multi-island topology is accepted')
    CALL check(dg%rec_scale == 1, 'islands: resolved topology needs no refinement')

    ! Replace the second broad run with one isolated interior contact node. The
    ! one-node toggle is mesh-scale, so it must retain the topology refinement gate.
    znode = [0.0_wp, 0.0_wp, 0.01_wp, 0.0_wp, 0.01_wp, 0.01_wp, 0.01_wp, 0.01_wp]
    DO i = 1, nn
      q(6*(i - 1) + 3) = znode(i)
    END DO
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, 0.005_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_OK, 'chatter: ok')
    CALL check(dg%n_islands == 2, 'chatter: two classified islands')
    CALL check(dg%contact_chatter, 'chatter: isolated interior contact is unresolved')
    CALL check(dg%fragile .AND. dg%rec_scale == 1, &
               'chatter: topology-only fragility requests a forced doubling')
  END SUBROUTINE case_contact_islands

  SUBROUTINE case_structured_bathymetry_contact()
    !! The resolution gate must classify contact against the same local sloping
    !! floor and local-to-global heading as the static/contact solve. A scalar
    !! representative depth sees only the deepest node; the structured query sees
    !! the complete grounded run.
    TYPE(CD_HermiteResolutionType) :: dg_flat, dg_bathy
    TYPE(CD_BathymetryType) :: bathy, empty_bathy
    REAL(wp) :: l0(4), q(30), xgrid(2), ygrid(2), depth(2, 2), s
    INTEGER :: es, i
    CHARACTER(200) :: em

    xgrid = [-1.0_wp, 1.0_wp]
    ygrid = [0.0_wp, 10.0_wp]
    depth(:, 1) = 10.0_wp
    depth(:, 2) = 20.0_wp
    CALL CD_Init_Bathymetry(bathy, xgrid, ygrid, depth, es, em)
    CALL check(es == CD_BATHY_OK, 'bathy metric: grid initialized')
    l0 = 2.5_wp
    q = 0.0_wp
    DO i = 1, 5
      s = 2.5_wp*REAL(i - 1, wp)
      q(6*(i - 1) + 1) = s                 ! local x -> global y for heading [0,1]
      q(6*(i - 1) + 3) = -(10.0_wp + s)   ! exactly on the sloping global floor
      q(6*(i - 1) + 4) = 1.0_wp
    END DO
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -20.0_wp, 0.02_wp, &
                                            CD_HC_HKAPPA_TARGET, dg_flat, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. dg_flat%n_contact == 1, &
               'bathy metric: scalar representative floor sees only deepest node')
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -20.0_wp, 0.02_wp, &
                                            CD_HC_HKAPPA_TARGET, dg_bathy, es, em, &
                                            bathymetry=bathy, contact_frame_cs=[0.0_wp, 1.0_wp])
    CALL check(es == CD_HCSTAT_OK, 'bathy metric: structured query ok')
    CALL check(dg_bathy%n_contact == 5 .AND. dg_bathy%n_islands == 1, &
               'bathy metric: complete sloping grounded run recognized')
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -20.0_wp, 0.02_wp, &
                                            CD_HC_HKAPPA_TARGET, dg_bathy, es, em, &
                                            bathymetry=empty_bathy)
    CALL check(es == CD_HCSTAT_BADINPUT, 'bathy metric: uninitialized grid rejected')
    CALL CD_End_Bathymetry(bathy)
  END SUBROUTINE case_structured_bathymetry_contact

  SUBROUTINE case_fail_closed()
    !! Every malformed input is rejected with CD_HCSTAT_BADINPUT before any metric is reported.
    REAL(wp) :: l0(4), q(30), nanv
    TYPE(CD_HermiteResolutionType) :: dg
    INTEGER :: es
    CHARACTER(160) :: em
    l0 = 1.0_wp; q = 0.0_wp
    nanv = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)

    ! q wrong length (must be 6*(ne+1) = 30); pass 24
    CALL CD_HermiteCable_Resolution_Metrics(l0, q(1:24), 0.0_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: q size')
    ! empty l0
    CALL CD_HermiteCable_Resolution_Metrics(l0(1:0), q(1:6), 0.0_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: empty l0')
    ! negative contact band
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, -0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: negative band')
    ! non-positive target
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, 0.5_wp, 0.0_wp, dg, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: target 0')
    ! non-finite DOF
    q(5) = nanv
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: non-finite q')
    q(5) = 0.0_wp
    ! non-positive element length
    l0(3) = 0.0_wp
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: zero l0')
    l0(3) = -1.0_wp
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, 0.0_wp, 0.5_wp, CD_HC_HKAPPA_TARGET, dg, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail: negative l0')
  END SUBROUTINE case_fail_closed

  SUBROUTINE check(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') '  FAIL: '//label
    END IF
  END SUBROUTINE check

END PROGRAM test_hermite_resolution
