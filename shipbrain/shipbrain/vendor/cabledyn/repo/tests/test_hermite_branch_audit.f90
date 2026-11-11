! File: tests/test_hermite_branch_audit.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_branch_audit
  !! Unit gates for the finite-EI static physical-branch safeguards:
  !!
  !!   1. CD_HermiteCable_Branch_Audit accepts a monotone sagging line, rejects a closed
  !!      loop and a hairpin fold (tangent reversal), exempts a restrained end's boundary
  !!      layer, skips the reversal test for a vertical chord, and rejects an
  !!      element-localized kink.
  !!   2. The element-mean compression screen is reported, and rejected only on request;
  !!      pointwise stiff-EA oscillation with a tensile mean is not compression, and the
  !!      3-element smoothed mean drops an isolated compressed element but keeps a run.
  !!   3. CD_HermiteCable_Resolution_Metrics compression modes: the default strain band is
  !!      unchanged, the tension-relative band flags compression larger than the peak tension
  !!      of a light line on a stiff EA (which the strain band alone accepts), and the strict
  !!      mode takes the tighter band.
  !!   4. The stable flag of CD_HermiteCable_Static_Solve: a hanging line is a stable
  !!      equilibrium; a straight compressed strut between fixed ends is not.
  !!   5. CD_HermiteCable_Static_Solve_Continuation reaches the hanging equilibrium of a
  !!      heavy line from its EI = 0 catenary seed (and from a straight chord seed that a
  !!      plain Newton would take to the strut), within its iteration budget, and fails
  !!      closed with NOCONVERGE on a zero budget-like single iteration.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Branch_Audit, CD_HermiteBranchAuditType, &
                                         CD_HermiteCable_Resolution_Metrics, CD_HermiteResolutionType, &
                                         CD_HermiteCable_Static_Solve, CD_HermiteCable_Static_Solve_Continuation, &
                                         CD_HC_AUDIT_PASS, CD_HC_AUDIT_BACKTRACK, CD_HC_AUDIT_COMPRESSION, &
                                         CD_HC_AUDIT_KINK, CD_HC_HKAPPA_TARGET, CD_HC_COMPRESSION_STRAIN, &
                                         CD_HC_COMPRESSION_RELATIVE, CD_HC_COMPRESSION_STRICT, &
                                         CD_HCSTAT_OK, CD_HCSTAT_BADINPUT, CD_HCSTAT_NOCONVERGE
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = ACOS(-1.0_wp)
  INTEGER :: nfail
  nfail = 0

  CALL case_monotone_sag()
  CALL case_loop_and_fold()
  CALL case_end_zone_and_vertical()
  CALL case_kink()
  CALL case_compression_report()
  CALL case_isolated_compressed_element()
  CALL case_resolution_modes()
  CALL case_stability_and_continuation()
  CALL case_fail_closed()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI physical-branch audit, compression modes, stability, continuation'

