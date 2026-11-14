! File: src/CableDyn_Modal.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Modal
  !! Modal analysis of a line about its static equilibrium: the natural frequencies and
  !! mode shapes of the generalised symmetric eigenproblem
  !!   K phi = omega^2 M phi
  !! over the free degrees of freedom (fixed or prescribed ends held), with K the static
  !! tangent stiffness and M the consistent structural mass plus the Morison added mass.
  !! K holds the element stiffness (geometric and material) and the linearised seabed
  !! normal contact; friction, damping and hydrodynamic drag are not part of an undamped
  !! modal analysis.
  !!
  !! K and M are assembled as their symmetric parts in LAPACK symmetric band storage (the
  !! nodes of a line are numbered along it, so the bandwidth is set by one element) and
  !! CD_Modal_Solve_Band computes only the requested lowest modes: the eigenvalues by a
  !! shift-invert block Lanczos iteration on the banded Cholesky factor of K, certified by
  !! a Sturm count of K - sigma M (or, for a short line, many modes, an indefinite or
  !! singular K, or a Lanczos run that is not certified, by LAPACK DSBGVX: band reduction
  !! and bisection), each mode shape by inverse iteration on the banded pencil,
  !! M-orthogonalised against the modes before it, and the returned eigenvalue as the
  !! Rayleigh quotient of that shape. Memory and time grow linearly with the line length
  !! (quadratically, with a small constant, for the band reduction). The dense routines
  !! (CD_Modal_Bar_Matrices, CD_Modal_Hermite_Matrices, CD_Modal_Solve with LAPACK DSYGV)
  !! are kept as the reference the banded solver is tested against, for small lines only.
  !!
  !! EI = 0 lines (two-node bars, three translations per node): an element of rest length
  !! l0 and current length l along the unit vector e, tension T = EA (l/l0 - 1) (zero when
  !! a tension-only element is slack), has the tangent
  !!   k = (EA/l0) e e^T + (T/l) (I - e e^T)  on  [[k, -k], [-k, k]],
  !! and the consistent mass (m l0/6) [[2I, I], [I, 2I]].
  !! Finite-EI lines (cubic-Hermite, position and tangent per node): the element Hessian of
  !! CD_HermiteCable_Element and the consistent mass of CD_HermiteCable_Mass.
  !!
  !! A line model of the cubic-Hermite dynamics (CD_Modal_Hermite_Line) adds what its dynamics
  !! carries: the end connections (a finite spring's Hessian on the end tangent; a rigid end
  !! keeps only the magnitude of its tangent, in the basis [d, b1, b2] of its direction d), the
  !! discrete attachments' masses and, on a line restrained in torsion, its twist. The dynamics
  !! of such a line carries a twist angle phi at every node (the nodal twist, with the polar
  !! inertia Irn), so the modes do too: 7 DOFs per node [r, m, phi], the lumped polar inertia
  !! (half of each adjacent element's Irn l0) as the mass of phi, and the second variation of the
  !! twist energy sum_e 1/2 (GJ/l0)(phi_{e+1} - phi_e + rho_e(q))**2 (+ the elastic end springs)
  !! as stiffness (CD_HermiteCable_Dyn_Twist_Hessian): with M_e the element torque,
  !!   d2E/dq2 = M_e d2rho/dq2 + (GJ/l0) g g^T,  d2E/dphi dq = +-(GJ/l0) g,  g = drho_e/dq,
  !! which couples the twist to the bending and, under torque-tension coupling (rho_e then holds
  !! (K/GJ)(l - l0)), to the stretch. Eliminating the angles (no polar inertia) leaves the
  !! condensed static tangent of the statics, M_t d2(-Theta)/dq2 + (1/C) g_T g_T^T,
  !! g_T = dTheta/dq: the Schur complement of the angle block is that rank-one term.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite
  USE CableDyn_SeabedContact, ONLY: CD_Seabed_Normal_Law
  USE CableDyn_Hydro, ONLY: CD_Cable_Added_Mass_Matrix
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Element, CD_HermiteCable_Mass
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_AddedMass_Element, CD_HermiteCableDynType, &
                                          CD_HermiteCable_Dyn_Twist_Hessian, CD_HCDYN_OK
  USE CableDyn_EndConnection, ONLY: CD_EndConn_Spring, CD_EndConn_Basis, CD_ENDCONN_OK, CD_ENDCONN_FINITE, &
                                    CD_ENDCONN_RIGID
  USE CableDyn_Linalg, ONLY: CD_Factor_Banded, CD_Solve_Factored_Banded, CD_Blas_Runtime_Check, CD_LINALG_OK, &
                             CD_BLAS_UNAVAILABLE_INFO
  IMPLICIT NONE
  PRIVATE

  INTEGER, PARAMETER, PUBLIC :: CD_MODAL_OK = 0, CD_MODAL_BADINPUT = 1, CD_MODAL_FAIL = 2
  ! Eigenvalue stage of CD_Modal_Solve_Band: chosen by problem size, the shift-invert Lanczos
  ! iteration (falling back to the band reduction when it is not certified), or the band
  ! reduction (DSBGVX)
  INTEGER, PARAMETER, PUBLIC :: CD_MODAL_EIG_AUTO = 0, CD_MODAL_EIG_LANCZOS = 1, CD_MODAL_EIG_BANDRED = 2
  INTEGER, PARAMETER :: I8 = SELECTED_INT_KIND(18)
  ! Shift-invert block Lanczos: block size (two, for the exactly repeated frequencies of the
  ! two transverse planes of a straight line), the residual tolerance of a wanted Ritz value
  ! and of the Ritz values that bound the Sturm interval (relative to the Ritz value of the
  ! shift-inverted operator, with a floor at round-off of the largest one), the relative gap
  ! the Sturm shift sits in, and the breakdown threshold of a new Lanczos vector. Below
  ! LZ_MIN_DOF free DOFs, or where the basis and its M-image would hold more than
  ! LZ_MAX_WORDS values (256 MB), the band reduction is used.
  INTEGER, PARAMETER :: LZ_BLOCK = 2, LZ_MIN_DOF = 200
  INTEGER(I8), PARAMETER :: LZ_MAX_WORDS = 32000000_I8
  REAL(wp), PARAMETER :: LZ_TOL = 1.0e-10_wp, LZ_TOL_MAX = 1.0e-7_wp, LZ_TOL_GUARD = 1.0e-6_wp
  REAL(wp), PARAMETER :: LZ_FLOOR = 1.0e-13_wp, LZ_GAP = 1.0e-3_wp, LZ_BREAK = 1.0e-10_wp
  ! Relative tolerance within which two components of a mode shape count as equally large in
  ! its sign convention
  REAL(wp), PARAMETER :: SIGN_TIE = 1.0e-6_wp
  ! Largest problem of the dense reference solver: three 4000 x 4000 matrices are 400 MB
  INTEGER, PARAMETER :: DENSE_MAX_DOF = 4000
  ! Inverse iterations per mode: at least MIN_ITER, at most MAX_ITER
  INTEGER, PARAMETER :: MIN_ITER = 3, MAX_ITER = 10
  REAL(wp), PARAMETER :: TWO_PI = 6.283185307179586476925286766559005768394_wp

  PUBLIC :: CD_Modal_Bar_Band, CD_Modal_Hermite_Band, CD_Modal_Solve_Band
  PUBLIC :: CD_Modal_Hermite_Line, CD_Modal_Hermite_Line_Band
  PUBLIC :: CD_Modal_Bar_Matrices, CD_Modal_Hermite_Matrices, CD_Modal_Solve
  PUBLIC :: CD_Modal_Write_Header, CD_Modal_Write_Line

CONTAINS

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_MODAL_BADINPUT
    ErrMsg = 'CableDyn_Modal: '//msg
  END SUBROUTINE fail

  SUBROUTINE add_entry(ab, kd, i, j, v)
    !! Add v, the (i, j) entry of a matrix, to the symmetric part held in upper band
    !! storage ab(kd+1+r-c, c), r <= c: a diagonal entry in full, an off-diagonal one
    !! halved (its transpose partner adds the other half).
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: kd, i, j
    REAL(wp), INTENT(IN) :: v
    IF (i == j) THEN
      ab(kd + 1, j) = ab(kd + 1, j) + v
    ELSE IF (i < j) THEN
      ab(kd + 1 + i - j, j) = ab(kd + 1 + i - j, j) + 0.5_wp*v
    ELSE
      ab(kd + 1 + j - i, i) = ab(kd + 1 + j - i, i) + 0.5_wp*v
    END IF
  END SUBROUTINE add_entry

  SUBROUTINE add_block(ab, kd, gd, blk)
    !! Add every entry of an element matrix blk on the global DOFs gd.
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: kd, gd(:)
    REAL(wp), INTENT(IN) :: blk(:, :)
    INTEGER :: a, b
    DO b = 1, SIZE(gd)
      DO a = 1, SIZE(gd)
        CALL add_entry(ab, kd, gd(a), gd(b), blk(a, b))
      END DO
    END DO
  END SUBROUTINE add_block

  SUBROUTINE band_to_dense(ab, kd, a)
    !! Expand a symmetric upper band to a full matrix.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kd
    REAL(wp), INTENT(OUT) :: a(:, :)
    INTEGER :: i, j
    a = CD_ZERO
    DO j = 1, SIZE(ab, 2)
      DO i = MAX(1, j - kd), j
        a(i, j) = ab(kd + 1 + i - j, j)
        a(j, i) = a(i, j)
      END DO
    END DO
  END SUBROUTINE band_to_dense

  SUBROUTINE sym_band_mv(ab, kd, x, y)
    !! y = A x for a symmetric A in upper band storage.
    REAL(wp), INTENT(IN) :: ab(:, :), x(:)
    INTEGER, INTENT(IN) :: kd
    REAL(wp), INTENT(OUT) :: y(:)
    INTEGER :: i, j
    REAL(wp) :: v
    y = CD_ZERO
    DO j = 1, SIZE(x)
      y(j) = y(j) + ab(kd + 1, j)*x(j)
      DO i = MAX(1, j - kd), j - 1
        v = ab(kd + 1 + i - j, j)
        y(i) = y(i) + v*x(j)
        y(j) = y(j) + v*x(i)
      END DO
    END DO
  END SUBROUTINE sym_band_mv

  REAL(wp) FUNCTION sym_band_norm(ab, kd) RESULT(s)
    !! Infinity norm of a symmetric matrix in upper band storage.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kd
    REAL(wp), ALLOCATABLE :: rows(:)
    INTEGER :: i, j
    ALLOCATE (rows(SIZE(ab, 2)))
    rows = CD_ZERO
    DO j = 1, SIZE(ab, 2)
      rows(j) = rows(j) + ABS(ab(kd + 1, j))
      DO i = MAX(1, j - kd), j - 1
        rows(i) = rows(i) + ABS(ab(kd + 1 + i - j, j))
        rows(j) = rows(j) + ABS(ab(kd + 1 + i - j, j))
      END DO
    END DO
    s = MAXVAL(rows)
  END FUNCTION sym_band_norm

  REAL(wp) FUNCTION rayleigh_quotient(a, b, kd, x) RESULT(rq)
    !! x^T A x / x^T B x for symmetric A and B in upper band storage, accumulated in
    !! quadruple precision (a product of two doubles is exact there): the low eigenvalues
    !! of a line lie many orders below its axial ones, whose terms cancel in the sum.
    USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: REAL128
    REAL(wp), INTENT(IN) :: a(:, :), b(:, :), x(:)
    INTEGER, INTENT(IN) :: kd
    REAL(REAL128) :: xa, xb, p
    INTEGER :: i, j
    xa = 0.0_REAL128
    xb = 0.0_REAL128
    DO j = 1, SIZE(x)
      p = REAL(x(j), REAL128)*REAL(x(j), REAL128)
      xa = xa + REAL(a(kd + 1, j), REAL128)*p
      xb = xb + REAL(b(kd + 1, j), REAL128)*p
      DO i = MAX(1, j - kd), j - 1
        p = 2.0_REAL128*REAL(x(i), REAL128)*REAL(x(j), REAL128)
        xa = xa + REAL(a(kd + 1 + i - j, j), REAL128)*p
        xb = xb + REAL(b(kd + 1 + i - j, j), REAL128)*p
      END DO
    END DO
    rq = REAL(xa/xb, wp)
  END FUNCTION rayleigh_quotient

  SUBROUTINE CD_Modal_Bar_Band(q, elem_conn, l0, ea, rho_a, tension_only, kd, K, M, ErrStat, ErrMsg, &
                               am_rho, am_waterline, am_diam, am_can, am_cat, seabed_kn, floor_z)
    !! Stiffness and mass of an EI = 0 line (3 DOFs per node) in state q, as their symmetric
    !! parts in upper band storage K(kd+1+i-j, j), i <= j, of half-bandwidth kd (set by the
    !! element connectivity). The optional added mass (rho, nodal waterline, per-element
    !! diameter/Can/Cat) is the Morison added mass of CD_Cable_Added_Mass_Matrix; the
    !! optional seabed (nodal normal stiffness and floor elevation) adds the tangent of the
    !! C1 normal contact law.
    REAL(wp), INTENT(IN) :: q(:), l0(:), ea(:), rho_a(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    LOGICAL, INTENT(IN) :: tension_only
    INTEGER, INTENT(OUT) :: kd
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: K(:, :), M(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: am_rho, am_waterline(:), am_diam(:), am_can(:), am_cat(:)
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:), floor_z(:)
    INTEGER :: n, nn, ne, e, a, b, ia, ib, i, j, conn1(2, 1), gd(6)
    REAL(wp) :: d(3), l, t, ke(3, 3), mm, ke6(6, 6), me6(6, 6), ma(6, 6), q2(6), wl2(2), l02(1), f, df
    CHARACTER(1024) :: em

    ErrStat = CD_MODAL_OK
    ErrMsg = ''
    kd = 0
    n = SIZE(q)
    nn = n/3
    ne = SIZE(l0)
    IF (MOD(n, 3) /= 0 .OR. n < 3 .OR. SIZE(elem_conn, 1) /= 2 .OR. SIZE(elem_conn, 2) /= ne .OR. &
        SIZE(ea) /= ne .OR. SIZE(rho_a) /= ne) THEN
      CALL fail(ErrStat, ErrMsg, 'inconsistent bar-line array sizes')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(q) .AND. ALL(l0 > CD_ZERO) .AND. ALL(ea >= CD_ZERO) .AND. ALL(rho_a >= CD_ZERO))) THEN
      CALL fail(ErrStat, ErrMsg, 'bar-line state and properties must be finite with l0 > 0, EA and mass >= 0')
      RETURN
    END IF
    IF (ne > 0) THEN
      IF (ANY(elem_conn < 1) .OR. ANY(elem_conn > nn)) THEN
        CALL fail(ErrStat, ErrMsg, 'bar-line element connectivity out of range')
        RETURN
      END IF
    END IF
    kd = 2
    DO e = 1, ne
      kd = MAX(kd, 3*ABS(elem_conn(2, e) - elem_conn(1, e)) + 2)
    END DO
    kd = MIN(kd, n - 1)
    ALLOCATE (K(kd + 1, n), M(kd + 1, n))
    K = CD_ZERO
    M = CD_ZERO
    conn1(:, 1) = [1, 2]
    DO e = 1, ne
      a = elem_conn(1, e)
      b = elem_conn(2, e)
      ia = 3*a - 3
      ib = 3*b - 3
      gd = [ia + 1, ia + 2, ia + 3, ib + 1, ib + 2, ib + 3]
      d = q(ib + 1:ib + 3) - q(ia + 1:ia + 3)
      l = SQRT(SUM(d*d))
      IF (.NOT. (l > CD_ZERO)) THEN
        CALL fail(ErrStat, ErrMsg, 'a bar element has zero length')
        RETURN
      END IF
      d = d/l
      t = ea(e)*(l/l0(e) - CD_ONE)
      IF (tension_only .AND. t <= CD_ZERO) THEN
        ke = CD_ZERO
      ELSE
        DO j = 1, 3
          DO i = 1, 3
            ke(i, j) = (ea(e)/l0(e) - t/l)*d(i)*d(j)
          END DO
          ke(j, j) = ke(j, j) + t/l
        END DO
      END IF
      ke6(1:3, 1:3) = ke
      ke6(4:6, 4:6) = ke
      ke6(1:3, 4:6) = -ke
      ke6(4:6, 1:3) = -ke
      CALL add_block(K, kd, gd, ke6)
      mm = rho_a(e)*l0(e)/6.0_wp
      me6 = CD_ZERO
      DO i = 1, 3
        me6(i, i) = 2.0_wp*mm
        me6(i + 3, i + 3) = 2.0_wp*mm
        me6(i, i + 3) = mm
        me6(i + 3, i) = mm
      END DO
      IF (PRESENT(am_rho) .AND. PRESENT(am_waterline) .AND. PRESENT(am_diam) .AND. PRESENT(am_can) .AND. &
          PRESENT(am_cat)) THEN
        q2(1:3) = q(ia + 1:ia + 3)
        q2(4:6) = q(ib + 1:ib + 3)
        wl2 = [am_waterline(a), am_waterline(b)]
        l02(1) = l0(e)
        CALL CD_Cable_Added_Mass_Matrix(q2, conn1, l02, wl2, am_rho, am_diam(e), am_can(e), am_cat(e), ma, &
                                        ErrStat, em)
        IF (ErrStat /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'added mass: '//TRIM(em))
          RETURN
        END IF
        me6 = me6 + ma
      END IF
      CALL add_block(M, kd, gd, me6)
    END DO
    IF (PRESENT(seabed_kn) .AND. PRESENT(floor_z)) THEN
      IF (SIZE(seabed_kn) /= nn .OR. SIZE(floor_z) /= nn) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed arrays must have one entry per node')
        RETURN
      END IF
      DO i = 1, nn
        CALL CD_Seabed_Normal_Law(floor_z(i) - q(3*i), seabed_kn(i), f, df)
        CALL add_entry(K, kd, 3*i, 3*i, df)
      END DO
    END IF
  END SUBROUTINE CD_Modal_Bar_Band

  SUBROUTINE CD_Modal_Hermite_Band(q, l0, ea, ei, rho_a, kd, K, M, ErrStat, ErrMsg, axial_order, bending_order, &
                                   am_rho, am_waterline, am_diam, am_can, am_cat, contact_kn, floor_z)
    !! Stiffness and mass of a cubic-Hermite line (6 DOFs per node: position and tangent)
    !! in state q, as their symmetric parts in upper band storage (half-bandwidth kd = 11):
    !! the element Hessians and consistent masses, the optional Morison added mass
    !! (CD_HermiteCable_AddedMass_Element) and the optional seabed normal contact tangent on
    !! the nodal vertical positions.
    REAL(wp), INTENT(IN) :: q(:), l0(:), ea(:), ei(:), rho_a(:)
    INTEGER, INTENT(OUT) :: kd
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: K(:, :), M(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: axial_order, bending_order
    REAL(wp), INTENT(IN), OPTIONAL :: am_rho, am_waterline, am_diam(:), am_can(:), am_cat(:)
    REAL(wp), INTENT(IN), OPTIONAL :: contact_kn(:), floor_z(:)
    INTEGER :: n, nn, ne, e, i0, i, ao, bo, gd(12)
    REAL(wp) :: qe(12), energy, fint(12), kt(12, 12), me(12, 12), ma(12, 12), f, df
    CHARACTER(1024) :: em

    ErrStat = CD_MODAL_OK
    ErrMsg = ''
    kd = 0
    n = SIZE(q)
    nn = n/6
    ne = SIZE(l0)
    ao = 4
    bo = 4
    IF (PRESENT(axial_order)) ao = axial_order
    IF (PRESENT(bending_order)) bo = bending_order
    IF (MOD(n, 6) /= 0 .OR. ne < 1 .OR. ne /= nn - 1 .OR. SIZE(ea) /= ne .OR. SIZE(ei) /= ne .OR. &
        SIZE(rho_a) /= ne) THEN
      CALL fail(ErrStat, ErrMsg, 'inconsistent Hermite-line array sizes')
      RETURN
    END IF
    kd = 11
    ALLOCATE (K(kd + 1, n), M(kd + 1, n))
    K = CD_ZERO
    M = CD_ZERO
    DO e = 1, ne
      i0 = 6*(e - 1)
      DO i = 1, 12
        gd(i) = i0 + i
      END DO
      qe = q(i0 + 1:i0 + 12)
      CALL CD_HermiteCable_Element(qe, l0(e), ea(e), ei(e), energy, fint, kt, ErrStat, em, &
                                   axial_quadrature_order=ao, bending_quadrature_order=bo)
      IF (ErrStat /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'Hermite element: '//TRIM(em))
        RETURN
      END IF
      CALL add_block(K, kd, gd, kt)
      CALL CD_HermiteCable_Mass(rho_a(e), l0(e), me, ErrStat, em)
      IF (ErrStat /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'Hermite mass: '//TRIM(em))
        RETURN
      END IF
      IF (PRESENT(am_rho) .AND. PRESENT(am_waterline) .AND. PRESENT(am_diam) .AND. PRESENT(am_can) .AND. &
          PRESENT(am_cat)) THEN
        CALL CD_HermiteCable_AddedMass_Element(qe, l0(e), am_waterline, am_rho, am_diam(e), am_can(e), am_cat(e), &
                                               ma, ErrStat, em)
        IF (ErrStat /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'Hermite added mass: '//TRIM(em))
          RETURN
        END IF
        me = me + ma
      END IF
      CALL add_block(M, kd, gd, me)
    END DO
    IF (PRESENT(contact_kn) .AND. PRESENT(floor_z)) THEN
      IF (SIZE(contact_kn) /= nn .OR. SIZE(floor_z) /= nn) THEN
        CALL fail(ErrStat, ErrMsg, 'contact arrays must have one entry per node')
        RETURN
      END IF
      DO i = 1, nn
        CALL CD_Seabed_Normal_Law(floor_z(i) - q(6*i - 3), contact_kn(i), f, df)
        CALL add_entry(K, kd, 6*i - 3, 6*i - 3, df)
      END DO
    END IF
  END SUBROUTINE CD_Modal_Hermite_Band

  SUBROUTINE CD_Modal_Hermite_Line(model, n_modes, omega2, shapes, n_found, dof_per_node, polar, ErrStat, ErrMsg)
    !! The n_modes lowest modes of a cubic-Hermite line model about its committed state (the
    !! static equilibrium a deck starts its march from), on the DOFs its dynamics solves
    !! (CD_Modal_Hermite_Line_Band). dof_per_node is 6 ([r, m] per node) or 7 ([r, m, phi]);
    !! shapes(:, j) is the full-length mode vector in the model's axes and node order (zero on
    !! the held DOFs), M-orthonormal; polar(j) its polar share of the modal kinetic energy,
    !! sum_k I_k phi_k**2 (0 without twist, 1 for a pure torsional mode).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: n_modes
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: omega2(:), shapes(:, :), polar(:)
    INTEGER, INTENT(OUT) :: n_found, dof_per_node, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: kb(:, :), mb(:, :)
    REAL(wp) :: basis(3, 3), f3(3)
    LOGICAL, ALLOCATABLE :: free(:)
    INTEGER :: n, kd, iend, j, k, nm
    CHARACTER(1024) :: em

    n_found = 0
    CALL CD_Modal_Hermite_Line_Band(model, kd, kb, mb, free, dof_per_node, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODAL_OK) RETURN
    n = SIZE(free)
    nm = MIN(n_modes, COUNT(free))
    ALLOCATE (omega2(MAX(nm, 1)), shapes(n, MAX(nm, 1)), polar(MAX(nm, 1)))
    omega2 = CD_ZERO
    shapes = CD_ZERO
    polar = CD_ZERO
    IF (nm < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'the line has no free degree of freedom')
      RETURN
    END IF
    CALL CD_Modal_Solve_Band(kb, mb, kd, free, nm, omega2, shapes, n_found, ErrStat, ErrMsg)
    IF (ErrStat /= CD_MODAL_OK) RETURN
    ! back to the model's axes: m = B [s, 0, 0] at a rigid end
    IF (model%has_endconn) THEN
      DO iend = 1, 2
        IF (model%endconn_mode(iend) /= CD_ENDCONN_RIGID) CYCLE
        CALL CD_EndConn_Basis(model%endconn_d0(:, iend), basis, ErrStat, em)
        IF (ErrStat /= CD_ENDCONN_OK) THEN
          n_found = 0
          CALL fail(ErrStat, ErrMsg, 'end connection: '//TRIM(em))
          RETURN
        END IF
        j = dof_per_node*(MERGE(1, model%nn, iend == 1) - 1) + 3
        DO k = 1, n_found
          f3 = shapes(j + 1:j + 3, k)
          shapes(j + 1:j + 3, k) = MATMUL(basis, f3)
        END DO
      END DO
    END IF
    IF (dof_per_node == 7) THEN
      DO k = 1, n_found
        polar(k) = SUM(model%tw_mass*shapes(7:n:7, k)**2)
      END DO
    END IF
  END SUBROUTINE CD_Modal_Hermite_Line

  SUBROUTINE CD_Modal_Hermite_Line_Band(model, kd, K, M, free, dof_per_node, ErrStat, ErrMsg)
    !! Stiffness and mass of a cubic-Hermite line model at its committed state, as their
    !! symmetric parts in upper band storage of half-bandwidth kd, with the free-DOF mask, on
    !! the DOFs its dynamics solves: the element stiffness and mass with the Morison added mass
    !! and the seabed normal contact of CD_Modal_Hermite_Band, the attachments' masses, the end
    !! connections and, with the nodal twist, the twist angles (see the module note; 7 DOFs per
    !! node, kd = 13, else 6 and kd = 11). The tangent handle of a rigid end is in the basis
    !! [d, b1, b2] of its direction (CD_EndConn_Basis), b1 and b2 held. A line with the
    !! condensed torsion of the quasi-static dynamics (no polar inertia) is refused.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(OUT) :: kd, dof_per_node, ErrStat
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: K(:, :), M(:, :)
    LOGICAL, ALLOCATABLE, INTENT(OUT) :: free(:)
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: k6(:, :), m6(:, :), floor_z(:), eg(:, :), eh(:, :, :), ek(:), emt(:)
    REAL(wp) :: lg(3, 2), lh(3, 3, 2), lk(2), lmt(2), f3(3), k3(3, 3), ke(14, 14), kl(4, 4), basis(3, 3, 2)
    LOGICAL :: twist, rigid(2)
    INTEGER :: nn, ne, n6, n, kd6, i, j, i6, j6, e, a, b, ia, ib, iend, node, p
    INTEGER :: gd(14), gl4(4)
    CHARACTER(1024) :: em

    ErrStat = CD_MODAL_OK
    ErrMsg = ''
    kd = 0
    dof_per_node = 6
    nn = model%nn
    ne = model%ne
    n6 = model%ndof
    twist = model%tw_active
    IF (model%torsion%active .AND. .NOT. twist) THEN
      CALL fail(ErrStat, ErrMsg, 'a line with condensed torsion (no polar inertia Irn) has no torsional '// &
                'modes; give its torsion the polar inertia')
      RETURN
    END IF
    ALLOCATE (floor_z(nn))
    floor_z = model%seabed_z
    IF (model%has_am .AND. model%has_contact) THEN
      CALL CD_Modal_Hermite_Band(model%q, model%l0, model%EA, model%EI, model%rho_a, kd6, k6, m6, ErrStat, em, &
                                 axial_order=model%axial_quadrature_order, &
                                 bending_order=model%bending_quadrature_order, am_rho=model%am_rho, &
                                 am_waterline=model%am_wl, am_diam=model%am_diam, am_can=model%am_can, &
                                 am_cat=model%am_cat, contact_kn=model%contact_kn, floor_z=floor_z)
    ELSE IF (model%has_am) THEN
      CALL CD_Modal_Hermite_Band(model%q, model%l0, model%EA, model%EI, model%rho_a, kd6, k6, m6, ErrStat, em, &
                                 axial_order=model%axial_quadrature_order, &
                                 bending_order=model%bending_quadrature_order, am_rho=model%am_rho, &
                                 am_waterline=model%am_wl, am_diam=model%am_diam, am_can=model%am_can, &
                                 am_cat=model%am_cat)
    ELSE IF (model%has_contact) THEN
      CALL CD_Modal_Hermite_Band(model%q, model%l0, model%EA, model%EI, model%rho_a, kd6, k6, m6, ErrStat, em, &
                                 axial_order=model%axial_quadrature_order, &
                                 bending_order=model%bending_quadrature_order, contact_kn=model%contact_kn, &
                                 floor_z=floor_z)
    ELSE
      CALL CD_Modal_Hermite_Band(model%q, model%l0, model%EA, model%EI, model%rho_a, kd6, k6, m6, ErrStat, em, &
                                 axial_order=model%axial_quadrature_order, &
                                 bending_order=model%bending_quadrature_order)
    END IF
    IF (ErrStat /= CD_MODAL_OK) THEN
      ErrMsg = em
      RETURN
    END IF
    ! discrete attachments: dry mass m and added mass Ca rho V on the node's translations
    IF (model%has_attach) THEN
      DO p = 1, SIZE(model%att_node)
        DO i = 1, 3
          j = 6*(model%att_node(p) - 1) + i
          CALL add_entry(m6, kd6, j, j, model%att_mass(p) + model%att_madd(p))
        END DO
      END DO
    END IF
    ! end connections: a finite spring adds d2U/dm2 on its end tangent; a rigid end is
    ! rotated into its basis below
    rigid = .FALSE.
    IF (model%has_endconn) THEN
      DO iend = 1, 2
        node = MERGE(1, nn, iend == 1)
        j = 6*(node - 1) + 3
        IF (model%endconn_mode(iend) == CD_ENDCONN_FINITE) THEN
          CALL CD_EndConn_Spring(model%q(j + 1:j + 3), model%endconn_d0(:, iend), model%endconn_k(iend), f3, k3, &
                                 ErrStat, em)
          IF (ErrStat /= CD_ENDCONN_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'end connection: '//TRIM(em))
            RETURN
          END IF
          CALL add_block(k6, kd6, [j + 1, j + 2, j + 3], k3)
        ELSE IF (model%endconn_mode(iend) == CD_ENDCONN_RIGID) THEN
          rigid(iend) = .TRUE.
          CALL CD_EndConn_Basis(model%endconn_d0(:, iend), basis(:, :, iend), ErrStat, em)
          IF (ErrStat /= CD_ENDCONN_OK) THEN
            CALL fail(ErrStat, ErrMsg, 'end connection: '//TRIM(em))
            RETURN
          END IF
        END IF
      END DO
    END IF

    IF (.NOT. twist) THEN
      n = n6
      kd = kd6
      CALL MOVE_ALLOC(k6, K)
      CALL MOVE_ALLOC(m6, M)
      ALLOCATE (free(n))
      free = model%freemask
    ELSE
      ! [r, m] of node p at 7(p - 1) + 1..6, its angle at 7 p: DOF i6 of the cable is
      ! i6 + (i6 - 1)/6; one element spans 14 DOFs (half-bandwidth 13)
      dof_per_node = 7
      n = 7*nn
      kd = 13
      ALLOCATE (K(kd + 1, n), M(kd + 1, n), free(n))
      K = CD_ZERO
      M = CD_ZERO
      DO j6 = 1, n6
        DO i6 = MAX(1, j6 - kd6), j6
          K(kd + 1 + (i6 + (i6 - 1)/6) - (j6 + (j6 - 1)/6), j6 + (j6 - 1)/6) = k6(kd6 + 1 + i6 - j6, j6)
          M(kd + 1 + (i6 + (i6 - 1)/6) - (j6 + (j6 - 1)/6), j6 + (j6 - 1)/6) = m6(kd6 + 1 + i6 - j6, j6)
        END DO
        free(j6 + (j6 - 1)/6) = model%freemask(j6)
      END DO
      DEALLOCATE (k6, m6)
      ALLOCATE (eg(12, ne), eh(12, 12, ne), ek(ne), emt(ne))
      CALL CD_HermiteCable_Dyn_Twist_Hessian(model, eg, eh, ek, emt, lg, lh, lk, lmt, ErrStat, em)
      IF (ErrStat /= CD_HCDYN_OK) THEN
        CALL fail(ErrStat, ErrMsg, TRIM(em))
        RETURN
      END IF
      DO e = 1, ne
        ! element DOFs [r_e, m_e, phi_e, r_e+1, m_e+1, phi_e+1]; the cable's 12 at 1..6, 8..13
        DO i = 1, 14
          gd(i) = 7*(e - 1) + i
        END DO
        ke = CD_ZERO
        DO b = 1, 12
          ib = b + (b - 1)/6
          DO a = 1, 12
            ia = a + (a - 1)/6
            ke(ia, ib) = emt(e)*eh(a, b, e) + ek(e)*eg(a, e)*eg(b, e)
          END DO
          ke(ib, 14) = ek(e)*eg(b, e)
          ke(14, ib) = ke(ib, 14)
          ke(ib, 7) = -ek(e)*eg(b, e)
          ke(7, ib) = ke(ib, 7)
        END DO
        ke(7, 7) = ek(e)
        ke(14, 14) = ek(e)
        ke(7, 14) = -ek(e)
        ke(14, 7) = -ek(e)
        CALL add_block(K, kd, gd, ke)
      END DO
      DO iend = 1, 2
        IF (.NOT. lk(iend) > CD_ZERO) CYCLE
        ! the elastic end's spring on [m, phi] of its node, d2psi/dm2 signed by its torque
        node = MERGE(1, nn, iend == 1)
        gl4 = [7*(node - 1) + 4, 7*(node - 1) + 5, 7*(node - 1) + 6, 7*node]
        DO b = 1, 3
          DO a = 1, 3
            kl(a, b) = lk(iend)*lg(a, iend)*lg(b, iend) + MERGE(-lmt(iend), lmt(iend), iend == 1)*lh(a, b, iend)
          END DO
          kl(b, 4) = -lk(iend)*lg(b, iend)
          kl(4, b) = kl(b, 4)
        END DO
        kl(4, 4) = lk(iend)
        CALL add_block(K, kd, gl4, kl)
      END DO
      DO p = 1, nn
        CALL add_entry(M, kd, 7*p, 7*p, model%tw_mass(p))
        free(7*p) = model%tw_free(p)
      END DO
    END IF
    ! a rigid end: its tangent handle in the basis [d, b1, b2], b1 and b2 held
    DO iend = 1, 2
      IF (.NOT. rigid(iend)) CYCLE
      node = MERGE(1, nn, iend == 1)
      j = dof_per_node*(node - 1) + 3
      CALL rotate_band_block(K, kd, j, basis(:, :, iend), ErrStat, em)
      IF (ErrStat == CD_MODAL_OK) CALL rotate_band_block(M, kd, j, basis(:, :, iend), ErrStat, em)
      IF (ErrStat /= CD_MODAL_OK) THEN
        ErrMsg = em
        RETURN
      END IF
      free(j + 2:j + 3) = .FALSE.
    END DO
  END SUBROUTINE CD_Modal_Hermite_Line_Band

  SUBROUTINE rotate_band_block(ab, kd, j0, b, ErrStat, ErrMsg)
    !! A <- T^T A T for a symmetric A in upper band storage, T the identity but for the block b
    !! on the DOFs j0 + 1..j0 + 3 (the tangent handle of a node in a rigid end's basis). The
    !! block's couplings reach only the DOFs of its node's two elements, all within kd of every
    !! DOF of the block, so the band does not widen; an entry that would fails closed.
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: kd, j0
    REAL(wp), INTENT(IN) :: b(3, 3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: w(:, :)
    INTEGER :: n, lo, hi, i, j
    ErrStat = CD_MODAL_OK
    ErrMsg = ''
    n = SIZE(ab, 2)
    lo = MAX(1, j0 + 1 - kd)
    hi = MIN(n, j0 + 3 + kd)
    ALLOCATE (w(lo:hi, lo:hi))
    w = CD_ZERO
    DO j = lo, hi
      DO i = MAX(lo, j - kd), j
        w(i, j) = ab(kd + 1 + i - j, j)
        w(j, i) = w(i, j)
      END DO
    END DO
    w(j0 + 1:j0 + 3, :) = MATMUL(TRANSPOSE(b), w(j0 + 1:j0 + 3, :))
    w(:, j0 + 1:j0 + 3) = MATMUL(w(:, j0 + 1:j0 + 3), b)
    DO j = lo, hi
      DO i = lo, j
        IF (.NOT. ((i > j0 .AND. i <= j0 + 3) .OR. (j > j0 .AND. j <= j0 + 3))) CYCLE
        IF (j - i <= kd) THEN
          ab(kd + 1 + i - j, j) = w(i, j)
        ELSE IF (ABS(w(i, j)) > CD_ZERO) THEN
          CALL fail(ErrStat, ErrMsg, 'a rigid end basis would widen the band')
          RETURN
        END IF
      END DO
    END DO
  END SUBROUTINE rotate_band_block

  SUBROUTINE CD_Modal_Bar_Matrices(q, elem_conn, l0, ea, rho_a, tension_only, K, M, ErrStat, ErrMsg, &
                                   am_rho, am_waterline, am_diam, am_can, am_cat, seabed_kn, floor_z)
    !! Dense form of CD_Modal_Bar_Band (the symmetric parts), for the dense reference solver.
    REAL(wp), INTENT(IN) :: q(:), l0(:), ea(:), rho_a(:)
    INTEGER, INTENT(IN) :: elem_conn(:, :)
    LOGICAL, INTENT(IN) :: tension_only
    REAL(wp), INTENT(OUT) :: K(:, :), M(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: am_rho, am_waterline(:), am_diam(:), am_can(:), am_cat(:)
    REAL(wp), INTENT(IN), OPTIONAL :: seabed_kn(:), floor_z(:)
    REAL(wp), ALLOCATABLE :: kb(:, :), mb(:, :)
    INTEGER :: n, kd
    K = CD_ZERO
    M = CD_ZERO
    n = SIZE(q)
    IF (SIZE(K, 1) /= n .OR. SIZE(K, 2) /= n .OR. SIZE(M, 1) /= n .OR. SIZE(M, 2) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'inconsistent bar-line array sizes')
      RETURN
    END IF
    CALL CD_Modal_Bar_Band(q, elem_conn, l0, ea, rho_a, tension_only, kd, kb, mb, ErrStat, ErrMsg, am_rho, &
                           am_waterline, am_diam, am_can, am_cat, seabed_kn, floor_z)
    IF (ErrStat /= CD_MODAL_OK) RETURN
    CALL band_to_dense(kb, kd, K)
    CALL band_to_dense(mb, kd, M)
  END SUBROUTINE CD_Modal_Bar_Matrices

  SUBROUTINE CD_Modal_Hermite_Matrices(q, l0, ea, ei, rho_a, K, M, ErrStat, ErrMsg, axial_order, bending_order, &
                                       am_rho, am_waterline, am_diam, am_can, am_cat, contact_kn, floor_z)
    !! Dense form of CD_Modal_Hermite_Band (the symmetric parts), for the dense reference solver.
    REAL(wp), INTENT(IN) :: q(:), l0(:), ea(:), ei(:), rho_a(:)
    REAL(wp), INTENT(OUT) :: K(:, :), M(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: axial_order, bending_order
    REAL(wp), INTENT(IN), OPTIONAL :: am_rho, am_waterline, am_diam(:), am_can(:), am_cat(:)
    REAL(wp), INTENT(IN), OPTIONAL :: contact_kn(:), floor_z(:)
    REAL(wp), ALLOCATABLE :: kb(:, :), mb(:, :)
    INTEGER :: n, kd
    K = CD_ZERO
    M = CD_ZERO
    n = SIZE(q)
    IF (SIZE(K, 1) /= n .OR. SIZE(K, 2) /= n .OR. SIZE(M, 1) /= n .OR. SIZE(M, 2) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'inconsistent Hermite-line array sizes')
      RETURN
    END IF
    CALL CD_Modal_Hermite_Band(q, l0, ea, ei, rho_a, kd, kb, mb, ErrStat, ErrMsg, axial_order, bending_order, &
                               am_rho, am_waterline, am_diam, am_can, am_cat, contact_kn, floor_z)
    IF (ErrStat /= CD_MODAL_OK) RETURN
    CALL band_to_dense(kb, kd, K)
    CALL band_to_dense(mb, kd, M)
  END SUBROUTINE CD_Modal_Hermite_Matrices

  RECURSIVE SUBROUTINE CD_Modal_Solve_Band(K, M, kd, free, n_modes, omega2, shapes, n_found, ErrStat, ErrMsg, &
                                           eig_method, eig_used)
    !! The n_modes lowest eigenpairs of K phi = omega^2 M phi on the free DOFs, K and M in
    !! symmetric upper band storage of half-bandwidth kd (CD_Modal_Bar_Band,
    !! CD_Modal_Hermite_Band). The held DOFs are removed, which keeps the band. The lowest
    !! n_modes eigenvalues come from a shift-invert block Lanczos iteration (lanczos_lowest)
    !! when it is the cheaper solver and its count is certified, else from DSBGVX (without
    !! eigenvectors: those would need an n x n work matrix); each shape is then found by
    !! inverse iteration with the banded LU factors of K - omega^2 M, M-orthogonalised
    !! against the shapes before it (so a repeated frequency, such as the two transverse
    !! planes of a taut string, gets two orthogonal shapes), and accepted on the residual of
    !! its eigen-equation. omega2 is the Rayleigh quotient of the shape (quadruple-precision
    !! sums), in ascending order. shapes(:, j) is the full-length mode vector (zero on the
    !! held DOFs), M-orthonormal on the free DOFs, signed so that its largest component is
    !! positive (the first of those equal to it within SIGN_TIE: a symmetric line's mirrored
    !! nodes). A negative omega2 (an unstable or compressed state) is returned as computed.
    !! eig_method (CD_MODAL_EIG_AUTO by default) selects the eigenvalue stage; eig_used
    !! returns the one that produced the eigenvalues (CD_MODAL_EIG_LANCZOS or
    !! CD_MODAL_EIG_BANDRED; CD_MODAL_EIG_AUTO when none did).
    REAL(wp), INTENT(IN) :: K(:, :), M(:, :)
    INTEGER, INTENT(IN) :: kd
    LOGICAL, INTENT(IN) :: free(:)
    INTEGER, INTENT(IN) :: n_modes
    REAL(wp), INTENT(OUT) :: omega2(:), shapes(:, :)
    INTEGER, INTENT(OUT) :: n_found, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: eig_method
    INTEGER, INTENT(OUT), OPTIONAL :: eig_used
    INTEGER :: n, nf, kc, i, j, ii, jj, info, m_found, mode, it, ntry, prev, pass, es, method
    INTEGER, ALLOCATABLE :: map(:), iwork(:), ifail(:), ipiv(:)
    INTEGER(I8) :: seed
    REAL(wp), ALLOCATABLE :: ac(:, :), bc(:, :), a(:, :), b(:, :), w(:), work(:), lu(:, :), x(:), y(:), r(:)
    REAL(wp), ALLOCATABLE :: vec(:, :), bvec(:, :)
    REAL(wp) :: qdum(1, 1), zdum(1, 1), anorm, bnorm, shift, scale, nrm, res, rq, noise, xmax
    LOGICAL :: converged, lz_ok
    CHARACTER(1024) :: em
    EXTERNAL :: dsbgvx

    ErrStat = CD_MODAL_OK
    ErrMsg = ''
    omega2 = CD_ZERO
    shapes = CD_ZERO
    n_found = 0
    IF (PRESENT(eig_used)) eig_used = CD_MODAL_EIG_AUTO
    method = CD_MODAL_EIG_AUTO
    IF (PRESENT(eig_method)) method = eig_method
    n = SIZE(free)
    IF (kd < 0 .OR. SIZE(K, 1) /= kd + 1 .OR. SIZE(M, 1) /= kd + 1 .OR. SIZE(K, 2) /= n .OR. SIZE(M, 2) /= n .OR. &
        SIZE(shapes, 1) /= n .OR. SIZE(shapes, 2) < n_modes .OR. SIZE(omega2) < n_modes .OR. n_modes < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'inconsistent modal array sizes')
      RETURN
    END IF
    nf = COUNT(free)
    IF (nf < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'the line has no free degree of freedom')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(K) .AND. CD_All_Finite(M))) THEN
      CALL fail(ErrStat, ErrMsg, 'the stiffness or mass matrix is not finite')
      RETURN
    END IF
    ALLOCATE (map(nf))
    j = 0
    DO i = 1, n
      IF (free(i)) THEN
        j = j + 1
        map(j) = i
      END IF
    END DO
    ! The free-DOF matrices: removing rows and columns never widens the band.
    kc = MIN(kd, nf - 1)
    ALLOCATE (ac(kc + 1, nf), bc(kc + 1, nf))
    ac = CD_ZERO
    bc = CD_ZERO
    DO jj = 1, nf
      j = map(jj)
      DO ii = MAX(1, jj - kc), jj
        i = map(ii)
        IF (j - i > kd) CYCLE
        ac(kc + 1 + ii - jj, jj) = K(kd + 1 + i - j, j)
        bc(kc + 1 + ii - jj, jj) = M(kd + 1 + i - j, j)
      END DO
    END DO
    n_found = MIN(n_modes, nf)

    ! The lowest n_found eigenvalues: the shift-invert Lanczos iteration where it is the
    ! cheaper solver, else (or when its count is not certified) the band reduction.
    ALLOCATE (w(nf))
    lz_ok = .FALSE.
    IF (method == CD_MODAL_EIG_LANCZOS .OR. (method == CD_MODAL_EIG_AUTO .AND. lanczos_cheaper(nf, kc, n_found))) &
      CALL lanczos_lowest(ac, bc, kc, n_found, w, lz_ok)
    IF (lz_ok) THEN
      IF (PRESENT(eig_used)) eig_used = CD_MODAL_EIG_LANCZOS
    ELSE
      ! DSBGVX overwrites its band copies.
      ALLOCATE (a(kc + 1, nf), b(kc + 1, nf), work(7*nf), iwork(5*nf), ifail(nf))
      a = ac
      b = bc
      CALL dsbgvx('N', 'I', 'U', nf, kc, kc, a, kc + 1, b, kc + 1, qdum, 1, CD_ZERO, CD_ZERO, 1, n_found, &
                  2.0_wp*TINY(CD_ONE), m_found, w, zdum, 1, work, iwork, ifail, info)
      IF (info /= 0 .OR. m_found /= n_found) THEN
        ErrStat = CD_MODAL_FAIL
        IF (info == CD_BLAS_UNAVAILABLE_INFO) THEN
          CALL CD_Blas_Runtime_Check('CableDyn_Modal (DSBGVX)', es, em)
          ErrMsg = 'CableDyn_Modal: '//TRIM(em)
        ELSE IF (info > nf) THEN
          ErrMsg = 'CableDyn_Modal: the mass matrix is not positive definite (DSBGVX)'
        ELSE
          BLOCK
            ! Local buffer: a record longer than the caller's ErrMsg truncates
            ! instead of aborting the internal write.
            CHARACTER(1024) :: wmsg
            INTEGER :: wios
            wmsg = ''
            WRITE (wmsg, '(A,I0,A,I0,A,I0)', IOSTAT=wios) 'CableDyn_Modal: DSBGVX failed, INFO = ', info, ', ', &
              m_found, ' of the requested eigenvalues found: ', n_found
            ErrMsg = wmsg
          END BLOCK
        END IF
        n_found = 0
        RETURN
      END IF
      DEALLOCATE (a, b, work, iwork, ifail)
      IF (PRESENT(eig_used)) eig_used = CD_MODAL_EIG_BANDRED
    END IF

    ! The shapes by inverse iteration on the banded pencil.
    anorm = sym_band_norm(ac, kc)
    bnorm = sym_band_norm(bc, kc)
    ! round-off level of an eigenvalue: eps times the largest one (about |K| / min diag M)
    noise = 1.0e3_wp*EPSILON(CD_ONE)*anorm/MINVAL(bc(kc + 1, :))
    ALLOCATE (lu(3*kc + 1, nf), ipiv(nf), x(nf), y(nf), r(nf), vec(nf, n_found), bvec(nf, n_found))
    DO mode = 1, n_found
      ! K - omega^2 M is singular to working precision by construction; an exactly zero
      ! pivot is moved off by a round-off shift of omega^2 (a unit scale when K = 0).
      shift = CD_ZERO
      scale = anorm/bnorm + ABS(w(mode))
      IF (.NOT. (scale > CD_ZERO)) scale = CD_ONE
      DO ntry = 1, 4
        CALL shifted_general_band(w(mode) + shift)
        CALL CD_Factor_Banded(lu, kc, kc, ipiv, es, em, matrix_validated=.TRUE.)
        IF (es == CD_LINALG_OK) EXIT
        shift = 10.0_wp**ntry*EPSILON(CD_ONE)*scale
      END DO
      IF (es /= CD_LINALG_OK) THEN
        CALL mode_fail('the shifted stiffness could not be factored: '//TRIM(em))
        RETURN
      END IF
      ! A deterministic pseudo-random start (a start orthogonal to the mode is improbable).
      seed = 12345_I8 + 7919_I8*INT(mode, I8)
      DO i = 1, nf
        seed = MOD(69069_I8*seed + 1_I8, 2147483647_I8)
        x(i) = REAL(seed, wp)/2147483647.0_wp - 0.5_wp
      END DO
      converged = .FALSE.
      DO it = 1, MAX_ITER
        CALL sym_band_mv(bc, kc, x, y)
        CALL CD_Solve_Factored_Banded(lu, kc, kc, ipiv, y, es, em, factor_validated=.TRUE.)
        IF (es /= CD_LINALG_OK) THEN
          CALL mode_fail('inverse iteration solve failed: '//TRIM(em))
          RETURN
        END IF
        DO pass = 1, 2
          DO prev = 1, mode - 1
            y = y - DOT_PRODUCT(bvec(:, prev), y)*vec(:, prev)
          END DO
        END DO
        CALL sym_band_mv(bc, kc, y, r)
        nrm = SQRT(MAX(DOT_PRODUCT(y, r), CD_ZERO))
        IF (.NOT. (nrm > CD_ZERO) .OR. .NOT. CD_All_Finite(y)) THEN
          CALL mode_fail('inverse iteration lost the mode')
          RETURN
        END IF
        x = y/nrm
        ! residual of K x = omega^2 M x against the scale of the two terms
        CALL sym_band_mv(ac, kc, x, r)
        CALL sym_band_mv(bc, kc, x, y)
        r = r - w(mode)*y
        res = MAXVAL(ABS(r))
        IF (it >= MIN_ITER .AND. res <= 1.0e-9_wp*(anorm + ABS(w(mode))*bnorm)*MAXVAL(ABS(x))) THEN
          converged = .TRUE.
          EXIT
        END IF
      END DO
      IF (.NOT. converged) THEN
        CALL mode_fail('inverse iteration did not converge')
        RETURN
      END IF
      ! The eigenvalue from the converged shape: the Rayleigh quotient is exact to second
      ! order in the shape error, where the band reduction of DSBGVX loses the low end of
      ! the spectrum to the round-off of the axial stiffness. The shape must belong to its
      ! own eigenvalue, not to another computed one distinct from it beyond round-off.
      rq = rayleigh_quotient(ac, bc, kc, x)
      DO j = 1, n_found
        IF (j == mode) CYCLE
        IF (ABS(w(j) - w(mode)) > MAX(1.0e-6_wp*MAX(ABS(w(j)), ABS(w(mode))), noise) .AND. &
            ABS(rq - w(j)) < ABS(rq - w(mode))) THEN
          CALL mode_fail('inverse iteration converged to another mode')
          RETURN
        END IF
      END DO
      ! the sign: the largest component positive; of components equal to it in magnitude to
      ! round-off (the mirrored nodes of a symmetric line) the first one
      xmax = MAXVAL(ABS(x))
      DO i = 1, nf - 1
        IF (ABS(x(i)) >= (CD_ONE - SIGN_TIE)*xmax) EXIT
      END DO
      IF (x(i) < CD_ZERO) x = -x
      vec(:, mode) = x
      CALL sym_band_mv(bc, kc, x, bvec(:, mode))
      omega2(mode) = rq
      shapes(map, mode) = x
    END DO
    ! ascending order (the refined values of a repeated frequency may swap)
    DO mode = 2, n_found
      DO j = mode, 2, -1
        IF (.NOT. (omega2(j) < omega2(j - 1))) EXIT
        rq = omega2(j)
        omega2(j) = omega2(j - 1)
        omega2(j - 1) = rq
        x = shapes(map, j)
        shapes(map, j) = shapes(map, j - 1)
        shapes(map, j - 1) = x
      END DO
    END DO

  CONTAINS

    SUBROUTINE shifted_general_band(sigma)
      !! lu = K - sigma M on the free DOFs in LAPACK general band storage (kl = ku = kc).
      REAL(wp), INTENT(IN) :: sigma
      INTEGER :: ic, jc
      lu = CD_ZERO
      DO jc = 1, nf
        DO ic = MAX(1, jc - kc), MIN(nf, jc + kc)
          IF (ic <= jc) THEN
            lu(2*kc + 1 + ic - jc, jc) = ac(kc + 1 + ic - jc, jc) - sigma*bc(kc + 1 + ic - jc, jc)
          ELSE
            lu(2*kc + 1 + ic - jc, jc) = ac(kc + 1 + jc - ic, ic) - sigma*bc(kc + 1 + jc - ic, ic)
          END IF
        END DO
      END DO
    END SUBROUTINE shifted_general_band

    SUBROUTINE mode_fail(msg)
      CHARACTER(*), INTENT(IN) :: msg
      INTEGER :: used
      IF (lz_ok) THEN
        ! A shape the Lanczos eigenvalues did not give: the whole solve again on the
        ! eigenvalues of the band reduction, which succeeds or fails as it does alone.
        CALL CD_Modal_Solve_Band(K, M, kd, free, n_modes, omega2, shapes, n_found, ErrStat, ErrMsg, &
                                 eig_method=CD_MODAL_EIG_BANDRED, eig_used=used)
        IF (PRESENT(eig_used)) eig_used = used
        RETURN
      END IF
      ErrStat = CD_MODAL_FAIL
      BLOCK
        ! Local buffer: a record longer than the caller's ErrMsg truncates
        ! instead of aborting the internal write.
        CHARACTER(1024) :: wmsg
        INTEGER :: wios
        wmsg = ''
        WRITE (wmsg, '(A,I0,A)', IOSTAT=wios) 'CableDyn_Modal: mode ', mode, ': '//msg
        ErrMsg = wmsg
      END BLOCK
      n_found = 0
      omega2 = CD_ZERO
      shapes = CD_ZERO
    END SUBROUTINE mode_fail

  END SUBROUTINE CD_Modal_Solve_Band

  INTEGER FUNCTION lanczos_max_basis(nf, nwant) RESULT(mb)
    !! The bound on the Lanczos basis for nwant of nf eigenvalues: the iteration usually
    !! converges with about twice nwant vectors.
    INTEGER, INTENT(IN) :: nf, nwant
    mb = MIN(nf, 2*nwant + MAX(nwant, 40))
  END FUNCTION lanczos_max_basis

  LOGICAL FUNCTION lanczos_cheaper(nf, kc, nwant) RESULT(yes)
    !! Whether the shift-invert Lanczos iteration is expected to cost less than the band
    !! reduction for nwant of nf eigenvalues at half-bandwidth kc: the work of its
    !! reorthogonalisation grows as nf m**2 with the basis size m (about 2 nwant + 20),
    !! that of the reduction as nf**2 kc (the constant measured on lines of 300 to 24000
    !! free DOFs).
    !! The memory of the basis is bounded (LZ_MAX_WORDS).
    INTEGER, INTENT(IN) :: nf, kc, nwant
    INTEGER(I8) :: m
    m = INT(MIN(nf, 2*nwant + 20), I8)
    yes = nf >= LZ_MIN_DOF .AND. m*m <= 4_I8*INT(nf, I8)*INT(MAX(kc, 1), I8) .AND. &
          2_I8*INT(lanczos_max_basis(nf, nwant), I8)*INT(nf, I8) <= LZ_MAX_WORDS
  END FUNCTION lanczos_cheaper

  SUBROUTINE lanczos_lowest(ac, bc, kc, nwant, w, ok)
    !! The nwant lowest eigenvalues w (ascending) of K x = lambda M x, K and M symmetric in
    !! upper band storage of half-bandwidth kc, both positive definite: a block Lanczos
    !! iteration (block LZ_BLOCK, a deterministic pseudo-random start, full
    !! M-reorthogonalisation by two passes of classical Gram-Schmidt) on the shift-invert
    !! operator S = K^-1 M (banded Cholesky factor of K), whose largest eigenvalues
    !! theta = 1/lambda belong to the wanted modes. The Ritz values are those of the
    !! projection V^T M S V, each accepted on its Lanczos residual, the norm of
    !! S x - theta x. Shift-invert keeps the low end of the spectrum to relative accuracy
    !! where a band reduction loses it to the round-off of the axial stiffness. The count is
    !! certified: the Cholesky factor of K shows that no eigenvalue lies at or below zero,
    !! and the inertia of K - sigma M (sturm_count) at a shift sigma in a gap above the
    !! wanted values equals the number of Ritz values below sigma, so no mode is missed (a
    !! frequency repeated more often than the block size, an eigenvector the start misses)
    !! and none is counted twice. ok is false (w undefined) when K or M is not positive
    !! definite, the basis reaches lanczos_max_basis unconverged or uncertified, or a LAPACK
    !! call fails; the caller then uses the band reduction.
    REAL(wp), INTENT(IN) :: ac(:, :), bc(:, :)
    INTEGER, INTENT(IN) :: kc, nwant
    REAL(wp), INTENT(OUT) :: w(:)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: nf, mmax, nb, c0, pb, pn, nnew, i, j, r, k, info, lwork, next_check, pass
    INTEGER(I8) :: seed
    REAL(wp), ALLOCATABLE :: fk(:, :), v(:, :), mv(:, :), wb(:, :), mwb(:, :), h(:, :), t(:, :), theta(:)
    REAL(wp), ALLOCATABLE :: work(:), c(:, :), cc(:), est(:), lam(:), y(:), my(:)
    REAL(wp) :: wq(1), g(LZ_BLOCK, LZ_BLOCK), ref(LZ_BLOCK), thmax, sigma, avg
    LOGICAL :: good, conv
    EXTERNAL :: dpbtrf, dpbtrs, dsyev

    ok = .FALSE.
    w = CD_ZERO
    nf = SIZE(ac, 2)
    IF (nwant < 1 .OR. nwant > nf .OR. nf < 2*LZ_BLOCK) RETURN
    mmax = lanczos_max_basis(nf, nwant)
    ! M, then K, positive definite (the factor of M is not used further)
    ALLOCATE (fk(kc + 1, nf))
    fk = bc
    CALL dpbtrf('U', nf, kc, fk, kc + 1, info)
    IF (info /= 0) RETURN
    fk = ac
    CALL dpbtrf('U', nf, kc, fk, kc + 1, info)
    IF (info /= 0) RETURN
    ALLOCATE (v(nf, mmax), mv(nf, mmax), wb(nf, LZ_BLOCK), mwb(nf, LZ_BLOCK), h(mmax, mmax), t(mmax, mmax), &
              theta(mmax), c(mmax, LZ_BLOCK), cc(mmax), est(mmax), lam(mmax), y(nf), my(nf))
    h = CD_ZERO
    t = CD_ZERO
    CALL dsyev('V', 'U', mmax, t, mmax, theta, wq, -1, info)
    IF (info /= 0) RETURN
    lwork = MAX(3*mmax, INT(wq(1)))
    ALLOCATE (work(lwork))

    nb = 0
    DO j = 1, LZ_BLOCK
      CALL random_vector(j)
      CALL append(1, SQRT(SUM(y*y)), good)
      IF (.NOT. good) RETURN
    END DO
    c0 = 0
    next_check = MIN(nwant + 1, nf)
    DO
      ! the block c0 + 1..nb: wb = S v, projected out of the basis (twice), the projection
      ! coefficients the new columns of H = V^T M S V
      pb = nb - c0
      wb(:, 1:pb) = mv(:, c0 + 1:nb)
      CALL dpbtrs('U', nf, kc, pb, fk, kc + 1, wb, nf, info)
      IF (info /= 0) RETURN
      IF (.NOT. CD_All_Finite(wb(:, 1:pb))) RETURN
      DO j = 1, pb
        ref(j) = SQRT(SUM(wb(:, j)**2))
      END DO
      DO pass = 1, 2
        c(1:nb, 1:pb) = MATMUL(TRANSPOSE(mv(:, 1:nb)), wb(:, 1:pb))
        wb(:, 1:pb) = wb(:, 1:pb) - MATMUL(v(:, 1:nb), c(1:nb, 1:pb))
        h(1:nb, c0 + 1:nb) = h(1:nb, c0 + 1:nb) + c(1:nb, 1:pb)
      END DO
      h(c0 + 1:nb, 1:c0) = TRANSPOSE(h(1:c0, c0 + 1:nb))
      DO j = c0 + 1, nb
        DO i = c0 + 1, j - 1
          avg = 0.5_wp*(h(i, j) + h(j, i))
          h(i, j) = avg
          h(j, i) = avg
        END DO
      END DO

      IF (nb >= next_check .OR. nb == nf .OR. nb >= mmax) THEN
        next_check = nb + MAX(LZ_BLOCK, nb/8)
        ! Ritz values lam(r) = 1/theta, ascending, and the norms est(r) of their residuals
        ! wb s (s the Ritz vector's components on the last block)
        t(1:nb, 1:nb) = h(1:nb, 1:nb)
        CALL dsyev('V', 'U', nb, t, mmax, theta, work, lwork, info)
        IF (info /= 0) RETURN
        DO j = 1, pb
          CALL sym_band_mv(bc, kc, wb(:, j), mwb(:, j))
        END DO
        DO j = 1, pb
          DO i = 1, pb
            g(i, j) = DOT_PRODUCT(wb(:, i), mwb(:, j))
          END DO
        END DO
        thmax = theta(nb)
        DO r = 1, nb
          k = nb + 1 - r
          lam(r) = HUGE(CD_ONE)
          IF (theta(k) > CD_ZERO) lam(r) = CD_ONE/theta(k)
          est(r) = SQRT(MAX(DOT_PRODUCT(t(c0 + 1:nb, k), MATMUL(g(1:pb, 1:pb), t(c0 + 1:nb, k))), CD_ZERO))
        END DO
        conv = .TRUE.
        DO r = 1, nwant
          conv = conv .AND. converged_ritz(r, LZ_TOL) .AND. est(r) <= LZ_TOL_MAX*theta(nb + 1 - r)
        END DO
        IF (conv) THEN
          IF (nb == nf) THEN
            ! a complete basis: its Ritz values are the eigenvalues
            ok = .TRUE.
          ELSE
            ! the first gap above the wanted values with every Ritz value below it converged
            DO k = nwant, nb - 1
              IF (k > nwant .AND. .NOT. converged_ritz(k, LZ_TOL_GUARD)) EXIT
              IF (.NOT. theta(nb - k) > CD_ZERO) EXIT
              IF (lam(k + 1) - lam(k) >= LZ_GAP*lam(k + 1)) THEN
                sigma = 0.5_wp*(lam(k) + lam(k + 1))
                ok = sturm_count(ac, bc, kc, sigma) == k
                EXIT
              END IF
            END DO
          END IF
          IF (ok) THEN
            w(1:nwant) = lam(1:nwant)
            RETURN
          END IF
        END IF
      END IF
      IF (nb >= mmax .OR. nb == nf) RETURN

      ! the next block: the projected wb, M-orthonormalised (a column that has vanished, an
      ! invariant subspace, is replaced by a fresh pseudo-random vector)
      pn = MIN(LZ_BLOCK, nf - nb, mmax - nb, pb)
      nnew = nb
      DO j = 1, pn
        y = wb(:, j)
        CALL append(nnew + 1, ref(j), good)
        IF (.NOT. good) THEN
          CALL random_vector(nb + LZ_BLOCK + 1)
          CALL append(1, SQRT(SUM(y*y)), good)
          IF (.NOT. good) RETURN
        END IF
      END DO
      c0 = nnew
    END DO

  CONTAINS

    LOGICAL FUNCTION converged_ritz(r, tol) RESULT(yes)
      !! Ritz value r (ascending) converged to tol relative to its theta, or to round-off of
      !! the largest theta.
      INTEGER, INTENT(IN) :: r
      REAL(wp), INTENT(IN) :: tol
      yes = theta(nb + 1 - r) > CD_ZERO .AND. est(r) <= MAX(tol*theta(nb + 1 - r), LZ_FLOOR*thmax)
    END FUNCTION converged_ritz

    SUBROUTINE random_vector(stream)
      !! y: a deterministic pseudo-random vector of the given stream.
      INTEGER, INTENT(IN) :: stream
      INTEGER :: ir
      seed = 24680_I8 + 7919_I8*INT(stream, I8)
      DO ir = 1, nf
        seed = MOD(69069_I8*seed + 1_I8, 2147483647_I8)
        y(ir) = REAL(seed, wp)/2147483647.0_wp - 0.5_wp
      END DO
    END SUBROUTINE random_vector

    SUBROUTINE append(lo, yref, good)
      !! y orthogonalised (two passes) against the basis vectors lo..nb, M-normalised and
      !! appended; good is false when it has vanished against its reference norm yref.
      INTEGER, INTENT(IN) :: lo
      REAL(wp), INTENT(IN) :: yref
      LOGICAL, INTENT(OUT) :: good
      INTEGER :: ip
      REAL(wp) :: nrm2
      good = .FALSE.
      DO ip = 1, 2
        IF (nb < lo) EXIT
        cc(1:nb - lo + 1) = MATMUL(TRANSPOSE(mv(:, lo:nb)), y)
        y = y - MATMUL(v(:, lo:nb), cc(1:nb - lo + 1))
      END DO
      CALL sym_band_mv(bc, kc, y, my)
      nrm2 = DOT_PRODUCT(y, my)
      IF (.NOT. (nrm2 > CD_ZERO .AND. SQRT(SUM(y*y)) > LZ_BREAK*yref .AND. nrm2 <= HUGE(nrm2))) RETURN
      nb = nb + 1
      v(:, nb) = y/SQRT(nrm2)
      mv(:, nb) = my/SQRT(nrm2)
      good = .TRUE.
    END SUBROUTINE append

  END SUBROUTINE lanczos_lowest

  INTEGER FUNCTION sturm_count(ac, bc, kc, sigma) RESULT(cnt)
    !! The number of eigenvalues of K x = lambda M x below sigma, K and M symmetric in upper
    !! band storage of half-bandwidth kc and M positive definite: by Sylvester's law of
    !! inertia, the number of negative pivots of the LDL^T factorisation of K - sigma M
    !! without pivoting (which keeps the band). -1 when a pivot is zero or not finite.
    REAL(wp), INTENT(IN) :: ac(:, :), bc(:, :), sigma
    INTEGER, INTENT(IN) :: kc
    REAL(wp), ALLOCATABLE :: a(:, :)
    REAL(wp) :: d, f
    INTEGER :: nf, k, i, j
    nf = SIZE(ac, 2)
    ALLOCATE (a(kc + 1, nf))
    a = ac - sigma*bc
    cnt = 0
    DO k = 1, nf
      d = a(kc + 1, k)
      IF (.NOT. (ABS(d) > CD_ZERO .AND. ABS(d) <= HUGE(d))) THEN
        cnt = -1
        RETURN
      END IF
      IF (d < CD_ZERO) cnt = cnt + 1
      ! the trailing block of the band: a(i, j) -= a(k, i) a(k, j) / d, k < i <= j <= k + kc
      DO j = k + 1, MIN(nf, k + kc)
        f = a(kc + 1 + k - j, j)/d
        DO i = k + 1, j
          a(kc + 1 + i - j, j) = a(kc + 1 + i - j, j) - f*a(kc + 1 + k - i, i)
        END DO
      END DO
    END DO
  END FUNCTION sturm_count

  SUBROUTINE CD_Modal_Solve(K, M, free, n_modes, omega2, shapes, n_found, ErrStat, ErrMsg)
    !! Dense reference solver: the n_modes lowest eigenpairs of K phi = omega^2 M phi on the
    !! free DOFs (DSYGV, symmetric parts of K and M), for lines of at most 4000 free DOFs.
    !! shapes(:, j) is the full-length mode vector (zero on the held DOFs), M-orthonormal on
    !! the free DOFs. A negative omega2 (an unstable or compressed state) is returned as
    !! computed. Production runs use CD_Modal_Solve_Band.
    REAL(wp), INTENT(IN) :: K(:, :), M(:, :)
    LOGICAL, INTENT(IN) :: free(:)
    INTEGER, INTENT(IN) :: n_modes
    REAL(wp), INTENT(OUT) :: omega2(:), shapes(:, :)
    INTEGER, INTENT(OUT) :: n_found, ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n, nf, i, j, ii, jj, info, lwork
    INTEGER, ALLOCATABLE :: map(:)
    REAL(wp), ALLOCATABLE :: a(:, :), b(:, :), w(:), work(:)
    REAL(wp) :: wq(1)
    EXTERNAL :: dsygv

    ErrStat = CD_MODAL_OK
    ErrMsg = ''
    omega2 = CD_ZERO
    shapes = CD_ZERO
    n_found = 0
    n = SIZE(free)
    IF (SIZE(K, 1) /= n .OR. SIZE(K, 2) /= n .OR. SIZE(M, 1) /= n .OR. SIZE(M, 2) /= n .OR. &
        SIZE(shapes, 1) /= n .OR. SIZE(shapes, 2) < n_modes .OR. SIZE(omega2) < n_modes .OR. n_modes < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'inconsistent modal array sizes')
      RETURN
    END IF
    nf = COUNT(free)
    IF (nf < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'the line has no free degree of freedom')
      RETURN
    END IF
    IF (nf > DENSE_MAX_DOF) THEN
      CALL fail(ErrStat, ErrMsg, 'the line has more free DOFs than the dense reference solver takes (4000)')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(K) .AND. CD_All_Finite(M))) THEN
      CALL fail(ErrStat, ErrMsg, 'the stiffness or mass matrix is not finite')
      RETURN
    END IF
    ALLOCATE (map(nf), a(nf, nf), b(nf, nf), w(nf))
    j = 0
    DO i = 1, n
      IF (free(i)) THEN
        j = j + 1
        map(j) = i
      END IF
    END DO
    DO jj = 1, nf
      DO ii = 1, nf
        a(ii, jj) = 0.5_wp*(K(map(ii), map(jj)) + K(map(jj), map(ii)))
        b(ii, jj) = 0.5_wp*(M(map(ii), map(jj)) + M(map(jj), map(ii)))
      END DO
    END DO
    CALL dsygv(1, 'V', 'U', nf, a, nf, b, nf, w, wq, -1, info)
    lwork = MAX(1, INT(wq(1)), 3*nf)
    ALLOCATE (work(lwork))
    CALL dsygv(1, 'V', 'U', nf, a, nf, b, nf, w, work, lwork, info)
    IF (info /= 0) THEN
      ErrStat = CD_MODAL_FAIL
      IF (info > nf) THEN
        ErrMsg = 'CableDyn_Modal: the mass matrix is not positive definite (DSYGV)'
      ELSE
        BLOCK
          ! Local buffer: a record longer than the caller's ErrMsg truncates
          ! instead of aborting the internal write.
          CHARACTER(1024) :: wmsg
          INTEGER :: wios
          wmsg = ''
          WRITE (wmsg, '(A,I0)', IOSTAT=wios) 'CableDyn_Modal: DSYGV failed, INFO = ', info
          ErrMsg = wmsg
        END BLOCK
      END IF
      RETURN
    END IF
    n_found = MIN(n_modes, nf)
    DO j = 1, n_found
      omega2(j) = w(j)
      shapes(map, j) = a(:, j)
    END DO
  END SUBROUTINE CD_Modal_Solve

  SUBROUTINE CD_Modal_Write_Header(unit)
    !! The two-table header of <root>.modes.out; the frequency rows of every line follow,
    !! then CD_Modal_Write_Line appends each line's shape rows under a second header.
    INTEGER, INTENT(IN) :: unit
    WRITE (unit, '(A)') '# CableDyn modal analysis about the static equilibrium: K phi = omega^2 M phi '// &
      '(static tangent, structural + added mass, fixed and prescribed ends held)'
  END SUBROUTINE CD_Modal_Write_Header

  SUBROUTINE CD_Modal_Write_Line(unit, line_id, q, dof_per_node, omega2, shapes, n_found, part, polar)
    !! part = 1: the frequency rows "LineID Mode Frequency Period Omega"; part = 2: the
    !! shape rows "LineID Mode Node X Y Z dX dY dZ", the nodal translations of each mode
    !! scaled to a unit largest nodal displacement (the static position X Y Z beside it).
    !! A negative omega^2 is written with a negative frequency and period 0. With polar (the
    !! twist columns of a file holding a line with twist): the frequency rows add the polar
    !! share of each mode, the shape rows the nodal twist dTwist (the 7th DOF of a node when
    !! dof_per_node = 7, else 0) on the same scale; a mode whose kinetic energy is mostly polar
    !! (share above 1/2, a torsional mode) is scaled to a unit largest nodal twist instead.
    INTEGER, INTENT(IN) :: unit, line_id, dof_per_node, n_found, part
    REAL(wp), INTENT(IN) :: q(:), omega2(:), shapes(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: polar(:)
    INTEGER :: j, i, nn, i0
    REAL(wp) :: om, fr, per, scl, dmax, tw
    CHARACTER(1), PARAMETER :: TB = ACHAR(9)
    nn = SIZE(q)/dof_per_node
    DO j = 1, n_found
      IF (part == 1) THEN
        om = SIGN(SQRT(ABS(omega2(j))), omega2(j))
        fr = om/TWO_PI
        per = CD_ZERO
        IF (om > CD_ZERO) per = CD_ONE/fr
        IF (PRESENT(polar)) THEN
          WRITE (unit, '(I0,A,I0,4(A,ES16.8E3))') line_id, TB, j, TB, fr, TB, per, TB, om, TB, polar(j)
        ELSE
          WRITE (unit, '(I0,A,I0,3(A,ES16.8E3))') line_id, TB, j, TB, fr, TB, per, TB, om
        END IF
      ELSE
        dmax = CD_ZERO
        IF (PRESENT(polar) .AND. dof_per_node == 7) THEN
          IF (polar(j) > 0.5_wp) dmax = MAXVAL(ABS(shapes(7:7*nn:7, j)))
        END IF
        IF (.NOT. dmax > CD_ZERO) THEN
          DO i = 1, nn
            i0 = dof_per_node*(i - 1)
            dmax = MAX(dmax, SQRT(SUM(shapes(i0 + 1:i0 + 3, j)**2)))
          END DO
        END IF
        scl = CD_ONE
        IF (dmax > CD_ZERO) scl = CD_ONE/dmax
        DO i = 1, nn
          i0 = dof_per_node*(i - 1)
          IF (PRESENT(polar)) THEN
            tw = CD_ZERO
            IF (dof_per_node == 7) tw = scl*shapes(i0 + 7, j)
            WRITE (unit, '(I0,A,I0,A,I0,7(A,ES16.8E3))') line_id, TB, j, TB, i, TB, q(i0 + 1), TB, q(i0 + 2), &
              TB, q(i0 + 3), TB, scl*shapes(i0 + 1, j), TB, scl*shapes(i0 + 2, j), TB, scl*shapes(i0 + 3, j), TB, tw
          ELSE
            WRITE (unit, '(I0,A,I0,A,I0,6(A,ES16.8E3))') line_id, TB, j, TB, i, TB, q(i0 + 1), TB, q(i0 + 2), &
              TB, q(i0 + 3), TB, scl*shapes(i0 + 1, j), TB, scl*shapes(i0 + 2, j), TB, scl*shapes(i0 + 3, j)
          END IF
        END DO
      END IF
    END DO
  END SUBROUTINE CD_Modal_Write_Line

END MODULE CableDyn_Modal
