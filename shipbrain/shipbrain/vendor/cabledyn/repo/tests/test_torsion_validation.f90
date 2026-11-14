! File: tests/test_torsion_validation.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_torsion_validation
  !! Validation gates of condensed torsion on the cubic-Hermite cable that complement the kernel,
  !! statics, dynamics and deck tests:
  !!   Z  zero-twist parity (V3): a sagging line clamped at both ends with out-of-plane end
  !!      directions (a three-dimensional shape with a non-zero holonomy Theta_0), restrained in
  !!      torsion with Phi = Theta_0, reproduces the solve without torsion to solver tolerance
  !!      and carries no torque;
  !!   H  Kirchhoff helix (V5): a = 1, pitch angle 30 deg, EI = 1, M_t = 0.5, four turns on 96
  !!      elements, clamped on the exact helix with Phi = Theta_helix + M_t C: the line stays on
  !!      the helix and the end reaction is the wrench of the helical equilibrium, F = 0.058013
  !!      along the axis and K = 0.899519 about it (van der Heijden et al. 2003, eqs. 1-5);
  !!   L  localised (hockling) onset (V6, static form): clamped-clamped critical torque at
  !!      T L^2/EI = 400 and 1600 against eq. (33), approaching 2 sqrt(EI T) from above;
  !!   C  cross-check against the Cosserat rod path (V7): pure torsion, and a rod clamped with
  !!      its far end displaced and rotated (bent and twisted), solved by both formulations:
  !!      shape and torque within 1 %;
  !!   S  the rank-one (Sherman-Morrison) term of the bordered Newton step (WP3 review): near the
  !!      Greenhill onset and on the post-buckled branch, Newton with the bordered tangent
  !!      B + g g^T / C converges quadratically, while the same iteration without g g^T / C
  !!      converges slowly or not at all, and B alone is indefinite on the post-buckled branch.
  !! Argument 1: tests/data/torsion_analytic_refs.txt.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Element
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Line, CD_HermiteTorsion_Unwrap, &
                                     CD_HermiteTorsion_Bordered_Solve, CD_HermiteTorsion_Inertia, CD_HTORS_OK, &
                                     CD_HTORS_KBAND, CD_HTORS_PI
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID
  USE CableDyn_CosseratStatic, ONLY: CosseratSolverConfig, CD_Static_Cosserat_Solve, CD_COS_OK
  USE CableDyn_Cosserat, ONLY: CD_Reference_Frame, CD_Cosserat_Strains
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = CD_HTORS_PI
  INTEGER, PARAMETER :: KB = CD_HTORS_KBAND, LDAB = 3*KB + 1
  INTEGER :: nfail = 0
  CHARACTER(512) :: ref_path
  REAL(wp) :: ref_local(2, 2), ref_helix(6)

  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'usage: test_torsion_validation <torsion_analytic_refs.txt>'
    ERROR STOP 2
  END IF
  CALL GET_COMMAND_ARGUMENT(1, ref_path)
  CALL read_refs()

  CALL check_zero_twist_parity()
  CALL check_helix()
  CALL check_localised_onset()
  CALL check_cosserat()
  CALL check_bordered_term()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' torsion validation assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: torsion validation (zero-twist parity, helix, localised onset, Cosserat, bordered step)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. ok) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: '//label
    END IF
  END SUBROUTINE require

  SUBROUTINE read_refs()
    !! "localised T M_cr" (two rows, EI = L = 1) and "helix a alpha_deg B M_t F K".
    INTEGER :: u, ios, nl, nh
    CHARACTER(256) :: line
    CHARACTER(16) :: tag
    REAL(wp) :: v(6)
    nl = 0
    nh = 0
    OPEN (NEWUNIT=u, FILE=ref_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'cannot open '//TRIM(ref_path)
      ERROR STOP 2
    END IF
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(line) == 0 .OR. line(1:1) == '#') CYCLE
      READ (line, *, IOSTAT=ios) tag
      IF (ios /= 0) CYCLE
      IF (TRIM(tag) == 'localised' .AND. nl < 2) THEN
        READ (line, *, IOSTAT=ios) tag, v(1:2)
        IF (ios /= 0) CYCLE
        nl = nl + 1
        ref_local(nl, :) = v(1:2)
      ELSE IF (TRIM(tag) == 'helix' .AND. nh < 1) THEN
        READ (line, *, IOSTAT=ios) tag, v
        IF (ios /= 0) CYCLE
        nh = nh + 1
        ref_helix = v
      END IF
    END DO
    CLOSE (u)
    IF (nl /= 2 .OR. nh /= 1) THEN
      WRITE (*, '(A)') 'reference file incomplete (localised, helix rows): '//TRIM(ref_path)
      ERROR STOP 2
    END IF
  END SUBROUTINE read_refs

  ! ------------------------------------------------------------------------------------------
  ! the condensed energy of a line in the test's own assembly (no loads, both end nodes held)
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE line_energy(q, l0, ea, ei, ends, c, phi, theta_ref, e_tot, theta, mt, ok, r, ab, g)
    !! E = sum_e U_e(q) + (Phi - Theta)^2 / (2 C), Theta unwrapped against theta_ref. Optional:
    !! r = dE/dq, ab = sum_e K_e - M_t d2Theta/dq2 in DGBSV band storage (the band part B of the
    !! tangent), g = dTheta/dq; the DOFs of both end nodes are held (rows and columns of B set
    !! to the identity, r and g zeroed there).
    REAL(wp), INTENT(IN) :: q(:), l0(:), ea, ei, ends(3, 4), c, phi, theta_ref
    REAL(wp), INTENT(OUT) :: e_tot, theta, mt
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), INTENT(OUT), OPTIONAL :: r(:), ab(:, :), g(:)
    REAL(wp) :: fe(12), ke(12, 12), ee, raw
    REAL(wp), ALLOCATABLE :: gq(:)
    INTEGER :: e, i, j, ii, jj, nd, es
    CHARACTER(256) :: em
    nd = SIZE(q)
    ALLOCATE (gq(nd))
    e_tot = 0.0_wp
    IF (PRESENT(r)) r = 0.0_wp
    IF (PRESENT(ab)) ab = 0.0_wp
    ok = .FALSE.
    DO e = 1, SIZE(l0)
      CALL CD_HermiteCable_Element(q(6*e - 5:6*e + 6), l0(e), ea, ei, ee, fe, ke, es, em)
      IF (es /= 0) RETURN
      e_tot = e_tot + ee
      IF (PRESENT(r)) r(6*e - 5:6*e + 6) = r(6*e - 5:6*e + 6) + fe
      IF (PRESENT(ab)) THEN
        DO jj = 1, 12
          j = 6*(e - 1) + jj
          DO ii = 1, 12
            i = 6*(e - 1) + ii
            ab(2*KB + 1 + i - j, j) = ab(2*KB + 1 + i - j, j) + ke(ii, jj)
          END DO
        END DO
      END IF
    END DO
    CALL CD_HermiteTorsion_Line(q, l0, ends, raw, gq, es, em)
    IF (es /= CD_HTORS_OK) RETURN
    theta = CD_HermiteTorsion_Unwrap(raw, theta_ref)
    mt = (phi - theta)/c
    e_tot = e_tot + 0.5_wp*(phi - theta)**2/c
    IF (PRESENT(r)) r = r - mt*gq
    IF (PRESENT(ab)) THEN
      CALL CD_HermiteTorsion_Line(q, l0, ends, raw, gq, es, em, hband=ab, band_scale=-mt)
      IF (es /= CD_HTORS_OK) RETURN
    END IF
    IF (PRESENT(g)) g = gq
    DO i = 1, nd
      IF (i > 6 .AND. i <= nd - 6) CYCLE
      IF (PRESENT(r)) r(i) = 0.0_wp
      IF (PRESENT(g)) g(i) = 0.0_wp
      IF (PRESENT(ab)) THEN
        DO j = MAX(1, i - KB), MIN(nd, i + KB)
          ab(2*KB + 1 + i - j, j) = 0.0_wp
          ab(2*KB + 1 + j - i, i) = 0.0_wp
        END DO
        ab(2*KB + 1, i) = 1.0_wp
      END IF
    END DO
    ok = ABS(e_tot) < HUGE(1.0_wp)
  END SUBROUTINE line_energy

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_zero_twist_parity()
    !! V3: sagging line (EA 1e5, EI 1, w 5, L = 1, 24 elements), ends 0.9 apart along x and
    !! clamped along out-of-plane directions; solved without torsion, then with both ends
    !! restrained and Phi = Theta_0, the holonomy of that untwisted equilibrium.
    INTEGER, PARAMETER :: NE = 24, ND = 6*(NE + 1)
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: seed(ND), q0(ND), q1(ND), l0(NE), gq(ND), ends(3, 4), raw, dq, da(3), db(3)
    INTEGER :: k, es
    CHARACTER(512) :: em
    l0 = 1.0_wp/NE
    da = [1.0_wp, 1.2_wp, -1.0_wp]/NORM2([1.0_wp, 1.2_wp, -1.0_wp])
    db = [0.2_wp, 1.0_wp, 1.0_wp]/NORM2([0.2_wp, 1.0_wp, 1.0_wp])
    DO k = 0, NE
      seed(6*k + 1:6*k + 6) = [0.9_wp*k/NE, 0.0_wp, -0.2_wp*SIN(PI*k/NE), 0.9_wp, 0.0_wp, -0.2_wp*PI*COS(PI*k/NE)]
    END DO
    CALL sag(seed, da, db, q0, es, em)
    CALL require(es == CD_HCSTAT_OK, 'Z: untwisted 3D sag solve converges: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    ends(:, 1) = da
    ends(:, 2) = unit_perp([0.0_wp, 1.0_wp, 0.0_wp], da)
    ends(:, 3) = db
    ends(:, 4) = unit_perp([0.0_wp, 1.0_wp, 0.0_wp], db)
    CALL CD_HermiteTorsion_Line(q0, l0, ends, raw, gq, es, em)
    CALL require(es == CD_HTORS_OK, 'Z: holonomy of the untwisted state')
    tors%active = .TRUE.
    ALLOCATE (tors%gj(NE))
    tors%gj = 0.3_wp
    tors%ends = ends
    tors%phi = raw
    tors%theta_hint = raw
    CALL sag(seed, da, db, q1, es, em, tors)
    CALL require(es == CD_HCSTAT_OK, 'Z: twist-restrained solve with Phi = Theta_0 converges: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    dq = nan_max_abs(q1 - q0)
    WRITE (*, '(A,F9.5,A,ES10.3,A,ES10.3,A,L1)') 'zero-twist parity (3D sag): Theta_0 = ', raw, ' rad, |q - q_0| = ', &
      dq, ', torque ', tors%torque, ', stable ', tors%stable
    CALL require(ABS(raw) > 1.0e-2_wp, 'Z: the untwisted 3D line has a non-zero holonomy')
    CALL require(dq <= 1.0e-8_wp, 'Z: the restrained untwisted line equals the line without torsion (1e-8)')
    CALL require(ABS(tors%torque) <= 1.0e-8_wp, 'Z: no torque at Phi = Theta_0')
    CALL require(tors%stable, 'Z: stable')
  END SUBROUTINE check_zero_twist_parity

  SUBROUTINE sag(s0, d1, d2, qo, es2, em2, t)
    !! The V3 sagging line (EA 1e5, EI 1, w 5, unit length) clamped along d1 and d2.
    REAL(wp), INTENT(IN) :: s0(:), d1(3), d2(3)
    REAL(wp), INTENT(OUT) :: qo(:)
    INTEGER, INTENT(OUT) :: es2
    CHARACTER(*), INTENT(OUT) :: em2
    TYPE(CD_HermiteTorsionType), INTENT(INOUT), OPTIONAL :: t
    REAL(wp), ALLOCATABLE :: l0(:), curv(:)
    REAL(wp) :: res
    INTEGER :: ne, nd, it
    nd = SIZE(s0)
    ne = nd/6 - 1
    ALLOCATE (l0(ne), curv(ne + 1))
    l0 = 1.0_wp/ne
    IF (PRESENT(t)) THEN
      CALL CD_HermiteCable_Static_Solve(l0, [(1.0e5_wp, it=1, ne)], [(1.0_wp, it=1, ne)], [(5.0_wp, it=1, ne)], &
                                        s0, [1, 2, 3, nd - 5, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 4, 100, &
                                        1.0e-9_wp, 1.0_wp, qo, curv, res, it, es2, em2, &
                                        endconn_stiffness=[0.0_wp, 0.0_wp], &
                                        endconn_direction=RESHAPE([d1, d2], [3, 2]), &
                                        endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=t)
    ELSE
      CALL CD_HermiteCable_Static_Solve(l0, [(1.0e5_wp, it=1, ne)], [(1.0_wp, it=1, ne)], [(5.0_wp, it=1, ne)], &
                                        s0, [1, 2, 3, nd - 5, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 4, 100, &
                                        1.0e-9_wp, 1.0_wp, qo, curv, res, it, es2, em2, &
                                        endconn_stiffness=[0.0_wp, 0.0_wp], &
                                        endconn_direction=RESHAPE([d1, d2], [3, 2]), &
                                        endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
    END IF
  END SUBROUTINE sag

  FUNCTION unit_perp(v, d) RESULT(n)
    REAL(wp), INTENT(IN) :: v(3), d(3)
    REAL(wp) :: n(3)
    n = v - DOT_PRODUCT(v, d)*d
    n = n/NORM2(n)
  END FUNCTION unit_perp

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_helix()
    !! V5: helix r(s) = (a cos p, a sin p, s sin(alpha)), p = s cos(alpha)/a, four turns, 96
    !! elements (13.0 deg of tangent turn per element), EA 1e5 (EA/F > 1e6), GJ = 1, both ends
    !! clamped with the Frenet normals as reference normals. Theta_helix = -tau l (oracle), and
    !! Phi = Theta_helix + M_t C. The end reaction is measured as the derivative of the discrete
    !! total energy: dE/dr_1 (force) and dE/dw (moment of a rigid rotation of the End-1 frame
    !! and its clamped tangent about r_1).
    INTEGER, PARAMETER :: NE = 96, ND = 6*(NE + 1)
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: a, alpha, bb, mt0, fref, kref, tau, ell, seed(ND), q(ND), l0(NE), curv(NE + 1), res, c
    REAL(wp) :: s, p, t0(3), t1(3), n0(3), n1(3), drift, f1(3), mom(3), mexp(3), ferr, merr, h
    REAL(wp) :: ep, emn, theta, mt, ends(3, 4), qp(ND), endsp(3, 4), rot(3, 3), w(3)
    INTEGER :: k, it, es, ic
    LOGICAL :: ok
    CHARACTER(512) :: em
    a = ref_helix(1)
    alpha = ref_helix(2)*PI/180.0_wp
    bb = ref_helix(3)
    mt0 = ref_helix(4)
    fref = ref_helix(5)
    kref = ref_helix(6)
    tau = SIN(alpha)*COS(alpha)/a
    ell = 4.0_wp*2.0_wp*PI*a/COS(alpha)
    l0 = ell/NE
    DO k = 0, NE
      s = ell*k/NE
      p = s*COS(alpha)/a
      seed(6*k + 1:6*k + 3) = [a*COS(p), a*SIN(p), s*SIN(alpha)]
      seed(6*k + 4:6*k + 6) = [-SIN(p)*COS(alpha), COS(p)*COS(alpha), SIN(alpha)]
    END DO
    t0 = seed(4:6)
    t1 = seed(ND - 2:ND)
    n0 = [-1.0_wp, 0.0_wp, 0.0_wp]
    p = ell*COS(alpha)/a
    n1 = [-COS(p), -SIN(p), 0.0_wp]
    c = ell/1.0_wp
    tors%active = .TRUE.
    ALLOCATE (tors%gj(NE))
    tors%gj = 1.0_wp
    tors%ends(:, 1) = t0
    tors%ends(:, 2) = n0
    tors%ends(:, 3) = t1
    tors%ends(:, 4) = n1
    tors%theta_hint = -tau*ell
    tors%phi = -tau*ell + mt0*c
    tors%descend = .FALSE.
    ends = tors%ends
    CALL CD_HermiteCable_Static_Solve(l0, [(1.0e5_wp, it=1, NE)], [(bb, it=1, NE)], [(0.0_wp, it=1, NE)], seed, &
                                      [1, 2, 3, ND - 5, ND - 4, ND - 3], -1.0e6_wp, 0.0_wp, 1, 100, 1.0e-8_wp, &
                                      1.0_wp, q, curv, res, it, es, em, endconn_stiffness=[0.0_wp, 0.0_wp], &
                                      endconn_direction=RESHAPE([t0, t1], [3, 2]), &
                                      endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=tors)
    CALL require(es == CD_HCSTAT_OK, 'H: clamped helix solve converges: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) RETURN
    drift = 0.0_wp
    DO k = 0, NE
      drift = nan_max_abs([drift, ABS(NORM2(q(6*k + 1:6*k + 2)) - a)])
    END DO
    ! end reaction: derivatives of the discrete total energy at the solution
    h = 1.0e-6_wp
    DO ic = 1, 3
      qp = q
      qp(ic) = q(ic) + h
      CALL line_energy(qp, l0, 1.0e5_wp, bb, ends, c, tors%phi, tors%theta, ep, theta, mt, ok)
      qp(ic) = q(ic) - h
      CALL line_energy(qp, l0, 1.0e5_wp, bb, ends, c, tors%phi, tors%theta, emn, theta, mt, ok)
      f1(ic) = (ep - emn)/(2.0_wp*h)
      w = 0.0_wp
      w(ic) = h
      rot = CD_Exp_SO3(w)
      qp = q
      qp(4:6) = MATMUL(rot, q(4:6))
      endsp = ends
      endsp(:, 1) = MATMUL(rot, ends(:, 1))
      endsp(:, 2) = MATMUL(rot, ends(:, 2))
      CALL line_energy(qp, l0, 1.0e5_wp, bb, endsp, c, tors%phi, tors%theta, ep, theta, mt, ok)
      rot = CD_Exp_SO3(-w)
      qp(4:6) = MATMUL(rot, q(4:6))
      endsp(:, 1) = MATMUL(rot, ends(:, 1))
      endsp(:, 2) = MATMUL(rot, ends(:, 2))
      CALL line_energy(qp, l0, 1.0e5_wp, bb, endsp, c, tors%phi, tors%theta, emn, theta, mt, ok)
      mom(ic) = (ep - emn)/(2.0_wp*h)
    END DO
    ! the helical wrench (F e_z, K e_z) about the axis, reduced to the end point r_1 = (a, 0, 0)
    mexp = [0.0_wp, a*fref, kref]
    ferr = MIN(NORM2(f1 - fref*[0.0_wp, 0.0_wp, 1.0_wp]), NORM2(f1 + fref*[0.0_wp, 0.0_wp, 1.0_wp]))/fref
    merr = MIN(NORM2(mom - mexp), NORM2(mom + mexp))/kref
    WRITE (*, '(A,I0,A,ES10.3,A,F10.7,A,3F11.7,A,3F11.7,A,L1)') 'helix (', NE, ' elements): radius drift/a ', &
      drift/a, ', M_t ', tors%torque, ', end force ', f1, ', end moment ', mom, ', stable ', tors%stable
    WRITE (*, '(A,F10.7,A,F10.7,A,ES10.3,A,ES10.3)') 'helix: reference F = ', fref, ', K = ', kref, &
      '; force error/F ', ferr, ', moment error/K ', merr
    CALL require(drift <= 5.0e-4_wp*a, 'H: the line stays on the helix (radius drift <= 5e-4 a)')
    CALL require(ABS(tors%torque - mt0) <= 1.0e-4_wp*mt0, 'H: M_t = 0.5')
    CALL require(ferr <= 5.0e-3_wp, 'H: end force = F e_z within 0.5 %')
    CALL require(merr <= 5.0e-3_wp, 'H: end moment = K e_z + lever within 0.5 % of K')
  END SUBROUTINE check_helix

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_localised_onset()
    !! V6 (static form): clamped-clamped, sliding End 2 under the dead tension T, onset bisected
    !! on the stability report of the straight state, N = 64 and 128 elements.
    INTEGER, PARAMETER :: NES(2) = [64, 128]
    REAL(wp) :: m(2), err(2), infinite
    INTEGER :: it, k
    DO it = 1, 2
      DO k = 1, 2
        m(k) = onset(NES(k), ref_local(it, 1), ref_local(it, 2))
        err(k) = ABS(m(k) - ref_local(it, 2))/ref_local(it, 2)
      END DO
      infinite = 2.0_wp*SQRT(ref_local(it, 1))
      WRITE (*, '(A,F7.1,A,2F12.6,A,F12.6,A,2ES10.2,A,F8.5)') 'localised onset T L^2/EI=', ref_local(it, 1), &
        ': M_cr L/EI (N=64,128) =', m, ' eq.(33) ', ref_local(it, 2), ' rel.err ', err, &
        '; ratio to 2 sqrt(EI T) ', m(2)/infinite
      CALL require(ALL(m > 0.0_wp), 'L: onset bracketed')
      CALL require(err(2) <= 1.0e-3_wp, 'L: N = 128 onset within 1e-3 of eq. (33)')
      CALL require(err(2) <= err(1), 'L: refinement does not move the onset away')
      CALL require(m(2) > infinite, 'L: the finite clamped rod buckles above 2 sqrt(EI T)')
    END DO
  END SUBROUTINE check_localised_onset

  REAL(wp) FUNCTION onset(ne, tension, mguess) RESULT(mcr)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(IN) :: tension, mguess
    REAL(wp) :: lo, hi, mid
    INTEGER :: k
    LOGICAL :: failed
    lo = 0.9_wp*mguess
    hi = 1.1_wp*mguess
    mcr = -1.0_wp
    IF (.NOT. stable_at(ne, tension, lo, failed)) RETURN
    IF (stable_at(ne, tension, hi, failed)) RETURN
    DO k = 1, 60
      mid = 0.5_wp*(lo + hi)
      IF (stable_at(ne, tension, mid, failed)) THEN
        lo = mid
      ELSE
        hi = mid
      END IF
      IF (failed) RETURN
      IF (hi - lo <= 1.0e-8_wp*mguess) EXIT
    END DO
    mcr = 0.5_wp*(lo + hi)
  END FUNCTION onset

  LOGICAL FUNCTION stable_at(ne, tension, m, failed) RESULT(stab)
    !! Straight weightless rod along +x, EI = L = GJ = 1, EA = 1e9 (T/EA <= 1.6e-6), node 1 held, the last node
    !! sliding along x under the dead tension; both ends clamped along +x; Phi = m (no descent).
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(IN) :: tension, m
    LOGICAL, INTENT(OUT) :: failed
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp), ALLOCATABLE :: seed(:), l0(:), q(:), f(:), curv(:)
    REAL(wp) :: res
    INTEGER :: nd, it, es, k
    CHARACTER(512) :: em
    nd = 6*(ne + 1)
    ALLOCATE (seed(nd), l0(ne), q(nd), f(nd), curv(ne + 1))
    l0 = 1.0_wp/ne
    seed = 0.0_wp
    DO k = 0, ne
      seed(6*k + 1) = REAL(k, wp)/ne
      seed(6*k + 4) = 1.0_wp
    END DO
    f = 0.0_wp
    f(nd - 5) = tension
    tors%active = .TRUE.
    ALLOCATE (tors%gj(ne))
    tors%gj = 1.0_wp
    tors%phi = m
    tors%ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                         0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    tors%descend = .FALSE.
    CALL CD_HermiteCable_Static_Solve(l0, [(1.0e9_wp, it=1, ne)], [(1.0_wp, it=1, ne)], [(0.0_wp, it=1, ne)], seed, &
                                      [1, 2, 3, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 1, 60, 1.0e-7_wp, 1.0_wp, q, &
                                      curv, res, it, es, em, f_nodal=f, endconn_stiffness=[0.0_wp, 0.0_wp], &
                                      endconn_direction=RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                [3, 2]), &
                                      endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=tors)
    failed = es /= CD_HCSTAT_OK
    IF (failed) WRITE (*, '(A)') '  solve failed: '//TRIM(em)
    stab = tors%stable .AND. .NOT. failed
  END FUNCTION stable_at

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_cosserat()
    !! V7: a rod of unit length along +z, EA 1e6, EI 1, GJ 0.7 (Cosserat GAs 1e6, reduced shear,
    !! 128 linear elements; Hermite 16 elements), End A clamped at the origin with frame
    !! (d, n) = (e_z, e_x). (1) End B at (0, 0, 1) turned by 2.5 rad about e_z; (2) End B at
    !! (0.15, -0.1, 0.98363) (chord = L) with the frame R_B = exp([0.25, -0.3, 1.2]). The Hermite line is
    !! clamped with d_B = R_B e_z, n_B = R_B e_x and Phi = 0 (the Cosserat reference is the
    !! untwisted straight rod). Compared: node positions at equal arc length and the torque
    !! (Hermite M_t; Cosserat GJ times the material twist curvature, mean over the elements).
    REAL(wp), PARAMETER :: THB(3, 2) = RESHAPE([0.0_wp, 0.0_wp, 2.5_wp, 0.25_wp, -0.3_wp, 1.2_wp], [3, 2])
    REAL(wp), PARAMETER :: RB(3, 2) = RESHAPE([0.0_wp, 0.0_wp, 1.0_wp, 0.15_wp, -0.1_wp, 0.98362593_wp], [3, 2])
    INTEGER :: icase
    REAL(wp) :: mt_h, mt_c, dpos
    REAL(wp), ALLOCATABLE :: rh(:, :), rc(:, :)
    LOGICAL :: ok_h, ok_c
    DO icase = 1, 2
      CALL hermite_rod(RB(:, icase), THB(:, icase), rh, mt_h, ok_h)
      CALL cosserat_rod(RB(:, icase), THB(:, icase), rc, mt_c, ok_c)
      CALL require(ok_h .AND. ok_c, 'C: both formulations converge')
      IF (.NOT. (ok_h .AND. ok_c)) CYCLE
      dpos = nan_max_abs(rh - rc(:, 1::8))
      WRITE (*, '(A,I0,A,ES10.3,A,F11.7,A,F11.7,A,ES10.3)') 'Cosserat cross-check ', icase, &
        ': max position difference/L ', dpos, ', torque Hermite ', mt_h, ' Cosserat ', mt_c, ' rel. ', &
        ABS(mt_h - mt_c)/ABS(mt_c)
      CALL require(dpos <= 1.0e-2_wp, 'C: shapes agree within 1 % of L')
      CALL require(ABS(mt_h - mt_c) <= 1.0e-2_wp*ABS(mt_c), 'C: torques agree within 1 %')
      IF (icase == 1) CALL require(ABS(mt_h - 0.7_wp*2.5_wp) <= 1.0e-10_wp, 'C: pure torsion GJ Phi / L (Hermite)')
    END DO
  END SUBROUTINE check_cosserat

  SUBROUTINE hermite_rod(rb, thb, rpos, mt, ok)
    REAL(wp), INTENT(IN) :: rb(3), thb(3)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: rpos(:, :)
    REAL(wp), INTENT(OUT) :: mt
    LOGICAL, INTENT(OUT) :: ok
    INTEGER, PARAMETER :: NE = 16, ND = 6*(NE + 1)
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: seed(ND), q(ND), l0(NE), curv(NE + 1), res, rmat(3, 3), dbv(3)
    INTEGER :: k, it, es
    CHARACTER(512) :: em
    rmat = CD_Exp_SO3(thb)
    dbv = rmat(:, 3)
    l0 = 1.0_wp/NE
    DO k = 0, NE
      seed(6*k + 1:6*k + 3) = rb*REAL(k, wp)/NE
      seed(6*k + 4:6*k + 6) = rb
    END DO
    tors%active = .TRUE.
    ALLOCATE (tors%gj(NE))
    tors%gj = 0.7_wp
    tors%ends(:, 1) = [0.0_wp, 0.0_wp, 1.0_wp]
    tors%ends(:, 2) = [1.0_wp, 0.0_wp, 0.0_wp]
    tors%ends(:, 3) = dbv
    tors%ends(:, 4) = rmat(:, 1)
    tors%phi = 0.0_wp
    CALL CD_HermiteCable_Static_Solve(l0, [(1.0e6_wp, it=1, NE)], [(1.0_wp, it=1, NE)], [(0.0_wp, it=1, NE)], seed, &
                                      [1, 2, 3, ND - 5, ND - 4, ND - 3], -1.0e6_wp, 0.0_wp, 4, 200, 1.0e-8_wp, &
                                      1.0_wp, q, curv, res, it, es, em, endconn_stiffness=[0.0_wp, 0.0_wp], &
                                      endconn_direction=RESHAPE([0.0_wp, 0.0_wp, 1.0_wp, dbv], [3, 2]), &
                                      endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=tors)
    ok = es == CD_HCSTAT_OK
    IF (.NOT. ok) WRITE (*, '(A)') '  Hermite solve: '//TRIM(em)
    ALLOCATE (rpos(3, NE + 1))
    DO k = 0, NE
      rpos(:, k + 1) = q(6*k + 1:6*k + 3)
    END DO
    mt = tors%torque
  END SUBROUTINE hermite_rod

  SUBROUTINE cosserat_rod(rb, thb, rpos, mt, ok)
    !! Linear-Lagrange Cosserat rod clamped at both ends (position and rotation vector), the End
    !! B pose reached in ten increments (each solve seeded with the previous one).
    REAL(wp), INTENT(IN) :: rb(3), thb(3)
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: rpos(:, :)
    REAL(wp), INTENT(OUT) :: mt
    LOGICAL, INTENT(OUT) :: ok
    INTEGER, PARAMETER :: NE = 128, NN = NE + 1, ND = 6*NN, NSTEP = 20
    REAL(wp) :: nodes(3, NN), q0(ND), q(ND), fext(ND), lam0(3, 3), len0, gam(3), kap(3), lam, zb(3)
    INTEGER :: conn(2, NE), fixed(12), k, istep, it, es
    LOGICAL :: conv, stalled
    TYPE(CosseratSolverConfig) :: cfg
    CHARACTER(160) :: em
    DO k = 1, NN
      nodes(:, k) = [0.0_wp, 0.0_wp, REAL(k - 1, wp)/NE]
    END DO
    DO k = 1, NE
      conn(:, k) = [k, k + 1]
    END DO
    fixed = [1, 2, 3, 4, 5, 6, ND - 5, ND - 4, ND - 3, ND - 2, ND - 1, ND]
    fext = 0.0_wp
    cfg%abs_tol = 1.0e-5_wp
    cfg%max_iter = 200
    q = 0.0_wp
    DO k = 1, NN
      q(6*k - 5:6*k - 3) = nodes(:, k)
    END DO
    zb = [0.0_wp, 0.0_wp, 1.0_wp]
    ok = .TRUE.
    DO istep = 1, NSTEP
      lam = REAL(istep, wp)/NSTEP
      q0 = q
      ! interior seed: previous state plus the end increment spread linearly; the end moves on
      ! the sphere |r_B| = |rb| (no compressive intermediate chord)
      DO k = 2, NN
        q0(6*k - 5:6*k - 3) = q(6*k - 5:6*k - 3) + (REAL(k - 1, wp)/NE)*(end_at(zb, rb, lam) - &
                                                                         end_at(zb, rb, lam - 1.0_wp/NSTEP))
        q0(6*k - 2:6*k) = q(6*k - 2:6*k) + (REAL(k - 1, wp)/NE)*thb/NSTEP
      END DO
      q0(ND - 5:ND - 3) = end_at(zb, rb, lam)
      q0(ND - 2:ND) = lam*thb
      CALL CD_Static_Cosserat_Solve(nodes, conn, [(1.0e6_wp, it=1, NE)], [(1.0e6_wp, it=1, NE)], &
                                    [(1.0_wp, it=1, NE)], [(0.7_wp, it=1, NE)], q0, fext, fixed, .TRUE., cfg, q, &
                                    conv, stalled, it, es, em)
      IF (es /= CD_COS_OK .OR. .NOT. conv) THEN
        ok = .FALSE.
        WRITE (*, '(A,I0,A)') '  Cosserat solve, increment ', istep, ': '//TRIM(em)
        EXIT
      END IF
    END DO
    ALLOCATE (rpos(3, NN))
    mt = 0.0_wp
    DO k = 1, NN
      rpos(:, k) = q(6*k - 5:6*k - 3)
    END DO
    DO k = 1, NE
      CALL CD_Reference_Frame(nodes(:, k), nodes(:, k + 1), lam0, len0)
      CALL CD_Cosserat_Strains(q(6*k - 5:6*k + 6), lam0, len0, 0.0_wp, gam, kap)
      mt = mt + 0.7_wp*kap(3)/NE
    END DO
  END SUBROUTINE cosserat_rod

  FUNCTION end_at(za, zb, f) RESULT(p)
    !! The point at fraction f between za and zb, moved onto the sphere of radius |zb|.
    REAL(wp), INTENT(IN) :: za(3), zb(3), f
    REAL(wp) :: p(3)
    p = za + f*(zb - za)
    p = p*NORM2(zb)/NORM2(p)
  END FUNCTION end_at

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_bordered_term()
    !! The rank-one term of the bordered Newton step on post-buckled states. A weightless rod
    !! (EI = L = 1, GJ = 2.5 EI, the ratio of the lazy-wave reference cable, EA = 1e4, 16
    !! elements), clamped along +x at both ends, node 1 held and End B sliding along x under the
    !! dead tension T L^2/EI = 10 with its lateral position held at y = 0.002 L (a small
    !! imperfection that removes the rotation symmetry about the clamp axis). The production
    !! static solve takes it to M = 1.05 and 1.20 M_cr (M_cr = 10.4289 EI/L, eq. (33)), where it
    !! buckles out of plane and the torque relaxes. At each state, with B = sum K_e -
    !! M_t d2Theta/dq2 and g = dTheta/dq on the free DOFs, rho = g^T B^-1 g / C is the error
    !! amplification of a Newton iteration that drops g g^T / C (its error is multiplied by
    !! -rho along B^-1 g): such an iteration converges only linearly, at the rate rho. From a
    !! 1e-6 perturbation of every free DOF, the test's own Newton iteration (both end nodes held
    !! at the solution) runs (a) with the bordered tangent through
    !! CD_HermiteTorsion_Bordered_Solve: quadratic convergence back to the production state, and
    !! (b) with B alone: linear convergence at the predicted rate rho.
    REAL(wp), PARAMETER :: MCR = 10.42885644_wp, OFS = 2.0e-3_wp, GJ = 2.5_wp, FRACS(2) = [1.05_wp, 1.20_wp]
    INTEGER, PARAMETER :: NE = 16, ND = 6*(NE + 1), MAXIT = 30
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: seed(ND), qs(ND), l0(NE), curv(NE + 1), res, ends(3, 4), q0(ND), hist(MAXIT, 2), sk, fdead(ND)
    REAL(wp) :: g(ND), z(ND), e, th, mt, qfin(ND), dfin, rho, amp, rate
    REAL(wp), ALLOCATABLE :: ab(:, :), abc(:, :)   ! band matrices on the heap, not the stack
    INTEGER :: k, it, es, ic, nit(2), nneg_b, nneg_k, info, ipiv(ND), nr
    LOGICAL :: conv(2), ok, mask(ND)
    CHARACTER(512) :: em
    EXTERNAL :: dgbsv
    ALLOCATE (ab(LDAB, ND), abc(LDAB, ND))
    l0 = 1.0_wp/NE
    fdead = 0.0_wp
    fdead(ND - 5) = 10.0_wp
    ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                    0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    DO ic = 1, 2
      DO k = 0, NE
        sk = REAL(k, wp)/NE
        seed(6*k + 1:6*k + 6) = [1.001_wp*sk, OFS*(3.0_wp*sk**2 - 2.0_wp*sk**3), 0.0_wp, &
                                 1.001_wp, 6.0_wp*OFS*sk*(1.0_wp - sk), 0.0_wp]
      END DO
      tors = CD_HermiteTorsionType()
      tors%active = .TRUE.
      ALLOCATE (tors%gj(NE))
      tors%gj = GJ
      tors%ends = ends
      tors%phi = FRACS(ic)*MCR/GJ
      CALL CD_HermiteCable_Static_Solve(l0, [(1.0e4_wp, it=1, NE)], [(1.0_wp, it=1, NE)], [(0.0_wp, it=1, NE)], &
                                        seed, [1, 2, 3, ND - 4, ND - 3], -1.0e6_wp, 0.0_wp, 1, 100, &
                                        1.0e-9_wp, 1.0_wp, qs, curv, res, it, es, em, f_nodal=fdead, &
                                        endconn_stiffness=[0.0_wp, 0.0_wp], &
                                        endconn_direction=RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                  [3, 2]), &
                                        endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=tors)
      CALL require(es == CD_HCSTAT_OK .AND. tors%stable, 'S: the production solve reaches a stable twisted state: '// &
                   TRIM(em))
      IF (es /= CD_HCSTAT_OK) CYCLE
      ! inertia of B and of K = B + g g^T / C at the solution (free DOFs), and rho
      CALL line_energy(qs, l0, 1.0e4_wp, 1.0_wp, ends, 1.0_wp/GJ, tors%phi, tors%theta, e, th, mt, ok, ab=ab, g=g)
      mask = .TRUE.
      mask(1:6) = .FALSE.
      mask(ND - 5:ND) = .FALSE.
      CALL CD_HermiteTorsion_Inertia(ab, KB, KB, mask, g, 1.0_wp/GJ, nneg_b, nneg_k, es, em)
      CALL require(es == CD_HTORS_OK, 'S: inertia count: '//TRIM(em))
      abc = ab
      z = g
      CALL dgbsv(ND, KB, KB, 1, abc, LDAB, ipiv, z, ND, info)
      rho = DOT_PRODUCT(g, z)*GJ
      IF (info /= 0) rho = HUGE(1.0_wp)
      ! the perturbed start and the two iterations
      q0 = qs
      DO k = 7, ND - 6
        q0(k) = qs(k) + 1.0e-6_wp*SIN(1.7_wp*k)
      END DO
      CALL newton(q0, l0, ends, tors%phi, tors%theta, GJ, .TRUE., nit(1), hist(:, 1), conv(1), qfin)
      dfin = nan_max_abs(qfin - qs)
      CALL newton(q0, l0, ends, tors%phi, tors%theta, GJ, .FALSE., nit(2), hist(:, 2), conv(2), qfin)
      ! observed linear rate of (b): geometric mean of the residual ratios after the first two
      ! iterations, above the round-off floor
      rate = 0.0_wp
      nr = 0
      DO k = 3, MIN(nit(2), MAXIT - 1)
        IF (hist(k + 1, 2) <= 1.0e-9_wp) EXIT
        rate = rate + LOG(hist(k + 1, 2)/hist(k, 2))
        nr = nr + 1
      END DO
      IF (nr > 0) rate = EXP(rate/nr)
      amp = nan_max_abs(qs(3::6))
      WRITE (*, '(A,F5.2,A,F9.5,A,ES10.3,A,I0,A,I0)') 'bordered step at M/M_cr = ', FRACS(ic), ': M_t L/EI ', &
        tors%torque, ', out-of-plane amplitude/L ', amp, '; negative eigenvalues of B ', nneg_b, ', of B + g g^T/C ', &
        nneg_k
      WRITE (*, '(A,I0,A,6ES9.1)') '  bordered tangent: ', nit(1), ' iterations, |R|: ', hist(1:MIN(6, nit(1) + 1), 1)
      WRITE (*, '(A,I0,A,6ES9.1)') '  B alone:          ', nit(2), ' iterations, |R|: ', hist(1:6, 2)
      WRITE (*, '(A,ES10.3,A,ES10.3)') '  rho = g^T B^-1 g / C = ', rho, ', observed rate without g g^T/C ', rate
      CALL require(conv(1) .AND. nit(1) <= 4, 'S: the bordered Newton step converges within 4 iterations')
      CALL require(dfin <= 1.0e-8_wp, 'S: and returns to the production solution')
      CALL require(rho >= 0.05_wp, 'S: the rank-one term carries weight on the buckled branch (rho >= 0.05)')
      CALL require(conv(2) .AND. nit(2) >= nit(1) + 2, 'S: without the rank-one term the iteration slows down')
      CALL require(nr >= 1 .AND. ABS(rate/rho - 1.0_wp) <= 0.25_wp, &
                   'S: without the rank-one term it converges linearly at the predicted rate rho (25 %)')
      CALL require(nneg_b == 0 .AND. nneg_k == 0, 'S: both tangents positive definite at this stable state')
    END DO
  END SUBROUTINE check_bordered_term

  SUBROUTINE newton(qstart, l0, ends, phi, theta0, gjn, bordered, niter, rh, converged, qout)
    !! Newton iteration of the S gate (EA 1e4, EI = GJ = 1, both end nodes held), with the
    !! bordered tangent (CD_HermiteTorsion_Bordered_Solve) or with its band part B alone.
    REAL(wp), INTENT(IN) :: qstart(:), l0(:), ends(3, 4), phi, theta0, gjn
    LOGICAL, INTENT(IN) :: bordered
    INTEGER, INTENT(OUT) :: niter
    REAL(wp), INTENT(OUT) :: rh(:), qout(:)
    LOGICAL, INTENT(OUT) :: converged
    REAL(wp), ALLOCATABLE :: qn(:), r(:), abn(:, :), gn(:), dq(:)
    REAL(wp) :: en, thn, mtn, thref
    INTEGER :: iter, info, nd, maxit, es
    INTEGER, ALLOCATABLE :: ipiv(:)
    LOGICAL :: okn
    CHARACTER(256) :: em
    EXTERNAL :: dgbsv
    nd = SIZE(qstart)
    maxit = SIZE(rh)
    ALLOCATE (qn(nd), r(nd), abn(LDAB, nd), gn(nd), dq(nd), ipiv(nd))
    qn = qstart
    rh = 0.0_wp
    converged = .FALSE.
    thref = theta0
    niter = maxit
    DO iter = 0, maxit - 1
      CALL line_energy(qn, l0, 1.0e4_wp, 1.0_wp, ends, SUM(l0)/gjn, phi, thref, en, thn, mtn, okn, r=r, ab=abn, g=gn)
      IF (.NOT. okn) EXIT
      thref = thn
      rh(iter + 1) = nan_max_abs(r)
      IF (.NOT. (rh(iter + 1) < 1.0e3_wp)) EXIT
      IF (rh(iter + 1) <= 1.0e-10_wp) THEN
        converged = .TRUE.
        niter = iter
        EXIT
      END IF
      IF (bordered) THEN
        CALL CD_HermiteTorsion_Bordered_Solve(abn, KB, KB, gn, SUM(l0)/gjn, -r, dq, es, em)
        IF (es /= CD_HTORS_OK) EXIT
      ELSE
        dq = -r
        CALL dgbsv(nd, KB, KB, 1, abn, LDAB, ipiv, dq, nd, info)
        IF (info /= 0) EXIT
      END IF
      qn = qn + dq
    END DO
    qout = qn
  END SUBROUTINE newton

END PROGRAM test_torsion_validation