CONTAINS

  SUBROUTINE check(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. ok) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: '//label
    END IF
  END SUBROUTINE check

  !> Parametric curve r(t), t in [0,1], sampled at ne+1 nodes with material tangents dr/ds
  !> of unit length (inextensible reference: l0 = arc length per element).
  SUBROUTINE build_curve(kind, ne, l0, q)
    CHARACTER(*), INTENT(IN) :: kind
    INTEGER, INTENT(IN) :: ne
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), q(:)
    INTEGER :: i
    REAL(wp) :: s, ds, th, r(3), t(3), total
    ALLOCATE (l0(ne), q(6*(ne + 1)))
    SELECT CASE (kind)
    CASE ('sag')
      total = 100.0_wp
    CASE ('loop')
      total = 100.0_wp + 2.0_wp*PI*5.0_wp
    CASE ('fold')
      total = 100.0_wp + PI*5.0_wp
    CASE DEFAULT
      total = 50.0_wp
    END SELECT
    ds = total/REAL(ne, wp)
    l0 = ds
    DO i = 0, ne
      s = REAL(i, wp)*ds
      SELECT CASE (kind)
      CASE ('sag')
        ! a sagging arc of radius 100 m: tangent within +-0.5 rad of +x
        th = -0.5_wp + s/total
        r = [100.0_wp*(SIN(th) + SIN(0.5_wp)), 0.0_wp, 100.0_wp*(COS(0.5_wp) - COS(th))]
        t = [COS(th), 0.0_wp, SIN(th)]
      CASE ('loop')
        ! straight, one full circle of radius 5 m, straight again
        IF (s <= 50.0_wp) THEN
          r = [s, 0.0_wp, 0.0_wp]; t = [1.0_wp, 0.0_wp, 0.0_wp]
        ELSE IF (s <= 50.0_wp + 2.0_wp*PI*5.0_wp) THEN
          th = (s - 50.0_wp)/5.0_wp
          r = [50.0_wp + 5.0_wp*SIN(th), 0.0_wp, 5.0_wp - 5.0_wp*COS(th)]
          t = [COS(th), 0.0_wp, SIN(th)]
        ELSE
          r = [s - 2.0_wp*PI*5.0_wp, 0.0_wp, 0.0_wp]; t = [1.0_wp, 0.0_wp, 0.0_wp]
        END IF
      CASE ('fold')
        ! forward 60 m, hairpin (half circle, radius 5 m) back 10 m over the top, then on
        IF (s <= 60.0_wp) THEN
          r = [s, 0.0_wp, 0.0_wp]; t = [1.0_wp, 0.0_wp, 0.0_wp]
        ELSE IF (s <= 60.0_wp + PI*5.0_wp) THEN
          th = (s - 60.0_wp)/5.0_wp
          r = [60.0_wp + 5.0_wp*SIN(th), 0.0_wp, 5.0_wp - 5.0_wp*COS(th)]
          t = [COS(th), 0.0_wp, SIN(th)]
        ELSE
          r = [60.0_wp - (s - 60.0_wp - PI*5.0_wp), 0.0_wp, 10.0_wp]; t = [-1.0_wp, 0.0_wp, 0.0_wp]
        END IF
      CASE ('vertical')
        r = [0.0_wp, 0.0_wp, s]; t = [0.0_wp, 0.0_wp, 1.0_wp]
      END SELECT
      q(6*i + 1:6*i + 3) = r
      q(6*i + 4:6*i + 6) = t
    END DO
  END SUBROUTINE build_curve

  SUBROUTINE case_monotone_sag()
    REAL(wp), ALLOCATABLE :: l0(:), q(:), ea(:)
    TYPE(CD_HermiteBranchAuditType) :: au
    INTEGER :: es
    CHARACTER(200) :: em
    CALL build_curve('sag', 40, l0, q)
    ALLOCATE (ea(40))
    ea = 1.0e9_wp
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK, 'sag: audit evaluated: '//TRIM(em))
    CALL check(au%physical .AND. au%failed_check == CD_HC_AUDIT_PASS, 'sag: monotone sag is physical')
    CALL check(au%backtrack_checked .AND. au%tangent_reversal < 1.0e-12_wp, 'sag: no tangent reversal')
  END SUBROUTINE case_monotone_sag

  SUBROUTINE case_loop_and_fold()
    REAL(wp), ALLOCATABLE :: l0(:), q(:), ea(:)
    TYPE(CD_HermiteBranchAuditType) :: au
    INTEGER :: es, i
    CHARACTER(200) :: em
    CALL build_curve('loop', 160, l0, q)
    ALLOCATE (ea(SIZE(l0)))
    ea = 1.0e9_wp
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK, 'loop: audit evaluated')
    CALL check(.NOT. au%physical .AND. au%failed_check == CD_HC_AUDIT_BACKTRACK, 'loop: closed loop rejected')
    CALL check(au%tangent_reversal > 0.99_wp, 'loop: tangent turns fully back')
    CALL check(au%backtrack > 9.0_wp, 'loop: backtracking length reported')
    DEALLOCATE (l0, q, ea)
    CALL build_curve('fold', 140, l0, q)
    ALLOCATE (ea(SIZE(l0)))
    ea = 1.0e9_wp
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK, 'fold: audit evaluated')
    CALL check(.NOT. au%physical .AND. au%failed_check == CD_HC_AUDIT_BACKTRACK, 'fold: hairpin fold rejected')
    ! With diameters the geometric self-contact test decides: the 10 m-high hairpin does
    ! not touch itself (its stability is judged separately), a closed planar loop does.
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em, diameter=[(0.2_wp, i=1, SIZE(l0))])
    CALL check(es == CD_HCSTAT_OK .AND. au%self_contact_checked .AND. au%physical .AND. au%self_gap > 9.0_wp, &
               'self-contact: separated hairpin legs are clear')
    DEALLOCATE (l0, q, ea)
    CALL build_curve('loop', 160, l0, q)
    ALLOCATE (ea(SIZE(l0)))
    ea = 1.0e9_wp
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em, diameter=[(0.2_wp, i=1, SIZE(l0))])
    CALL check(es == CD_HCSTAT_OK .AND. .NOT. au%physical .AND. au%failed_check == CD_HC_AUDIT_BACKTRACK .AND. &
               au%self_gap < 0.0_wp, 'self-contact: a closed loop crosses itself')
    CALL build_curve('sag', 40, l0, q)
    CALL CD_HermiteCable_Branch_Audit(l0, q, [(1.0e9_wp, i=1, 40)], au, es, em, diameter=[(0.2_wp, i=1, 40)])
    CALL check(es == CD_HCSTAT_OK .AND. au%physical, 'self-contact: a sagging line is clear of itself')
  END SUBROUTINE case_loop_and_fold

  SUBROUTINE case_end_zone_and_vertical()
    REAL(wp), ALLOCATABLE :: l0(:), q(:), ea(:)
    TYPE(CD_HermiteBranchAuditType) :: au
    INTEGER :: es
    CHARACTER(200) :: em
    ! The hairpin sits between arc 60 m and 86 m; an end zone covering it from the far end
    ! (total ~ 125.7 m) exempts it, as for the boundary layer of a restrained end.
    CALL build_curve('fold', 140, l0, q)
    ALLOCATE (ea(SIZE(l0)))
    ea = 1.0e9_wp
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em, end_zone=[0.0_wp, SUM(l0) - 59.0_wp])
    CALL check(es == CD_HCSTAT_OK .AND. au%physical, 'end zone: reversal inside the exempt layer accepted')
    DEALLOCATE (l0, q, ea)
    CALL build_curve('vertical', 20, l0, q)
    ALLOCATE (ea(20))
    ea = 1.0e9_wp
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. .NOT. au%backtrack_checked .AND. au%physical, &
               'vertical: chord without horizontal extent skips the reversal test')
  END SUBROUTINE case_end_zone_and_vertical

  SUBROUTINE case_kink()
    REAL(wp) :: l0(2), q(18), ea(2)
    TYPE(CD_HermiteBranchAuditType) :: au
    INTEGER :: es
    CHARACTER(200) :: em
    ! Two elements meeting in a 90-degree corner carried by the tangent handles.
    l0 = 1.0_wp
    ea = 1.0e8_wp
    q = 0.0_wp
    q(1:3) = [0.0_wp, 0.0_wp, 0.0_wp]; q(4:6) = [1.0_wp, 0.0_wp, 0.0_wp]
    q(7:9) = [1.0_wp, 0.0_wp, 0.0_wp]; q(10:12) = [0.0_wp, 0.0_wp, 1.0_wp]
    q(13:15) = [1.0_wp, 0.0_wp, 1.0_wp]; q(16:18) = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK, 'kink: audit evaluated')
    CALL check(.NOT. au%physical .AND. au%failed_check == CD_HC_AUDIT_KINK .AND. au%h_kappa_peak > 0.7_wp, &
               'kink: element-localized fold rejected')
  END SUBROUTINE case_kink

  SUBROUTINE case_compression_report()
    REAL(wp) :: l0(4), q(30), ea(4)
    TYPE(CD_HermiteBranchAuditType) :: au
    INTEGER :: es, i
    CHARACTER(200) :: em
    ! Straight line compressed uniformly by 1e-5 strain (EA 1e9 -> 1e4 N compression).
    l0 = 1.0_wp
    ea = 1.0e9_wp
    q = 0.0_wp
    DO i = 0, 4
      q(6*i + 1) = REAL(i, wp)*(1.0_wp - 1.0e-5_wp)
      q(6*i + 4) = 1.0_wp - 1.0e-5_wp
    END DO
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. au%compressed .AND. au%physical, &
               'compression: reported but not rejected by default')
    CALL check(ABS(au%mean_axial_min + 1.0e4_wp) < 1.0_wp, 'compression: element-mean force recovered')
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em, reject_compression=.TRUE.)
    CALL check(.NOT. au%physical .AND. au%failed_check == CD_HC_AUDIT_COMPRESSION, &
               'compression: rejected on request')
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em, compression_allowance=2.0e4_wp, &
                                      reject_compression=.TRUE.)
    CALL check(au%physical .AND. .NOT. au%compressed, 'compression: within the bending allowance')
    ! Compression spanning the line survives the 3-element smoothing.
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(au%smoothed_compressed .AND. ABS(au%smoothed_axial_min + 1.0e4_wp) < 1.0_wp, &
               'compression: uniform compression is smoothed-compressed')
  END SUBROUTINE case_compression_report

  SUBROUTINE case_isolated_compressed_element()
    REAL(wp) :: l0(5), q(36), ea(5), x
    TYPE(CD_HermiteBranchAuditType) :: au
    INTEGER :: es, i
    CHARACTER(200) :: em
    ! Straight line along x: elements stretched by 1e-4 except element 3, compressed by
    ! 1e-5 (element means +1e5 N and -1e4 N at EA 1e9: the Gauss mean of |r'| of a
    ! straight cubic is its chord ratio). A single compressed element between tensile
    ! neighbours is a mesh-local dip; the smoothed resultant stays tensile.
    l0 = 1.0_wp
    ea = 1.0e9_wp
    q = 0.0_wp
    x = 0.0_wp
    DO i = 0, 5
      q(6*i + 1) = x
      q(6*i + 4) = 1.0_wp
      IF (i < 5) x = x + MERGE(1.0_wp - 1.0e-5_wp, 1.0_wp + 1.0e-4_wp, i == 2)
    END DO
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. au%compressed .AND. au%axial_min_elem == 3 .AND. &
               ABS(au%mean_axial_min + 1.0e4_wp) < 1.0_wp, 'isolated dip: element-mean compression at element 3')
    CALL check(.NOT. au%smoothed_compressed .AND. au%smoothed_axial_min > 5.0e4_wp, &
               'isolated dip: smoothed element-mean force is tensile')
    ! Two adjacent elements compressed as strongly as their neighbours are stretched are
    ! not an isolated dip: the smoothed minimum is compressive.
    x = 0.0_wp
    DO i = 0, 5
      q(6*i + 1) = x
      IF (i < 5) x = x + MERGE(1.0_wp - 1.0e-4_wp, 1.0_wp + 1.0e-4_wp, i == 2 .OR. i == 3)
    END DO
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_OK .AND. au%smoothed_compressed, &
               'isolated dip: two compressed neighbours remain smoothed-compressed')
  END SUBROUTINE case_isolated_compressed_element

  SUBROUTINE case_resolution_modes()
    TYPE(CD_HermiteResolutionType) :: dg
    REAL(wp) :: l0(2), q(18), ea(2)
    INTEGER :: es, i
    CHARACTER(160) :: em
    ! Element 1 in tension 5 kN, element 2 in compression 6 kN, EA = 4e9 (strain band 8 kN).
    l0 = 1.0_wp
    ea = 4.0e9_wp
    q = 0.0_wp
    q(4) = 1.0_wp + 1.25e-6_wp
    q(7) = 1.0_wp + 1.25e-6_wp
    q(10) = 1.0_wp
    q(13) = q(7) + 1.0_wp - 1.5e-6_wp
    q(16) = 1.0_wp - 1.5e-6_wp
    ! make each element uniform: node 2 tangent is the average; accept small gradients
    q(10) = 0.5_wp*(q(4) + q(16))
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.0_wp, CD_HC_HKAPPA_TARGET, dg, es, em, EA=ea)
    CALL check(es == CD_HCSTAT_OK .AND. .NOT. dg%axial_compression, &
               'modes: default strain band accepts compression above the peak tension')
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.0_wp, CD_HC_HKAPPA_TARGET, dg, es, em, EA=ea, &
                                            compression_mode=CD_HC_COMPRESSION_RELATIVE)
    CALL check(es == CD_HCSTAT_OK .AND. dg%axial_compression .AND. dg%axial_strain_min_elem == 2, &
               'modes: tension-relative band flags it')
    CALL check(dg%axial_tolerance < 10.0_wp, 'modes: relative tolerance is a small fraction of the peak tension')
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.0_wp, CD_HC_HKAPPA_TARGET, dg, es, em, EA=ea, &
                                            compression_mode=CD_HC_COMPRESSION_STRICT)
    CALL check(es == CD_HCSTAT_OK .AND. dg%axial_compression, 'modes: strict band flags it')
    CALL CD_HermiteCable_Resolution_Metrics(l0, q, -1.0e4_wp, 0.0_wp, CD_HC_HKAPPA_TARGET, dg, es, em, EA=ea, &
                                            compression_mode=7)
    CALL check(es == CD_HCSTAT_BADINPUT, 'modes: unknown mode rejected')
    i = CD_HC_COMPRESSION_STRAIN
    CALL check(i == 0, 'modes: strain band is the default mode')
  END SUBROUTINE case_resolution_modes

  SUBROUTINE hanging_line(ne, l0, ea, ei, w, seed_cat, seed_chord, fixed)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: l0(:), ea(:), ei(:), w(:), seed_cat(:), seed_chord(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: fixed(:)
    REAL(wp) :: a(3), b(3), pos(3*(ne + 1)), h, g, d(3)
    INTEGER :: i, es
    CHARACTER(200) :: em
    ! 100 m heavy line hung between two points 94 m apart (a strut-prone geometry).
    ALLOCATE (l0(ne), ea(ne), ei(ne), w(ne), seed_cat(6*(ne + 1)), seed_chord(6*(ne + 1)), fixed(6 + 2*(ne + 1)))
    l0 = 100.0_wp/REAL(ne, wp)
    ea = 1.0e9_wp
    ei = 2.0e4_wp
    w = 800.0_wp
    a = [0.0_wp, 0.0_wp, -100.0_wp]
    b = [94.0_wp, 0.0_wp, -100.0_wp]
    CALL CD_Catenary_Seed(a, b, l0, ea, w, pos, h, g, es, em, suspended=.TRUE.)
    CALL check(es == CD_CAT_OK, 'setup: catenary seed '//TRIM(em))
    seed_cat = 0.0_wp
    seed_chord = 0.0_wp
    DO i = 0, ne
      seed_cat(6*i + 1:6*i + 3) = pos(3*i + 1:3*i + 3)
      seed_chord(6*i + 1:6*i + 3) = a + (b - a)*REAL(i, wp)/REAL(ne, wp)
      seed_chord(6*i + 4:6*i + 6) = [1.0_wp, 0.0_wp, 0.0_wp]
    END DO
    DO i = 0, ne
      IF (i < ne) THEN
        d = pos(3*i + 4:3*i + 6) - pos(3*i + 1:3*i + 3)
      ELSE
        d = pos(3*i + 1:3*i + 3) - pos(3*i - 2:3*i)
      END IF
      seed_cat(6*i + 4:6*i + 6) = d/NORM2(d)
    END DO
    fixed(1:6) = [1, 2, 3, 6*ne + 1, 6*ne + 2, 6*ne + 3]
    DO i = 0, ne
      fixed(7 + 2*i) = 6*i + 2
      fixed(8 + 2*i) = 6*i + 5
    END DO
  END SUBROUTINE hanging_line

  SUBROUTINE case_stability_and_continuation()
    INTEGER, PARAMETER :: NE = 40
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), ei(:), w(:), seed_cat(:), seed_chord(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp) :: q(6*(NE + 1)), q2(6*(NE + 1)), curv(NE + 1), res, zmid
    INTEGER :: it, es
    LOGICAL :: stable
    CHARACTER(300) :: em
    CALL hanging_line(NE, l0, ea, ei, w, seed_cat, seed_chord, fixed)
    ! Continuation from the catenary seed reaches the hanging (stable) equilibrium.
    CALL CD_HermiteCable_Static_Solve_Continuation(l0, ea, ei, w, seed_cat, fixed, -1.0e4_wp, 0.0_wp, &
                                                   40, 1.0e-8_wp, 1.0e-3_wp, 2000, q, curv, res, it, es, em)
    CALL check(es == CD_HCSTAT_OK, 'continuation: catenary seed converges: '//TRIM(em))
    zmid = q(6*(NE/2) + 3)
    CALL check(zmid < -110.0_wp, 'continuation: the line hangs (sag below the endpoints)')
    CALL CD_HermiteCable_Static_Solve(l0, ea, ei, w, q, fixed, -1.0e4_wp, 0.0_wp, 1, 1, HUGE(1.0_wp), 1.0_wp, &
                                      q2, curv, res, it, es, em, stable=stable)
    CALL check(es == CD_HCSTAT_OK .AND. stable, 'stability: the hanging line is a stable equilibrium')
    ! The straight chord is an exact equilibrium of the symmetric problem only when the
    ! weight is absent; with the weight off, a 6% over-length line held straight is a
    ! compressed strut, which the stability test rejects.
    CALL CD_HermiteCable_Static_Solve(l0, ea, ei, 0.0_wp*w, seed_chord, fixed, -1.0e4_wp, 0.0_wp, 1, 1, &
                                      HUGE(1.0_wp), 1.0_wp, q, curv, res, it, es, em, stable=stable)
    CALL check(es == CD_HCSTAT_OK .AND. .NOT. stable, 'stability: a straight compressed strut is unstable')
    ! Energy-minimizing continuation from the straight chord seed does not stop at the strut.
    CALL CD_HermiteCable_Static_Solve_Continuation(l0, ea, ei, w, seed_chord, fixed, -1.0e4_wp, 0.0_wp, &
                                                   40, 1.0e-8_wp, 1.0_wp, 4000, q, curv, res, it, es, em)
    IF (es == CD_HCSTAT_OK) THEN
      WRITE (*, '(A,ES12.4)') '  chord-seed continuation mid-span z = ', q(6*(NE/2) + 3)
      CALL check(q(6*(NE/2) + 3) < -110.0_wp, 'continuation: chord seed reaches the hanging branch')
    END IF
  END SUBROUTINE case_stability_and_continuation

  SUBROUTINE case_fail_closed()
    REAL(wp) :: l0(2), q(18), ea(3), qo(18), curv(3), res
    TYPE(CD_HermiteBranchAuditType) :: au
    INTEGER :: es, it, fixed(3)
    CHARACTER(200) :: em
    l0 = 1.0_wp
    q = 0.0_wp
    ea = 1.0_wp
    CALL CD_HermiteCable_Branch_Audit(l0, q, ea, au, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail-closed: audit rejects inconsistent sizes')
    fixed = [1, 2, 3]
    CALL CD_HermiteCable_Static_Solve_Continuation(l0, [1.0_wp, 1.0_wp], [1.0_wp, 1.0_wp], [1.0_wp, 1.0_wp], q, &
                                                   fixed, 0.0_wp, 0.0_wp, 5, 1.0e-8_wp, 0.0_wp, 10, qo, curv, &
                                                   res, it, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail-closed: continuation rejects ei_start = 0')
    CALL CD_HermiteCable_Static_Solve_Continuation(l0, [1.0_wp, 1.0_wp], [1.0_wp, 1.0_wp], [1.0_wp, 1.0_wp], q, &
                                                   fixed, 0.0_wp, 0.0_wp, 5, 1.0e-8_wp, 0.5_wp, 0, qo, curv, &
                                                   res, it, es, em)
    CALL check(es == CD_HCSTAT_BADINPUT, 'fail-closed: continuation rejects a zero budget')
    it = CD_HCSTAT_NOCONVERGE
  END SUBROUTINE case_fail_closed

END PROGRAM test_hermite_branch_audit
