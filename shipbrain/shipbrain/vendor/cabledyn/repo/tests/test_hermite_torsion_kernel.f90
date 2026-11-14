! File: tests/test_hermite_torsion_kernel.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_torsion_kernel
  !! Gates for the parallel-transport twist kernel of the Hermite cable (CableDyn_HermiteTorsion):
  !!   O  Theta, dTheta/d[q, w_A, w_B] and every second derivative against automatic-
  !!      differentiation reference values (tests/data/torsion_oracle_reference.txt) on random
  !!      large-deformation lines with clamped and articulated ends,
  !!   F  gradient and Hessian against central finite differences, including the end rotations,
  !!   B  the DOF Hessian has half-bandwidth exactly 11, in DGBSV storage, and accumulates with
  !!      band_scale,
  !!   R  invariance under a rigid rotation of the line and both end frames,
  !!   P  Theta = 0 for planar curves (also a 1.5-turn circle),
  !!   H  helix with Frenet end normals: Theta = -tau * length,
  !!   U  2 pi unwrapping through more than three turns, and the pi/2 step limit,
  !!   G  fold guard (element and articulated end) and fail-closed input checks,
  !!   E  the element routine against finite differences and against the line assembly,
  !!   W  the allocation-free workspace evaluation (bit-identical, kept Hessian, size checks),
  !!   L  the bordered solve on its direct, shifted and dense paths and its named failure, the
  !!      inertia count's input checks and unreliable count, and the compliance of a bad input.
  !! Argument 1: path of the reference data file.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsion_Element, CD_HermiteTorsion_Line, CD_HermiteTorsion_Fold_Check, &
                                     CD_HermiteTorsion_Unwrap, CD_HermiteTorsion_Accept, CD_HTORS_OK, &
                                     CD_HTORS_BADINPUT, CD_HTORS_FOLD, CD_HTORS_NONFINITE, CD_HTORS_STEP, &
                                     CD_HTORS_KBAND, CD_HTORS_PI, CD_HermiteTorsionWorkType, &
                                     CD_HermiteTorsion_Work_Init, CD_HermiteTorsion_Work_End, &
                                     CD_HermiteTorsion_Work_Add_Hessian, CD_HermiteTorsion_Bordered_Solve, &
                                     CD_HermiteTorsion_Inertia, CD_HermiteTorsion_Compliance, CD_HermiteTorsionType, &
                                     CD_HTORS_ILLCOND, CD_HTORS_UNRELIABLE, CD_HTORS_DENSE_MAX
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_NAN, IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE

  INTEGER, PARAMETER :: KB = CD_HTORS_KBAND, LDAB = 3*KB + 1
  REAL(wp), PARAMETER :: TWO_PI = 2.0_wp*CD_HTORS_PI
  INTEGER :: nfail
  CHARACTER(512) :: ref_path

  nfail = 0
  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'usage: test_hermite_torsion_kernel <torsion_oracle_reference.txt>'
    ERROR STOP 2
  END IF
  CALL GET_COMMAND_ARGUMENT(1, ref_path)

  CALL check_oracle_reference()
  CALL check_finite_differences()
  CALL check_band_layout()
  CALL check_workspace()
  CALL check_rigid_rotation()
  CALL check_planar()
  CALL check_helix_and_unwrap()
  CALL check_accept_rule()
  CALL check_fold_and_inputs()
  CALL check_element_routine()
  CALL check_linear_algebra()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Hermite torsion kernel matches the reference and analytic cases'

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

  REAL(wp) FUNCTION wrap(x)
    REAL(wp), INTENT(IN) :: x
    wrap = x - TWO_PI*ANINT(x/TWO_PI)
  END FUNCTION wrap

  ! ---------------------------------------------------------------------------------------
  ! geometry helpers
  ! ---------------------------------------------------------------------------------------

  FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  FUNCTION rotate(w, v) RESULT(r)
    !! exp(w) v (Rodrigues).
    REAL(wp), INTENT(IN) :: w(3), v(3)
    REAL(wp) :: r(3), th, k(3)
    th = NORM2(w)
    IF (th < 1.0e-300_wp) THEN
      r = v
      RETURN
    END IF
    k = w/th
    r = v*COS(th) + cross(k, v)*SIN(th) + k*DOT_PRODUCT(k, v)*(1.0_wp - COS(th))
  END FUNCTION rotate

  SUBROUTINE random_line(nel, seed, q, le)
    !! Smooth random 3D line (several radians of tangent turning) with random nodal stretch.
    INTEGER, INTENT(IN) :: nel, seed
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q(:), le(:)
    REAL(wp) :: ca(3, 3), cb(3, 3), s, w, stretch, total
    INTEGER :: k, md, i
    total = 6.0_wp
    ALLOCATE (q(6*(nel + 1)), le(nel))
    DO md = 1, 3
      DO i = 1, 3
        ca(i, md) = 0.9_wp*SIN(1.7_wp*i + 2.3_wp*md + 0.37_wp*seed)/md
        cb(i, md) = 0.9_wp*COS(0.6_wp*i - 1.1_wp*md + 0.53_wp*seed)/md
      END DO
    END DO
    DO k = 0, nel
      s = total*k/nel
      q(6*k + 1:6*k + 6) = 0.0_wp
      q(6*k + 1) = s
      q(6*k + 4) = 1.0_wp
      DO md = 1, 3
        w = CD_HTORS_PI*md/total
        q(6*k + 1:6*k + 3) = q(6*k + 1:6*k + 3) + (ca(:, md)*SIN(w*s) + cb(:, md)*(COS(w*s) - 1.0_wp))*total/CD_HTORS_PI
        q(6*k + 4:6*k + 6) = q(6*k + 4:6*k + 6) + (ca(:, md)*w*COS(w*s) - cb(:, md)*w*SIN(w*s))*total/CD_HTORS_PI
      END DO
      stretch = 1.0_wp + 0.08_wp*SIN(3.1_wp*k + seed)
      q(6*k + 4:6*k + 6) = stretch*q(6*k + 4:6*k + 6)
    END DO
    le = total/nel
  END SUBROUTINE random_line

  FUNCTION clamped_ends(q) RESULT(ends)
    REAL(wp), INTENT(IN) :: q(:)
    REAL(wp) :: ends(3, 4), ta(3), tb(3), sd(3)
    INTEGER :: n
    n = SIZE(q)
    ta = q(4:6)/NORM2(q(4:6))
    tb = q(n - 2:n)/NORM2(q(n - 2:n))
    sd = [0.0_wp, 0.0_wp, 1.0_wp]
    IF (ABS(ta(3)) > 0.9_wp) sd = [0.0_wp, 1.0_wp, 0.0_wp]
    ends(:, 1) = ta
    ends(:, 2) = (sd - DOT_PRODUCT(sd, ta)*ta)/NORM2(sd - DOT_PRODUCT(sd, ta)*ta)
    ends(:, 3) = tb
    ends(:, 4) = (ends(:, 2) - DOT_PRODUCT(ends(:, 2), tb)*tb)/NORM2(ends(:, 2) - DOT_PRODUCT(ends(:, 2), tb)*tb)
  END FUNCTION clamped_ends

  FUNCTION articulated_ends(q) RESULT(ends)
    !! End directors 30-40 degrees off the end tangents, normals perpendicular to them.
    REAL(wp), INTENT(IN) :: q(:)
    REAL(wp) :: ends(3, 4)
    ends = clamped_ends(q)
    ends(:, 1:2) = RESHAPE([rotate([0.3_wp, -0.4_wp, 0.2_wp], ends(:, 1)), &
                            rotate([0.3_wp, -0.4_wp, 0.2_wp], ends(:, 2))], [3, 2])
    ends(:, 3:4) = RESHAPE([rotate([-0.5_wp, 0.1_wp, 0.35_wp], ends(:, 3)), &
                            rotate([-0.5_wp, 0.1_wp, 0.35_wp], ends(:, 4))], [3, 2])
  END FUNCTION articulated_ends

  FUNCTION rotated_ends(ends, wa, wb) RESULT(r)
    REAL(wp), INTENT(IN) :: ends(3, 4), wa(3), wb(3)
    REAL(wp) :: r(3, 4)
    r(:, 1) = rotate(wa, ends(:, 1))
    r(:, 2) = rotate(wa, ends(:, 2))
    r(:, 3) = rotate(wb, ends(:, 3))
    r(:, 4) = rotate(wb, ends(:, 4))
  END FUNCTION rotated_ends

  SUBROUTINE evaluate(q, le, ends, th, g, hb, eg, eh, ec, es)
    REAL(wp), INTENT(IN) :: q(:), le(:), ends(3, 4)
    REAL(wp), INTENT(OUT) :: th, g(:), hb(:, :), eg(6), eh(3, 3, 2), ec(3, 3, 2)
    INTEGER, INTENT(OUT) :: es
    CHARACTER(200) :: em
    hb = 0.0_wp
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em, hband=hb, end_grad=eg, end_hess=eh, end_cross=ec)
    IF (es /= CD_HTORS_OK) WRITE (*, '(A)') '  kernel: '//TRIM(em)
  END SUBROUTINE evaluate

  REAL(wp) FUNCTION theta_of(q, le, ends) RESULT(th)
    REAL(wp), INTENT(IN) :: q(:), le(:), ends(3, 4)
    REAL(wp), ALLOCATABLE :: g(:)
    INTEGER :: es
    CHARACTER(200) :: em
    ALLOCATE (g(SIZE(q)))
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em)
    IF (es /= CD_HTORS_OK) th = HUGE(1.0_wp)
  END FUNCTION theta_of

  FUNCTION band_to_dense(hb, n) RESULT(h)
    REAL(wp), INTENT(IN) :: hb(:, :)
    INTEGER, INTENT(IN) :: n
    REAL(wp) :: h(n, n)
    INTEGER :: i, j
    h = 0.0_wp
    DO j = 1, n
      DO i = MAX(1, j - KB), MIN(n, j + KB)
        h(i, j) = hb(SIZE(hb, 1) - KB + i - j, j)
      END DO
    END DO
  END FUNCTION band_to_dense

  ! ---------------------------------------------------------------------------------------
  ! O: automatic-differentiation reference
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE check_oracle_reference()
    INTEGER :: unit, ios, ncase, ic, nn, ng, n, i, j, es, nb
    CHARACTER(256) :: line, name
    REAL(wp), ALLOCATABLE :: le(:), q(:), g_ref(:), band_ref(:), g(:), hb(:, :), h(:, :)
    REAL(wp) :: ends(3, 4), th_ref, th, eg(6), eh(3, 3, 2), ec(3, 3, 2), blocks(9, 4), href(3, 3, 4)
    REAL(wp) :: err_g, err_h, err_e, scale_h

    OPEN (NEWUNIT=unit, FILE=TRIM(ref_path), STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'O: open reference data '//TRIM(ref_path))
    IF (ios /= 0) RETURN
    DO
      READ (unit, '(A)') line
      IF (line(1:1) /= '#') EXIT
    END DO
    READ (line, *) ncase
    CALL require(ncase == 4, 'O: four reference cases')
    DO ic = 1, ncase
      READ (unit, '(A)') name
      READ (unit, *) nn, ng
      n = 6*nn
      ALLOCATE (le(nn - 1), q(n), g_ref(n + 6), g(n), hb(LDAB, n))
      nb = 0
      DO j = 1, n
        nb = nb + MIN(n, j + KB) - j + 1
      END DO
      ALLOCATE (band_ref(nb))
      READ (unit, *) le, q, ends, th_ref, g_ref, band_ref, blocks
      CALL evaluate(q, le, ends, th, g, hb, eg, eh, ec, es)
      CALL require(es == CD_HTORS_OK .AND. ng == 4, 'O: evaluate '//TRIM(name))
      h = band_to_dense(hb, n)
      err_h = 0.0_wp
      scale_h = MAXVAL(ABS(band_ref))
      nb = 0
      DO j = 1, n
        DO i = j, MIN(n, j + KB)
          nb = nb + 1
          err_h = nan_max_abs([err_h, ABS(h(i, j) - band_ref(nb)), ABS(h(j, i) - band_ref(nb))])
        END DO
      END DO
      err_h = err_h/scale_h
      err_g = nan_max_abs([g, eg] - g_ref)/MAXVAL(ABS(g_ref))
      href = RESHAPE(blocks, [3, 3, 4])
      err_e = MAX(nan_max_abs(eh(:, :, 1) - href(:, :, 1)), nan_max_abs(eh(:, :, 2) - href(:, :, 2)), &
                  nan_max_abs(ec(:, :, 1) - href(:, :, 3)), nan_max_abs(ec(:, :, 2) - href(:, :, 4)))/scale_h
      WRITE (*, '(A,A,ES9.2,A,ES9.2,A,ES9.2,A,ES9.2)') '  O ', TRIM(name)//': Theta err ', &
        ABS(wrap(th - th_ref)), ', grad rel ', err_g, ', Hessian rel ', err_h, ', end blocks rel ', err_e
      CALL require(ABS(wrap(th - th_ref)) <= 1.0e-12_wp*MAX(1.0_wp, ABS(th_ref)), 'O: Theta '//TRIM(name))
      CALL require(err_g <= 1.0e-12_wp, 'O: gradient '//TRIM(name))
      CALL require(err_h <= 1.0e-12_wp, 'O: DOF Hessian '//TRIM(name))
      CALL require(err_e <= 1.0e-12_wp, 'O: end-rotation Hessian blocks '//TRIM(name))
      DEALLOCATE (le, q, g_ref, g, hb, band_ref, h)
    END DO
    CLOSE (unit)
  END SUBROUTINE check_oracle_reference

  ! ---------------------------------------------------------------------------------------
  ! F: finite differences (independent of the reference data)
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE check_finite_differences()
    REAL(wp), ALLOCATABLE :: q(:), le(:), g(:), hb(:, :), h(:, :), gp(:), gm(:), hfd(:, :), dq(:)
    REAL(wp) :: ends(3, 4), th, eg(6), eh(3, 3, 2), ec(3, 3, 2), egfd(6), ehfd(3, 3, 2), ecfd(3, 3, 2)
    REAL(wp) :: tp, tm, step, wa(3), wb(3), w6(6), e_i(3), e_j(3), t4(4), dum
    REAL(wp) :: hbx(LDAB, 1), egx(6), ehx(3, 3, 2), ecx(3, 3, 2)
    INTEGER :: n, i, j, k, es, iend
    CHARACTER(16) :: tag
    CHARACTER(200) :: em

    DO iend = 1, 2
      CALL random_line(10, 3 + iend, q, le)
      IF (iend == 1) THEN
        ends = clamped_ends(q)
        tag = 'clamped'
      ELSE
        ends = articulated_ends(q)
        tag = 'articulated'
      END IF
      n = SIZE(q)
      ALLOCATE (g(n), hb(LDAB, n), gp(n), gm(n), hfd(n, n), dq(n))
      CALL evaluate(q, le, ends, th, g, hb, eg, eh, ec, es)
      CALL require(es == CD_HTORS_OK, 'F: evaluate '//TRIM(tag))
      h = band_to_dense(hb, n)
      step = 1.0e-6_wp
      DO i = 1, n
        dq = 0.0_wp
        dq(i) = step
        tp = theta_of(q + dq, le, ends)
        tm = theta_of(q - dq, le, ends)
        gp(i) = wrap(tp - tm)/(2.0_wp*step)
      END DO
      CALL require(nan_max_abs(gp - g) <= 1.0e-7_wp*MAXVAL(ABS(g)), 'F: gradient vs FD '//TRIM(tag))
      step = 1.0e-6_wp
      DO i = 1, n
        dq = 0.0_wp
        dq(i) = step
        CALL CD_HermiteTorsion_Line(q + dq, le, ends, dum, gp, es, em)
        CALL CD_HermiteTorsion_Line(q - dq, le, ends, dum, gm, es, em)
        hfd(:, i) = (gp - gm)/(2.0_wp*step)
      END DO
      WRITE (*, '(A,ES9.2)') '  F '//TRIM(tag)//': Hessian vs FD rel ', nan_max_abs(hfd - h)/MAXVAL(ABS(h))
      CALL require(nan_max_abs(hfd - h) <= 1.0e-6_wp*MAXVAL(ABS(h)), 'F: Hessian vs FD '//TRIM(tag))
      ! B: half-bandwidth exactly 11 -- nothing outside the band, something on its edge
      dum = 0.0_wp
      tp = 0.0_wp
      DO j = 1, n
        DO i = 1, n
          IF (ABS(i - j) > KB) dum = nan_max_abs([dum, ABS(hfd(i, j))])
          IF (ABS(i - j) == KB) tp = nan_max_abs([tp, ABS(h(i, j))])
        END DO
      END DO
      CALL require(dum <= 1.0e-7_wp*MAXVAL(ABS(h)), 'B: FD Hessian vanishes outside the band '//TRIM(tag))
      CALL require(tp >= 1.0e-3_wp*MAXVAL(ABS(h)), 'B: Hessian reaches the band edge 11 '//TRIM(tag))

      ! end rotations: gradient and Hessians by differences of exp(w)-rotated end frames
      step = 1.0e-6_wp
      DO k = 1, 6
        w6 = 0.0_wp
        w6(k) = step
        wa = w6(1:3)
        wb = w6(4:6)
        tp = theta_of(q, le, rotated_ends(ends, wa, wb))
        tm = theta_of(q, le, rotated_ends(ends, -wa, -wb))
        egfd(k) = wrap(tp - tm)/(2.0_wp*step)
        CALL CD_HermiteTorsion_Line(q, le, rotated_ends(ends, wa, wb), dum, gp, es, em)
        CALL CD_HermiteTorsion_Line(q, le, rotated_ends(ends, -wa, -wb), dum, gm, es, em)
        IF (k <= 3) ecfd(k, :, 1) = (gp(4:6) - gm(4:6))/(2.0_wp*step)
        IF (k > 3) ecfd(k - 3, :, 2) = (gp(n - 2:n) - gm(n - 2:n))/(2.0_wp*step)
      END DO
      step = 1.0e-4_wp
      DO k = 1, 2
        DO j = 1, 3
          DO i = 1, 3
            e_i = 0.0_wp
            e_j = 0.0_wp
            e_i(i) = step
            e_j(j) = step
            IF (k == 1) THEN
              t4 = [theta_of(q, le, rotated_ends(ends, e_i + e_j, [0.0_wp, 0.0_wp, 0.0_wp])), &
                    theta_of(q, le, rotated_ends(ends, e_i - e_j, [0.0_wp, 0.0_wp, 0.0_wp])), &
                    theta_of(q, le, rotated_ends(ends, -e_i + e_j, [0.0_wp, 0.0_wp, 0.0_wp])), &
                    theta_of(q, le, rotated_ends(ends, -e_i - e_j, [0.0_wp, 0.0_wp, 0.0_wp]))]
            ELSE
              t4 = [theta_of(q, le, rotated_ends(ends, [0.0_wp, 0.0_wp, 0.0_wp], e_i + e_j)), &
                    theta_of(q, le, rotated_ends(ends, [0.0_wp, 0.0_wp, 0.0_wp], e_i - e_j)), &
                    theta_of(q, le, rotated_ends(ends, [0.0_wp, 0.0_wp, 0.0_wp], -e_i + e_j)), &
                    theta_of(q, le, rotated_ends(ends, [0.0_wp, 0.0_wp, 0.0_wp], -e_i - e_j))]
            END IF
            ehfd(i, j, k) = (wrap(t4(1) - t4(2)) - wrap(t4(3) - t4(4)))/(4.0_wp*step*step)
          END DO
        END DO
      END DO
      WRITE (*, '(A,3ES9.2)') '  F '//TRIM(tag)//': end grad / end Hessian / cross vs FD ', &
        nan_max_abs(egfd - eg), nan_max_abs(ehfd - eh), nan_max_abs(ecfd - ec)
      CALL require(nan_max_abs(egfd - eg) <= 1.0e-8_wp, 'F: end-rotation gradient '//TRIM(tag))
      CALL require(nan_max_abs(ehfd - eh) <= 1.0e-6_wp*MAX(1.0_wp, MAXVAL(ABS(eh))), &
                   'F: end-rotation Hessian '//TRIM(tag))
      CALL require(nan_max_abs(ecfd - ec) <= 1.0e-6_wp*MAX(1.0_wp, MAXVAL(ABS(ec))), &
                   'F: end-rotation / tangent cross Hessian '//TRIM(tag))
      ! a rotation of an end frame about its own director changes Theta by exactly that angle
      CALL require(ABS(DOT_PRODUCT(eg(1:3), ends(:, 1)) - 1.0_wp) <= 1.0e-12_wp .AND. &
                   ABS(DOT_PRODUCT(eg(4:6), ends(:, 3)) + 1.0_wp) <= 1.0e-12_wp, 'F: end roll enters with unit weight')
      DEALLOCATE (g, hb, gp, gm, hfd, dq, h)
    END DO
    ! the optional end outputs need no band
    CALL random_line(4, 1, q, le)
    ends = clamped_ends(q)
    ALLOCATE (g(SIZE(q)))
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em, end_grad=egx, end_hess=ehx, end_cross=ecx)
    CALL require(es == CD_HTORS_OK .AND. ALL(ABS(egx) < 1.0e3_wp), 'F: end outputs without band')
    hbx = 0.0_wp
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em, hband=hbx)
    CALL require(es == CD_HTORS_BADINPUT, 'F: undersized band rejected')
  END SUBROUTINE check_finite_differences

  ! ---------------------------------------------------------------------------------------
  ! B: band layout and accumulation
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE check_band_layout()
    REAL(wp), ALLOCATABLE :: q(:), le(:), g(:), h34(:, :), h23(:, :), hacc(:, :)
    REAL(wp) :: ends(3, 4), th
    INTEGER :: n, es
    CHARACTER(200) :: em
    CALL random_line(6, 2, q, le)
    ends = articulated_ends(q)
    n = SIZE(q)
    ALLOCATE (g(n), h34(LDAB, n), h23(2*KB + 1, n), hacc(LDAB, n))
    h34 = 0.0_wp
    h23 = 0.0_wp
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em, hband=h34)
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em, hband=h23)
    CALL require(nan_max_abs(band_to_dense(h34, n) - band_to_dense(h23, n)) <= 0.0_wp, &
                 'B: DGBSV and DGBMV layouts carry the same Hessian')
    CALL require(nan_max_abs(h34(1:KB, :)) <= 0.0_wp, 'B: DGBSV fill rows untouched')
    CALL require(nan_max_abs(band_to_dense(h34, n) - TRANSPOSE(band_to_dense(h34, n))) <= &
                 1.0e-14_wp*MAXVAL(ABS(h34)), 'B: Hessian symmetric')
    hacc = 1.0_wp
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em, hband=hacc, band_scale=-2.5_wp)
    CALL require(nan_max_abs(hacc - 1.0_wp + 2.5_wp*h34) <= 1.0e-13_wp*MAXVAL(ABS(h34)), &
                 'B: band_scale accumulates into the band')
  END SUBROUTINE check_band_layout

  ! ---------------------------------------------------------------------------------------
  ! W: workspace variant (no allocation in the evaluation)
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE check_workspace()
    !! The workspace evaluation returns bit-identical values to the allocating one; keep_hessian
    !! with CD_HermiteTorsion_Work_Add_Hessian equals hband with band_scale; a workspace sized for
    !! another line, or released, is refused by name.
    REAL(wp), ALLOCATABLE :: q(:), le(:), g1(:), g2(:), h1(:, :), h2(:, :)
    REAL(wp) :: ends(3, 4), th1, th2, eg1(6), eg2(6)
    TYPE(CD_HermiteTorsionWorkType) :: work
    INTEGER :: n, es, k
    CHARACTER(200) :: em
    CALL random_line(16, 2, q, le)
    n = SIZE(q)
    ALLOCATE (g1(n), g2(n), h1(LDAB, n), h2(LDAB, n))
    CALL CD_HermiteTorsion_Work_Init(work, n/6, es, em)
    CALL require(es == CD_HTORS_OK, 'W: workspace sized')
    DO k = 1, 2
      IF (k == 1) THEN
        ends = clamped_ends(q)
      ELSE
        ends = articulated_ends(q)
      END IF
      h1 = 0.0_wp
      h2 = 0.0_wp
      CALL CD_HermiteTorsion_Line(q, le, ends, th1, g1, es, em, hband=h1, band_scale=-3.0_wp, end_grad=eg1)
      CALL CD_HermiteTorsion_Line(q, le, ends, th2, g2, es, em, end_grad=eg2, work=work, keep_hessian=.TRUE.)
      CALL require(es == CD_HTORS_OK, 'W: workspace evaluation succeeds '//TRIM(em))
      CALL CD_HermiteTorsion_Work_Add_Hessian(work, h2, -3.0_wp, es, em)
      CALL require(es == CD_HTORS_OK, 'W: the kept Hessian is added '//TRIM(em))
      CALL require(.NOT. (ABS(th1 - th2) > 0.0_wp) .AND. nan_max_abs(g1 - g2) <= 0.0_wp .AND. &
                   nan_max_abs(eg1 - eg2) <= 0.0_wp, 'W: workspace Theta and gradients bit-identical')
      CALL require(nan_max_abs(h1 - h2) <= 0.0_wp, 'W: kept Hessian scaled later equals band_scale')
      h2 = 0.0_wp
      CALL CD_HermiteTorsion_Line(q, le, ends, th2, g2, es, em, hband=h2, band_scale=-3.0_wp, work=work)
      CALL require(nan_max_abs(h1 - h2) <= 0.0_wp, 'W: workspace hband path bit-identical')
      ! that call kept no Hessian: adding one now fails and leaves the band unchanged
      h1 = h2
      CALL CD_HermiteTorsion_Work_Add_Hessian(work, h2, 1.0_wp, es, em)
      CALL require(es == CD_HTORS_BADINPUT .AND. INDEX(em, 'no Hessian') > 0 .AND. nan_max_abs(h1 - h2) <= 0.0_wp, &
                   'W: adding a Hessian that was not kept is refused')
      CALL CD_HermiteTorsion_Line(q, le, ends, th2, g2, es, em, work=work, keep_hessian=.TRUE.)
      CALL CD_HermiteTorsion_Work_Add_Hessian(work, h2(:, 1:n - 6), 1.0_wp, es, em)
      CALL require(es == CD_HTORS_BADINPUT .AND. INDEX(em, 'does not match') > 0, &
                   'W: a band of another size is refused')
    END DO
    CALL CD_HermiteTorsion_Work_Init(work, n/6 + 1, es, em)
    CALL CD_HermiteTorsion_Line(q, le, ends, th2, g2, es, em, work=work)
    CALL require(es == CD_HTORS_BADINPUT .AND. INDEX(em, 'workspace is not sized') > 0 .AND. &
                 nan_max_abs(g2) <= 0.0_wp, 'W: a workspace of another size is refused')
    CALL CD_HermiteTorsion_Work_End(work)
    CALL CD_HermiteTorsion_Line(q, le, ends, th2, g2, es, em, work=work)
    CALL require(es == CD_HTORS_BADINPUT, 'W: a released workspace is refused')
    CALL CD_HermiteTorsion_Work_Init(work, 1, es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'W: a one-node workspace is refused')
  END SUBROUTINE check_workspace

  ! ---------------------------------------------------------------------------------------
  ! R: rigid rotation of everything
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE check_rigid_rotation()
    REAL(wp), ALLOCATABLE :: q(:), le(:), q2(:), g(:), g2(:), grot(:)
    REAL(wp) :: ends(3, 4), ends2(3, 4), th, th2, w(3), err_t, err_g, err_gen, eg(6), gen(3)
    INTEGER :: n, k, ir, iend, es
    CHARACTER(200) :: em
    err_t = 0.0_wp
    err_g = 0.0_wp
    err_gen = 0.0_wp
    DO iend = 1, 2
      CALL random_line(12, 7, q, le)
      ends = clamped_ends(q)
      IF (iend == 2) ends = articulated_ends(q)
      n = SIZE(q)
      ALLOCATE (q2(n), g(n), g2(n), grot(n))
      CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em, end_grad=eg)
      ! infinitesimal form: the rotation generator annihilates Theta,
      ! sum_k (r_k x dTheta/dr_k + m_k x dTheta/dm_k) + dTheta/dw_A + dTheta/dw_B = 0
      gen = eg(1:3) + eg(4:6)
      DO k = 0, n/3 - 1
        gen = gen + cross(q(3*k + 1:3*k + 3), g(3*k + 1:3*k + 3))
      END DO
      err_gen = nan_max_abs([err_gen, nan_max_abs(gen)/MAXVAL(ABS(g))])
      DO ir = 1, 5
        w = [0.7_wp*ir, -1.3_wp + 0.4_wp*ir, 2.1_wp - 0.9_wp*ir]
        DO k = 0, n/3 - 1
          q2(3*k + 1:3*k + 3) = rotate(w, q(3*k + 1:3*k + 3))
          grot(3*k + 1:3*k + 3) = rotate(w, g(3*k + 1:3*k + 3))
        END DO
        DO k = 1, 4
          ends2(:, k) = rotate(w, ends(:, k))
        END DO
        CALL CD_HermiteTorsion_Line(q2, le, ends2, th2, g2, es, em)
        err_t = nan_max_abs([err_t, ABS(wrap(th2 - th))])
        err_g = nan_max_abs([err_g, nan_max_abs(g2 - grot)/MAXVAL(ABS(g))])
      END DO
      DEALLOCATE (q2, g, g2, grot)
    END DO
    WRITE (*, '(A,3ES9.2)') '  R rigid rotation: max |dTheta|, gradient covariance rel, generator ', &
      err_t, err_g, err_gen
    CALL require(err_gen <= 1.0e-13_wp, 'R: rotation generator annihilates Theta (end gradients included)')
    CALL require(err_t <= 1.0e-13_wp, 'R: Theta invariant under rigid rotation')
    CALL require(err_g <= 1.0e-12_wp, 'R: gradient rotates with the line')
  END SUBROUTINE check_rigid_rotation

  ! ---------------------------------------------------------------------------------------
  ! P: planar curves
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE check_planar()
    REAL(wp), ALLOCATABLE :: q(:), le(:), g(:), hb(:, :)
    REAL(wp) :: ends(3, 4), th, s, rc, ez(3), eg(6), eh(3, 3, 2), ec(3, 3, 2)
    INTEGER :: k, n, es, nc
    CHARACTER(200) :: em
    ez = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL random_line(14, 5, q, le)
    n = SIZE(q)
    DO k = 0, n/6 - 1
      q(6*k + 3) = 0.0_wp
      q(6*k + 6) = 0.0_wp
    END DO
    ends(:, 1) = q(4:6)/NORM2(q(4:6))
    ends(:, 2) = ez
    ends(:, 3) = q(n - 2:n)/NORM2(q(n - 2:n))
    ends(:, 4) = ez
    ALLOCATE (g(n), hb(LDAB, n))
    CALL evaluate(q, le, ends, th, g, hb, eg, eh, ec, es)
    CALL require(es == CD_HTORS_OK .AND. ABS(th) <= 1.0e-14_wp, 'P: random planar curve has Theta = 0')
    ! out-of-plane gradient only: in-plane perturbations keep Theta = 0
    DO k = 0, n/6 - 1
      CALL require(ABS(g(6*k + 1)) + ABS(g(6*k + 2)) + ABS(g(6*k + 4)) + ABS(g(6*k + 5)) <= 1.0e-13_wp, &
                   'P: in-plane gradient vanishes')
    END DO
    DEALLOCATE (q, le, g, hb)
    ! 1.5-turn circle, 540 degrees of tangent turning
    rc = 2.0_wp
    nc = 36
    ALLOCATE (q(6*(nc + 1)), le(nc), g(6*(nc + 1)))
    DO k = 0, nc
      s = 3.0_wp*CD_HTORS_PI*rc*k/nc
      q(6*k + 1:6*k + 6) = [rc*SIN(s/rc), rc*(1.0_wp - COS(s/rc)), 0.0_wp, COS(s/rc), SIN(s/rc), 0.0_wp]
    END DO
    le = 3.0_wp*CD_HTORS_PI*rc/nc
    n = SIZE(q)
    ends(:, 1) = q(4:6)
    ends(:, 2) = ez
    ends(:, 3) = q(n - 2:n)
    ends(:, 4) = ez
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em)
    CALL require(es == CD_HTORS_OK .AND. ABS(th) <= 1.0e-14_wp, 'P: 1.5-turn circle has Theta = 0')
  END SUBROUTINE check_planar

  ! ---------------------------------------------------------------------------------------
  ! H, U: helix closed form and multi-turn unwrapping
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE helix(nel, ell, q, le, ends, expected)
    !! r = (R cos(s/k), R sin(s/k), c s/k), k = sqrt(R^2 + c^2); clamped with Frenet normals.
    INTEGER, INTENT(IN) :: nel
    REAL(wp), INTENT(IN) :: ell
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q(:), le(:)
    REAL(wp), INTENT(OUT) :: ends(3, 4), expected
    REAL(wp), PARAMETER :: rh = 1.0_wp, ch = 0.5_wp
    REAL(wp) :: kh, s
    INTEGER :: k
    kh = SQRT(rh*rh + ch*ch)
    ALLOCATE (q(6*(nel + 1)), le(nel))
    DO k = 0, nel
      s = ell*k/nel
      q(6*k + 1:6*k + 6) = [rh*COS(s/kh), rh*SIN(s/kh), ch*s/kh, -rh*SIN(s/kh)/kh, rh*COS(s/kh)/kh, ch/kh]
    END DO
    le = ell/nel
    ends(:, 1) = q(4:6)
    ends(:, 2) = [-1.0_wp, 0.0_wp, 0.0_wp]
    ends(:, 3) = q(6*nel + 4:6*nel + 6)
    ends(:, 4) = [-COS(ell/kh), -SIN(ell/kh), 0.0_wp]
    expected = -ch/(kh*kh)*ell
  END SUBROUTINE helix

  SUBROUTINE check_helix_and_unwrap()
    REAL(wp), ALLOCATABLE :: q(:), le(:), g(:)
    REAL(wp) :: ends(3, 4), expected, th, raw, raw_prev, prev, err, err8, ell
    INTEGER :: es, i, jumps, nsweep
    CHARACTER(200) :: em
    ! H: one turn of a helix, 12 and 48 elements (fourth-order quadrature convergence)
    CALL helix(12, 7.0_wp, q, le, ends, expected)
    ALLOCATE (g(SIZE(q)))
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em)
    err8 = ABS(wrap(th - expected))
    DEALLOCATE (q, le, g)
    CALL helix(48, 7.0_wp, q, le, ends, expected)
    ALLOCATE (g(SIZE(q)))
    CALL CD_HermiteTorsion_Line(q, le, ends, th, g, es, em)
    err = ABS(wrap(th - expected))
    DEALLOCATE (q, le, g)
    WRITE (*, '(A,2ES9.2)') '  H helix Theta = -tau l: error at 12 / 48 elements ', err8, err
    CALL require(es == CD_HTORS_OK .AND. err <= 2.0e-6_wp, 'H: helix Theta = -tau * length')
    CALL require(err8 > 16.0_wp*err, 'H: quadrature error converges at high order')

    ! U: sweep the helix length through more than three turns of Theta, one accepted step at a time
    nsweep = 400
    prev = 0.0_wp
    jumps = 0
    err = 0.0_wp
    DO i = 1, nsweep
      ell = 0.05_wp + (50.0_wp - 0.05_wp)*REAL(i - 1, wp)/(nsweep - 1)
      CALL helix(96, ell, q, le, ends, expected)
      ALLOCATE (g(SIZE(q)))
      CALL CD_HermiteTorsion_Line(q, le, ends, raw, g, es, em)
      IF (i == 1) THEN
        prev = raw
      ELSE
        IF (ABS(raw - raw_prev) > CD_HTORS_PI) jumps = jumps + 1
        CALL CD_HermiteTorsion_Accept(prev, raw, th, es, em)
        CALL require(es == CD_HTORS_OK, 'U: sweep step accepted')
        prev = th
      END IF
      raw_prev = raw
      err = nan_max_abs([err, ABS(prev - expected)])
      DEALLOCATE (q, le, g)
    END DO
    WRITE (*, '(A,F8.3,A,I0,A,ES9.2)') '  U unwrap: final Theta ', prev, ' rad, raw branch jumps ', jumps, &
      ', max error vs -tau l ', err
    CALL require(prev < -3.0_wp*CD_HTORS_PI, 'U: sweep passes more than 1.5 turns')
    CALL require(jumps >= 3, 'U: raw value wraps at least three times')
    CALL require(err <= 2.0e-3_wp, 'U: unwrapped Theta follows the multi-turn closed form')
  END SUBROUTINE check_helix_and_unwrap

  SUBROUTINE check_accept_rule()
    REAL(wp) :: th
    INTEGER :: es
    CHARACTER(200) :: em
    CALL require(ABS(CD_HermiteTorsion_Unwrap(3.1_wp, -3.1_wp) - (3.1_wp - TWO_PI)) <= 1.0e-15_wp, &
                 'U: nearest branch across +-pi')
    CALL require(ABS(CD_HermiteTorsion_Unwrap(0.2_wp, 25.0_wp) - (0.2_wp + 4.0_wp*TWO_PI)) <= 1.0e-13_wp, &
                 'U: nearest branch several turns away')
    CALL CD_HermiteTorsion_Accept(10.0_wp, 10.0_wp - TWO_PI + 1.4_wp, th, es, em)
    CALL require(es == CD_HTORS_OK .AND. ABS(th - 11.4_wp) <= 1.0e-13_wp, 'U: step below pi/2 accepted')
    CALL CD_HermiteTorsion_Accept(10.0_wp, 10.0_wp + 1.7_wp, th, es, em)
    CALL require(es == CD_HTORS_STEP .AND. ABS(th - 10.0_wp) <= 0.0_wp .AND. INDEX(em, 'step limit') > 0, &
                 'U: step above pi/2 rejected by name, previous value kept')
    CALL CD_HermiteTorsion_Accept(10.0_wp, 10.0_wp + 1.7_wp, th, es, em, max_step=2.0_wp)
    CALL require(es == CD_HTORS_OK, 'U: wider explicit step limit')
    CALL CD_HermiteTorsion_Accept(10.0_wp, 10.0_wp, th, es, em, max_step=4.0_wp)
    CALL require(es == CD_HTORS_BADINPUT, 'U: step limit at or above pi rejected')
    CALL CD_HermiteTorsion_Accept(10.0_wp, quiet_nan(), th, es, em)
    CALL require(es == CD_HTORS_NONFINITE .AND. ABS(th - 10.0_wp) <= 0.0_wp, 'U: non-finite trial rejected')
  END SUBROUTINE check_accept_rule

  REAL(wp) FUNCTION quiet_nan() RESULT(x)
    USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
    x = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
  END FUNCTION quiet_nan

  ! ---------------------------------------------------------------------------------------
  ! G: fold guard and input checks
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE arc_element(psi_deg, qe)
    !! One element of unit length turning by psi in the xy-plane, with a small z-lift.
    REAL(wp), INTENT(IN) :: psi_deg
    REAL(wp), INTENT(OUT) :: qe(12)
    REAL(wp) :: kap
    kap = psi_deg*CD_HTORS_PI/180.0_wp
    qe(1:6) = [0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp]
    qe(7:12) = [SIN(kap)/kap, (1.0_wp - COS(kap))/kap, 0.05_wp, COS(kap), SIN(kap), 0.1_wp]
  END SUBROUTINE arc_element

  SUBROUTINE check_fold_and_inputs()
    REAL(wp) :: qe(12), le(1), ends(3, 4), th, g(12), margin, hb(LDAB, 12), bad(12)
    INTEGER :: es
    CHARACTER(200) :: em
    CALL arc_element(100.0_wp, qe)
    le = 1.0_wp
    ends = clamped_ends(qe)
    CALL CD_HermiteTorsion_Fold_Check(qe, le, ends, margin, es, em)
    CALL require(es == CD_HTORS_OK .AND. margin > 0.5_wp .AND. margin < 1.0_wp, 'G: 100-degree element accepted')
    CALL arc_element(135.0_wp, qe)
    ends = clamped_ends(qe)
    hb = 7.0_wp
    CALL CD_HermiteTorsion_Line(qe, le, ends, th, g, es, em, hband=hb)
    CALL require(es == CD_HTORS_FOLD .AND. INDEX(em, '120 degrees inside element 1') > 0, &
                 'G: 135-degree element fails closed by name')
    CALL require(ALL(ABS(hb - 7.0_wp) <= 0.0_wp) .AND. ALL(ABS(g) <= 0.0_wp), 'G: failed call leaves outputs clean')
    ! articulated End A director 150 degrees from the first tangent
    CALL arc_element(40.0_wp, qe)
    ends = clamped_ends(qe)
    ends(:, 1) = [COS(2.618_wp), SIN(2.618_wp), 0.0_wp]
    ends(:, 2) = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL CD_HermiteTorsion_Fold_Check(qe, le, ends, margin, es, em)
    CALL require(es == CD_HTORS_FOLD .AND. INDEX(em, 'End-A director') > 0, 'G: folded articulated end by name')
    ! malformed input
    ends = clamped_ends(qe)
    ends(:, 2) = ends(:, 2) + 1.0e-3_wp*ends(:, 1)
    CALL CD_HermiteTorsion_Line(qe, le, ends, th, g, es, em)
    CALL require(es == CD_HTORS_BADINPUT .AND. INDEX(em, 'End-A') > 0, 'G: non-orthonormal end frame rejected')
    ends = clamped_ends(qe)
    bad = qe
    bad(5) = quiet_nan()
    CALL CD_HermiteTorsion_Line(bad, le, ends, th, g, es, em)
    CALL require(es == CD_HTORS_NONFINITE, 'G: NaN DOF rejected')
    bad = qe
    bad(10:12) = 0.0_wp
    CALL CD_HermiteTorsion_Line(bad, le, ends, th, g, es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'G: zero tangent handle rejected')
    CALL CD_HermiteTorsion_Line(qe(1:6), le(1:0), ends, th, g(1:6), es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'G: single-node line rejected')
    CALL CD_HermiteTorsion_Line(qe, -le, ends, th, g, es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'G: negative length rejected')
    CALL CD_HermiteTorsion_Line(qe, le, ends, th, g, es, em, quadrature_order=7)
    CALL require(es == CD_HTORS_BADINPUT, 'G: unsupported quadrature rejected')
    CALL CD_HermiteTorsion_Line(qe, le, ends, th, g(1:6), es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'G: gradient size checked')
    CALL CD_HermiteTorsion_Line(qe, le, ends, th, g, es, em, hband=hb, band_scale=quiet_nan())
    CALL require(es == CD_HTORS_NONFINITE, 'G: non-finite band scale rejected')
  END SUBROUTINE check_fold_and_inputs

  ! ---------------------------------------------------------------------------------------
  ! E: element routine
  ! ---------------------------------------------------------------------------------------

  SUBROUTINE check_element_routine()
    REAL(wp) :: qe(12), h, g(12), hk(12, 12), hp, hm, gp(12), gm(12), gfd(12), hfd(12, 12), dq(12), margin
    REAL(wp) :: ends(3, 4), th, gl(12), hb(LDAB, 12), le(1), eg(6), eh(3, 3, 2), ec(3, 3, 2), h6
    INTEGER :: es, i
    CHARACTER(200) :: em
    CALL arc_element(70.0_wp, qe)
    qe(4:6) = 1.07_wp*qe(4:6)
    qe(10:12) = 0.93_wp*qe(10:12) + [0.0_wp, 0.0_wp, 0.2_wp]
    CALL CD_HermiteTorsion_Element(qe, 1.3_wp, h, g, es, em, hess=hk, fold_margin=margin)
    CALL require(es == CD_HTORS_OK .AND. margin > 0.5_wp, 'E: element evaluates')
    DO i = 1, 12
      dq = 0.0_wp
      dq(i) = 1.0e-6_wp
      CALL CD_HermiteTorsion_Element(qe + dq, 1.3_wp, hp, gp, es, em)
      CALL CD_HermiteTorsion_Element(qe - dq, 1.3_wp, hm, gm, es, em)
      gfd(i) = (hp - hm)/2.0e-6_wp
      hfd(:, i) = (gp - gm)/2.0e-6_wp
    END DO
    CALL require(nan_max_abs(gfd - g) <= 1.0e-8_wp*MAXVAL(ABS(g)), 'E: element gradient vs FD')
    CALL require(nan_max_abs(hfd - hk) <= 1.0e-6_wp*MAXVAL(ABS(hk)), 'E: element Hessian vs FD')
    CALL require(nan_max_abs(hk - TRANSPOSE(hk)) <= 1.0e-14_wp*MAXVAL(ABS(hk)), 'E: element Hessian symmetric')
    ! the line of one element = element holonomy + chain terms; clamped ends make the end links trivial
    le = 1.3_wp
    ends = clamped_ends(qe)
    hb = 0.0_wp
    CALL evaluate(qe, le, ends, th, gl, hb, eg, eh, ec, es)
    CALL require(es == CD_HTORS_OK, 'E: one-element line evaluates')
    CALL require(nan_max_abs(gl(1:3) - g(1:3)) + nan_max_abs(gl(7:9) - g(7:9)) <= 1.0e-14_wp*MAXVAL(ABS(g)), &
                 'E: position gradient of the line is the element holonomy gradient')
    CALL require(nan_max_abs(band_to_dense(hb, 12) - hk) > 1.0e-6_wp*MAXVAL(ABS(hk)), &
                 'E: chain terms add to the tangent-handle block')
    ! sixth-order quadrature changes h_e only by the quadrature error (about 1e-3 for one coarse,
    ! 70-degree, distorted element)
    CALL CD_HermiteTorsion_Element(qe, 1.3_wp, h6, g, es, em, quadrature_order=6)
    WRITE (*, '(A,2ES12.4)') '  E element holonomy, 4- and 6-point quadrature ', h, h6
    CALL require(es == CD_HTORS_OK .AND. ABS(h6 - h) <= 5.0e-3_wp*ABS(h), &
                 'E: quadrature order 6 consistent')
    CALL CD_HermiteTorsion_Element(qe, 0.0_wp, h, g, es, em)
    CALL require(es == CD_HTORS_BADINPUT, 'E: zero length rejected')
    CALL CD_HermiteTorsion_Element(qe, 1.3_wp, h, g, es, em, quadrature_order=0)
    CALL require(es == CD_HTORS_BADINPUT, 'E: quadrature order 0 rejected')
    CALL arc_element(140.0_wp, qe)
    CALL CD_HermiteTorsion_Element(qe, 1.0_wp, h, g, es, em, fold_margin=margin)
    CALL require(es == CD_HTORS_FOLD .AND. margin < 0.5_wp, 'E: element fold reported with its margin')
  END SUBROUTINE check_element_routine

  ! ---------------------------------------------------------------------------------------
  SUBROUTINE check_linear_algebra()
    !! L  (B + g g^T / C) x = r on a 6x6 band (kl = ku = 2):
    !!    - B regular: the direct Sherman-Morrison step;
    !!    - B exactly singular, K regular: the shifted factorization with refinement;
    !!    - C = 1e-8 with B nearly singular (lambda ~ 1e-10): g^T B^-1 g / C ~ 1e18 defeats both
    !!      Sherman-Morrison paths although K is well conditioned, so the dense fallback solves it;
    !!    - that case in a line beyond CD_HTORS_DENSE_MAX DOFs: named CD_HTORS_ILLCOND with x = 0.
    !!    The inertia count refuses a non-square band and a NaN coupling vector, and reports a
    !!    vanishing pivot as unreliable; the compliance of a description without GJ is NaN.
    INTEGER, PARAMETER :: N = 6, KLB = 2, LD = 2*KLB + KLB + 1
    REAL(wp) :: dense(N, N), g(N), r(N), x(N), xt(N), ab(LD, N), be, err
    INTEGER :: es, i, nb, nk
    LOGICAL :: sh, dn, mask(N)
    CHARACTER(256) :: em
    TYPE(CD_HermiteTorsionType) :: tors
    g = [1.0_wp, 0.1_wp, 0.2_wp, -0.1_wp, 0.05_wp, 0.0_wp]
    r = [1.0_wp, -2.0_wp, 0.5_wp, 1.0_wp, 0.0_wp, 3.0_wp]
    ! direct path
    CALL la_case(1.0_wp, 0.5_wp, 1.0_wp, g, r, x, xt, es, em, be, sh, dn)
    err = nan_max_abs(x - xt)/MAXVAL(ABS(xt))
    CALL require(es == CD_HTORS_OK .AND. .NOT. sh .AND. .NOT. dn .AND. err <= 1.0e-13_wp, &
                 'L: direct bordered step '//TRIM(em))
    ! B exactly singular (first pivot zero), K regular: shifted path
    CALL la_case(0.0_wp, 0.0_wp, 1.0_wp, g, r, x, xt, es, em, be, sh, dn)
    err = nan_max_abs(x - xt)/MAXVAL(ABS(xt))
    CALL require(es == CD_HTORS_OK .AND. sh .AND. .NOT. dn .AND. err <= 1.0e-8_wp, &
                 'L: shifted bordered step for a singular B '//TRIM(em))
    ! g^T B^-1 g / C huge: dense fallback
    CALL la_case(1.0e-10_wp + 0.09_wp, 0.3_wp, 1.0e-8_wp, g, r, x, xt, es, em, be, sh, dn)
    err = nan_max_abs(x - xt)/MAXVAL(ABS(xt))
    WRITE (*, '(A,I0,A,L1,A,L1,A,ES10.3,A,ES10.3)') 'bordered solve, g^T B^-1 g / C ~ 1e18: status ', es, &
      ', shifted ', sh, ', dense ', dn, ', backward error ', be, ', error vs dense LU ', err
    CALL require(es == CD_HTORS_OK .AND. dn .AND. err <= 1.0e-6_wp .AND. be <= 1.0e-10_wp, &
                 'L: dense fallback when Sherman-Morrison fails')
    ! the same system embedded in a line too large for the dense fallback: named, x = 0
    BLOCK
      INTEGER, PARAMETER :: NL = CD_HTORS_DENSE_MAX + 2
      REAL(wp), ALLOCATABLE :: abl(:, :), gl(:), rl(:), xl(:)
      ALLOCATE (abl(LD, NL), gl(NL), rl(NL), xl(NL))
      abl = 0.0_wp
      abl(2*KLB + 1, :) = 1.0_wp
      abl(2*KLB + 1, 1) = 1.0e-10_wp + 0.09_wp
      abl(2*KLB, 2) = 0.3_wp
      abl(2*KLB + 2, 1) = 0.3_wp
      gl = 0.0_wp
      gl(1:N) = g
      rl = 0.0_wp
      rl(1:N) = r
      CALL CD_HermiteTorsion_Bordered_Solve(abl, KLB, KLB, gl, 1.0e-8_wp, rl, xl, es, em, backward_error=be, &
                                            shifted=sh, dense=dn)
      CALL require(es == CD_HTORS_ILLCOND .AND. INDEX(em, 'ill-conditioned') > 0 .AND. nan_max_abs(xl) <= 0.0_wp &
                   .AND. .NOT. dn, 'L: a failed bordered step beyond the dense size is named ill-conditioned, x = 0')
    END BLOCK
    ! a band with a zero pivot for the inertia checks: B = diag(0, 0, 1, 1, 1, 1)
    dense = 0.0_wp
    DO i = 3, N
      dense(i, i) = 1.0_wp
    END DO
    CALL la_band(dense, KLB, ab)
    g = 0.0_wp
    g(1) = 1.0_wp
    ! inertia input checks and the unreliable count
    mask = .TRUE.
    CALL CD_HermiteTorsion_Inertia(ab(2:, :), KLB - 1, KLB, mask, g, 1.0_wp, nb, nk, es, em)
    CALL require(es == CD_HTORS_BADINPUT .AND. INDEX(em, 'kl = ku') > 0, 'L: inertia refuses a non-square band')
    g(2) = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    CALL CD_HermiteTorsion_Inertia(ab, KLB, KLB, mask, g, 1.0_wp, nb, nk, es, em)
    CALL require(es == CD_HTORS_NONFINITE, 'L: inertia refuses a NaN coupling vector')
    g(2) = 0.0_wp
    CALL CD_HermiteTorsion_Inertia(ab, KLB, KLB, mask, g, 1.0_wp, nb, nk, es, em)
    CALL require(es == CD_HTORS_UNRELIABLE, 'L: a vanishing pivot makes the count unreliable')
    ! compliance without GJ
    CALL require(IEEE_IS_NAN(CD_HermiteTorsion_Compliance(tors, [1.0_wp, 1.0_wp])), &
                 'L: the compliance of a description without GJ is NaN')
    ALLOCATE (tors%gj(3))
    tors%gj = 1.0_wp
    CALL require(IEEE_IS_NAN(CD_HermiteTorsion_Compliance(tors, [1.0_wp, 1.0_wp])), &
                 'L: the compliance with a GJ count that does not match the mesh is NaN')
    tors%end_compliance = [0.5_wp, 0.25_wp]
    CALL require(ABS(CD_HermiteTorsion_Compliance(tors, [1.0_wp, 2.0_wp, 3.0_wp]) - 6.75_wp) <= 1.0e-15_wp, &
                 'L: compliance = sum L/GJ + end compliances')
  END SUBROUTINE check_linear_algebra

  SUBROUTINE la_band(dense, kl, ab)
    !! General band storage (DGBSV, kl = ku) of a dense square matrix.
    REAL(wp), INTENT(IN) :: dense(:, :)
    INTEGER, INTENT(IN) :: kl
    REAL(wp), INTENT(OUT) :: ab(:, :)
    INTEGER :: i, j, n
    n = SIZE(dense, 2)
    ab = 0.0_wp
    DO j = 1, n
      DO i = MAX(1, j - kl), MIN(n, j + kl)
        ab(2*kl + 1 + i - j, j) = dense(i, j)
      END DO
    END DO
  END SUBROUTINE la_band

  SUBROUTINE la_case(b11, b12, cc, g, r, x, xt, es, em, be, sh, dn)
    !! B = identity with the leading 2x2 block [b11 b12; b12 1]: the bordered solve of
    !! (B + g g^T / cc) x = r, and the reference xt from a dense LU of the same K.
    REAL(wp), INTENT(IN) :: b11, b12, cc, g(:), r(:)
    REAL(wp), INTENT(OUT) :: x(:), xt(:), be
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    LOGICAL, INTENT(OUT) :: sh, dn
    INTEGER, PARAMETER :: KL2 = 2
    REAL(wp) :: dense(SIZE(g), SIZE(g)), kk(SIZE(g), SIZE(g)), ab(3*KL2 + 1, SIZE(g))
    INTEGER :: i, n, info, ipiv(SIZE(g))
    EXTERNAL :: dgesv
    n = SIZE(g)
    dense = 0.0_wp
    DO i = 1, n
      dense(i, i) = 1.0_wp
    END DO
    dense(1, 1) = b11
    dense(1, 2) = b12
    dense(2, 1) = b12
    CALL la_band(dense, KL2, ab)
    CALL CD_HermiteTorsion_Bordered_Solve(ab, KL2, KL2, g, cc, r, x, es, em, backward_error=be, shifted=sh, &
                                          dense=dn)
    kk = dense + SPREAD(g, 2, n)*SPREAD(g, 1, n)/cc
    xt = r
    CALL dgesv(n, 1, kk, n, ipiv, xt, n, info)
  END SUBROUTINE la_case

END PROGRAM test_hermite_torsion_kernel
