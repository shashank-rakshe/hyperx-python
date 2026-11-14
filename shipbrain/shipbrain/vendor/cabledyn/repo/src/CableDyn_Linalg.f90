! File: src/CableDyn_Linalg.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Linalg
  !! Small LAPACK helpers for the Fortran core: banded factorization and solves
  !! (DGBTRF/DGBTRS, DGBSV, DGBSVX), and the dense-assembly reference path that
  !! packs an already-assembled dense free-DOF block into LAPACK general-band storage
  !! and solves it with DGBSV (CD_Solve_Dense_As_Banded), used by the secondary Cosserat
  !! solvers and the tests.
  !!
  !! Reference: LAPACK Users' Guide, DGBSV general band solver storage convention.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_All_Finite, CD_Is_Finite
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_CHAR, C_INT, C_NULL_CHAR
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_LINALG_OK, CD_LINALG_BADINPUT, CD_LINALG_SINGULAR, CD_LINALG_BLAS_UNAVAILABLE
  PUBLIC :: CD_BLAS_UNAVAILABLE_INFO
  PUBLIC :: CD_Solve_Dense_As_Banded, CD_Solve_Dense_As_Banded_Multiple, CD_Solve_Banded
  PUBLIC :: CD_Solve_Banded_Refined
  PUBLIC :: CD_Factor_Banded, CD_Solve_Factored_Banded, CD_Solve_Factored_Banded_Multiple
  PUBLIC :: CD_Blas_Runtime_Check

  INTEGER, PARAMETER :: CD_LINALG_OK = 0
  INTEGER, PARAMETER :: CD_LINALG_BADINPUT = 1
  INTEGER, PARAMETER :: CD_LINALG_SINGULAR = 2
  !! The LAPACK runtime could not be loaded (see CD_Blas_Runtime_Check).
  INTEGER, PARAMETER :: CD_LINALG_BLAS_UNAVAILABLE = 3
  !! INFO returned by every LAPACK routine that src/cabledyn_blas.c forwards when the
  !! run-time loaded OpenBLAS is unavailable (CABLEDYN_BLAS_UNAVAILABLE_INFO there).
  INTEGER, PARAMETER :: CD_BLAS_UNAVAILABLE_INFO = -1000

  INTERFACE
    ! Returns 0 when the LAPACK runtime is usable. Otherwise returns 1 and writes a
    ! null-terminated diagnostic, naming `requester`, the library, the locations tried,
    ! and the load error, to msg(1:msg_len) (src/cabledyn_blas.c).
    FUNCTION cabledyn_blas_runtime_status(requester, msg, msg_len) RESULT(failed) &
      BIND(C, NAME='cabledyn_blas_runtime_status')
      IMPORT :: C_CHAR, C_INT
      CHARACTER(KIND=C_CHAR), INTENT(IN) :: requester(*)
      CHARACTER(KIND=C_CHAR), INTENT(OUT) :: msg(*)
      INTEGER(C_INT), VALUE :: msg_len
      INTEGER(C_INT) :: failed
    END FUNCTION cabledyn_blas_runtime_status
  END INTERFACE

CONTAINS

  SUBROUTINE CD_Solve_Dense_As_Banded(A, rhs, ErrStat, ErrMsg, kl_out, ku_out)
    !! Solve A x = rhs by detecting the occupied bandwidth of dense A, packing it
    !! into LAPACK DGBSV storage, and overwriting rhs with x. This keeps the
    !! existing dense assemblers as the correctness anchor while replacing the
    !! dense O(n^3) free-block factorisation with a banded solve.
    REAL(wp), INTENT(IN) :: A(:, :)
    REAL(wp), INTENT(INOUT) :: rhs(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(OUT), OPTIONAL :: kl_out, ku_out

    INTEGER :: n, i, j, kl, ku, ldab, row, info
    INTEGER, ALLOCATABLE :: ipiv(:)
    REAL(wp), ALLOCATABLE :: ab(:, :)
    EXTERNAL :: dgbsv

    ErrStat = CD_LINALG_OK; ErrMsg = ''
    IF (PRESENT(kl_out)) kl_out = 0
    IF (PRESENT(ku_out)) ku_out = 0

    n = SIZE(rhs)
    IF (SIZE(A, 1) /= n .OR. SIZE(A, 2) /= n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Dense_As_Banded: A must be square with size(rhs)'
      RETURN
    END IF
    IF (n == 0) RETURN
    IF (.NOT. CD_All_Finite(A) .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Dense_As_Banded: A and rhs must be finite'
      RETURN
    END IF

    kl = 0; ku = 0
    DO j = 1, n
      DO i = 1, n
        IF (ABS(A(i, j)) > CD_ZERO) THEN
          IF (i > j) kl = MAX(kl, i - j)
          IF (j > i) ku = MAX(ku, j - i)
        END IF
      END DO
    END DO
    IF (PRESENT(kl_out)) kl_out = kl
    IF (PRESENT(ku_out)) ku_out = ku

    ldab = 2*kl + ku + 1
    ALLOCATE (ab(ldab, n), ipiv(n))
    ab = CD_ZERO
    DO j = 1, n
      DO i = MAX(1, j - ku), MIN(n, j + kl)
        row = kl + ku + 1 + i - j
        ab(row, j) = A(i, j)
      END DO
    END DO

    CALL dgbsv(n, kl, ku, 1, ab, ldab, ipiv, rhs, n, info)
    IF (info /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_SINGULAR
      ErrMsg = 'CD_Solve_Dense_As_Banded: DGBSV reported a singular or ill-conditioned banded system'
      CALL map_blas_unavailable('DGBSV', info, ErrStat, ErrMsg)
      RETURN
    END IF
  END SUBROUTINE CD_Solve_Dense_As_Banded

  SUBROUTINE CD_Solve_Dense_As_Banded_Multiple(A, rhs, ErrStat, ErrMsg, kl_out, ku_out)
    !! Solve A X = RHS for multiple right-hand sides by detecting the occupied
    !! dense bandwidth, packing once into LAPACK DGBSV storage, and overwriting
    !! RHS with X. This avoids repeated band detection/factorization for reduced
    !! coupling Jacobian blocks.
    REAL(wp), INTENT(IN) :: A(:, :)
    REAL(wp), INTENT(INOUT) :: rhs(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(OUT), OPTIONAL :: kl_out, ku_out

    INTEGER :: n, nrhs, i, j, kl, ku, ldab, row, info
    INTEGER, ALLOCATABLE :: ipiv(:)
    REAL(wp), ALLOCATABLE :: ab(:, :)
    EXTERNAL :: dgbsv

    ErrStat = CD_LINALG_OK; ErrMsg = ''
    IF (PRESENT(kl_out)) kl_out = 0
    IF (PRESENT(ku_out)) ku_out = 0

    n = SIZE(rhs, 1)
    nrhs = SIZE(rhs, 2)
    IF (SIZE(A, 1) /= n .OR. SIZE(A, 2) /= n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Dense_As_Banded_Multiple: A must be square with size(rhs,1)'
      RETURN
    END IF
    IF (n == 0 .OR. nrhs == 0) RETURN
    IF (.NOT. CD_All_Finite(A) .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Dense_As_Banded_Multiple: A and rhs must be finite'
      RETURN
    END IF

    kl = 0; ku = 0
    DO j = 1, n
      DO i = 1, n
        IF (ABS(A(i, j)) > CD_ZERO) THEN
          IF (i > j) kl = MAX(kl, i - j)
          IF (j > i) ku = MAX(ku, j - i)
        END IF
      END DO
    END DO
    IF (PRESENT(kl_out)) kl_out = kl
    IF (PRESENT(ku_out)) ku_out = ku

    ldab = 2*kl + ku + 1
    ALLOCATE (ab(ldab, n), ipiv(n))
    ab = CD_ZERO
    DO j = 1, n
      DO i = MAX(1, j - ku), MIN(n, j + kl)
        row = kl + ku + 1 + i - j
        ab(row, j) = A(i, j)
      END DO
    END DO

    CALL dgbsv(n, kl, ku, nrhs, ab, ldab, ipiv, rhs, n, info)
    IF (info /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_SINGULAR
      ErrMsg = 'CD_Solve_Dense_As_Banded_Multiple: DGBSV reported a singular or ill-conditioned banded system'
      CALL map_blas_unavailable('DGBSV', info, ErrStat, ErrMsg)
      RETURN
    END IF
  END SUBROUTINE CD_Solve_Dense_As_Banded_Multiple

  SUBROUTINE CD_Solve_Banded(ab, kl, ku, rhs, ErrStat, ErrMsg)
    !! Solve A x = rhs from LAPACK general-band storage AB, overwriting both the
    !! banded matrix (LU factors) and rhs (solution), exactly as DGBSV specifies.
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    REAL(wp), INTENT(INOUT) :: rhs(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, ldab, info
    INTEGER, ALLOCATABLE :: ipiv(:)
    EXTERNAL :: dgbsv

    ErrStat = CD_LINALG_OK; ErrMsg = ''
    n = SIZE(rhs)
    ldab = 2*kl + ku + 1
    IF (kl < 0 .OR. ku < 0) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Banded: kl and ku must be non-negative'
      RETURN
    END IF
    IF (SIZE(ab, 1) < ldab .OR. SIZE(ab, 2) /= n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Banded: AB must have shape (2*kl+ku+1, size(rhs))'
      RETURN
    END IF
    IF (n == 0) RETURN
    IF (.NOT. CD_All_Finite(ab) .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Banded: AB and rhs must be finite'
      RETURN
    END IF

    ALLOCATE (ipiv(n))
    CALL dgbsv(n, kl, ku, 1, ab, SIZE(ab, 1), ipiv, rhs, n, info)
    IF (info /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_SINGULAR
      ErrMsg = 'CD_Solve_Banded: DGBSV reported a singular or ill-conditioned banded system'
      CALL map_blas_unavailable('DGBSV', info, ErrStat, ErrMsg)
      RETURN
    END IF
  END SUBROUTINE CD_Solve_Banded

  SUBROUTINE CD_Solve_Banded_Refined(ab, kl, ku, rhs, ErrStat, ErrMsg)
    !! Solve A x = rhs with LAPACK DGBSVX equilibration, condition estimation and
    !! iterative refinement. The input uses the same extended general-band layout
    !! as CD_Solve_Banded; it is preserved so DGBSVX can evaluate the backward error
    !! against the unfactored matrix. This costlier path is intended for bounded
    !! nonlinear-solver recovery rather than ordinary time stepping.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    REAL(wp), INTENT(INOUT) :: rhs(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, ldab, ldab_compact, info, i, j
    INTEGER, ALLOCATABLE :: ipiv(:), iwork(:)
    REAL(wp) :: rcond
    REAL(wp), ALLOCATABLE :: ab_compact(:, :), afb(:, :), row_scale(:), column_scale(:)
    REAL(wp), ALLOCATABLE :: b(:, :), x(:, :), ferr(:), berr(:), work(:)
    CHARACTER(1) :: equed
    EXTERNAL :: dgbsvx

    ErrStat = CD_LINALG_OK; ErrMsg = ''
    n = SIZE(rhs)
    ldab = 2*kl + ku + 1
    ldab_compact = kl + ku + 1
    IF (kl < 0 .OR. ku < 0) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Banded_Refined: kl and ku must be non-negative'
      RETURN
    END IF
    IF (SIZE(ab, 1) < ldab .OR. SIZE(ab, 2) /= n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Banded_Refined: AB must have shape (2*kl+ku+1, size(rhs))'
      RETURN
    END IF
    IF (n == 0) RETURN
    IF (.NOT. CD_All_Finite(ab) .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Banded_Refined: AB and rhs must be finite'
      RETURN
    END IF

    ALLOCATE (ab_compact(ldab_compact, n), afb(ldab, n), ipiv(n), iwork(n))
    ALLOCATE (row_scale(n), column_scale(n), b(n, 1), x(n, 1), ferr(1), berr(1), work(3*n))
    ab_compact = CD_ZERO
    DO j = 1, n
      DO i = MAX(1, j - ku), MIN(n, j + kl)
        ab_compact(ku + 1 + i - j, j) = ab(kl + ku + 1 + i - j, j)
      END DO
    END DO
    afb = CD_ZERO
    b(:, 1) = rhs
    x = CD_ZERO
    equed = 'N'
    CALL dgbsvx('E', 'N', n, kl, ku, 1, ab_compact, ldab_compact, afb, ldab, ipiv, equed, &
                row_scale, column_scale, b, n, x, n, rcond, ferr, berr, work, iwork, info)
    IF (info /= 0 .OR. .NOT. CD_Is_Finite(rcond) .OR. .NOT. CD_All_Finite(x) .OR. &
        .NOT. CD_All_Finite(ferr) .OR. .NOT. CD_All_Finite(berr)) THEN
      ErrStat = CD_LINALG_SINGULAR
      ErrMsg = 'CD_Solve_Banded_Refined: DGBSVX reported a singular or ill-conditioned banded system'
      CALL map_blas_unavailable('DGBSVX', info, ErrStat, ErrMsg)
      RETURN
    END IF
    rhs = x(:, 1)
  END SUBROUTINE CD_Solve_Banded_Refined

  SUBROUTINE CD_Factor_Banded(ab, kl, ku, ipiv, ErrStat, ErrMsg, matrix_validated)
    !! Factor a LAPACK general-band matrix in-place using DGBTRF. Pair with
    !! CD_Solve_Factored_Banded to reuse a modified-Newton effective tangent
    !! without refactorizing the same matrix for every stale iteration.
    !! `matrix_validated` skips only the redundant input finiteness scan; factor output is
    !! still checked before success. The default remains fully defensive.
    REAL(wp), INTENT(INOUT) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    INTEGER, INTENT(INOUT) :: ipiv(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: matrix_validated

    INTEGER :: n, ldab, info
    LOGICAL :: trust_matrix
    EXTERNAL :: dgbtrf

    ErrStat = CD_LINALG_OK; ErrMsg = ''
    trust_matrix = .FALSE.
    IF (PRESENT(matrix_validated)) trust_matrix = matrix_validated
    n = SIZE(ab, 2)
    ldab = 2*kl + ku + 1
    IF (kl < 0 .OR. ku < 0) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Factor_Banded: kl and ku must be non-negative'
      RETURN
    END IF
    IF (SIZE(ab, 1) < ldab) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Factor_Banded: AB must have at least 2*kl+ku+1 rows'
      RETURN
    END IF
    IF (SIZE(ipiv) < n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Factor_Banded: ipiv must have length at least size(AB,2)'
      RETURN
    END IF
    IF (n == 0) RETURN
    ! Do not rely on non-standard short-circuit evaluation to elide this full-band scan.
    IF (.NOT. trust_matrix) THEN
      IF (.NOT. CD_All_Finite(ab)) THEN
        ErrStat = CD_LINALG_BADINPUT
        ErrMsg = 'CD_Factor_Banded: AB must be finite'
        RETURN
      END IF
    END IF

    CALL dgbtrf(n, n, kl, ku, ab, SIZE(ab, 1), ipiv, info)
    IF (info /= 0 .OR. .NOT. CD_All_Finite(ab)) THEN
      ErrStat = CD_LINALG_SINGULAR
      ErrMsg = 'CD_Factor_Banded: DGBTRF reported a singular or ill-conditioned banded system'
      CALL map_blas_unavailable('DGBTRF', info, ErrStat, ErrMsg)
      RETURN
    END IF
  END SUBROUTINE CD_Factor_Banded

  SUBROUTINE CD_Solve_Factored_Banded(ab_lu, kl, ku, ipiv, rhs, ErrStat, ErrMsg, factor_validated)
    !! Solve A x = rhs from a DGBTRF-factored general-band matrix, overwriting rhs
    !! with x. The factorization is not modified, so callers can reuse it for
    !! repeated modified-Newton solves with the same effective tangent.
    !! `factor_validated` is for an immutable LU returned successfully by
    !! CD_Factor_Banded; RHS input and solution output remain checked for finiteness.
    REAL(wp), INTENT(IN) :: ab_lu(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    INTEGER, INTENT(IN) :: ipiv(:)
    REAL(wp), INTENT(INOUT) :: rhs(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL, INTENT(IN), OPTIONAL :: factor_validated

    INTEGER :: n, ldab, info
    LOGICAL :: trust_factor
    EXTERNAL :: dgbtrs

    ErrStat = CD_LINALG_OK; ErrMsg = ''
    trust_factor = .FALSE.
    IF (PRESENT(factor_validated)) trust_factor = factor_validated
    n = SIZE(rhs)
    ldab = 2*kl + ku + 1
    IF (kl < 0 .OR. ku < 0) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded: kl and ku must be non-negative'
      RETURN
    END IF
    IF (SIZE(ab_lu, 1) < ldab .OR. SIZE(ab_lu, 2) /= n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded: AB_LU must have shape (2*kl+ku+1, size(rhs))'
      RETURN
    END IF
    IF (SIZE(ipiv) < n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded: ipiv must have length at least size(rhs)'
      RETURN
    END IF
    IF (n == 0) RETURN
    ! The immutable-factor fast path must skip the O(n*bandwidth) scan even on Debug
    ! compilers that eagerly evaluate every logical operand. RHS remains checked always.
    IF (.NOT. trust_factor) THEN
      IF (.NOT. CD_All_Finite(ab_lu)) THEN
        ErrStat = CD_LINALG_BADINPUT
        ErrMsg = 'CD_Solve_Factored_Banded: AB_LU and rhs must be finite'
        RETURN
      END IF
    END IF
    IF (.NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded: AB_LU and rhs must be finite'
      RETURN
    END IF

    CALL dgbtrs('N', n, kl, ku, 1, ab_lu, SIZE(ab_lu, 1), ipiv, rhs, n, info)
    IF (info /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_SINGULAR
      ErrMsg = 'CD_Solve_Factored_Banded: DGBTRS reported a singular or ill-conditioned banded system'
      CALL map_blas_unavailable('DGBTRS', info, ErrStat, ErrMsg)
      RETURN
    END IF
  END SUBROUTINE CD_Solve_Factored_Banded

  SUBROUTINE CD_Solve_Factored_Banded_Multiple(ab_lu, kl, ku, ipiv, rhs, ErrStat, ErrMsg)
    !! Solve A X = RHS for every column of RHS from a DGBTRF-factored general-band
    !! matrix (one DGBTRS call), overwriting RHS with X. The factorization is not
    !! modified. RHS input and solution output are checked for finiteness.
    REAL(wp), INTENT(IN) :: ab_lu(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    INTEGER, INTENT(IN) :: ipiv(:)
    REAL(wp), INTENT(INOUT) :: rhs(:, :)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, nrhs, ldab, info
    EXTERNAL :: dgbtrs

    ErrStat = CD_LINALG_OK; ErrMsg = ''
    n = SIZE(rhs, 1)
    nrhs = SIZE(rhs, 2)
    ldab = 2*kl + ku + 1
    IF (kl < 0 .OR. ku < 0) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded_Multiple: kl and ku must be non-negative'
      RETURN
    END IF
    IF (SIZE(ab_lu, 1) < ldab .OR. SIZE(ab_lu, 2) /= n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded_Multiple: AB_LU must have shape (2*kl+ku+1, size(rhs,1))'
      RETURN
    END IF
    IF (SIZE(ipiv) < n) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded_Multiple: ipiv must have length at least size(rhs,1)'
      RETURN
    END IF
    IF (n == 0 .OR. nrhs == 0) RETURN
    IF (.NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_BADINPUT
      ErrMsg = 'CD_Solve_Factored_Banded_Multiple: rhs must be finite'
      RETURN
    END IF

    CALL dgbtrs('N', n, kl, ku, nrhs, ab_lu, SIZE(ab_lu, 1), ipiv, rhs, n, info)
    IF (info /= 0 .OR. .NOT. CD_All_Finite(rhs)) THEN
      ErrStat = CD_LINALG_SINGULAR
      ErrMsg = 'CD_Solve_Factored_Banded_Multiple: DGBTRS reported a singular or ill-conditioned banded system'
      CALL map_blas_unavailable('DGBTRS', info, ErrStat, ErrMsg)
      RETURN
    END IF
  END SUBROUTINE CD_Solve_Factored_Banded_Multiple

  SUBROUTINE CD_Blas_Runtime_Check(requester, ErrStat, ErrMsg)
    !! Fail closed when the LAPACK runtime is unavailable. In the Windows GNU build
    !! CableDyn loads openblas.dll on first use (src/cabledyn_blas.c); this triggers
    !! that load and, when it fails, returns CD_LINALG_BLAS_UNAVAILABLE with a message
    !! naming `requester`, the library, the locations tried, and the load error.
    !! Elsewhere LAPACK is linked and this always succeeds.
    CHARACTER(*), INTENT(IN) :: requester
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER, PARAMETER :: MSG_CAP = 2048
    CHARACTER(KIND=C_CHAR) :: buf(MSG_CAP)
    INTEGER :: i, n

    ErrStat = CD_LINALG_OK
    ErrMsg = ''
    buf = C_NULL_CHAR
    IF (cabledyn_blas_runtime_status(TRIM(requester)//C_NULL_CHAR, buf, INT(MSG_CAP, C_INT)) == 0_C_INT) RETURN
    ErrStat = CD_LINALG_BLAS_UNAVAILABLE
    n = 0
    DO i = 1, MSG_CAP
      IF (buf(i) == C_NULL_CHAR) EXIT
      n = i
    END DO
    DO i = 1, MIN(n, LEN(ErrMsg))
      ErrMsg(i:i) = buf(i)
    END DO
    IF (n == 0) ErrMsg = TRIM(requester)//': the LAPACK runtime could not be loaded'
  END SUBROUTINE CD_Blas_Runtime_Check

  SUBROUTINE map_blas_unavailable(routine, info, ErrStat, ErrMsg)
    !! Replace a LAPACK failure report by the load diagnostic when the forwarded
    !! routine returned CD_BLAS_UNAVAILABLE_INFO (the runtime was never loaded).
    CHARACTER(*), INTENT(IN) :: routine
    INTEGER, INTENT(IN) :: info
    INTEGER, INTENT(INOUT) :: ErrStat
    CHARACTER(*), INTENT(INOUT) :: ErrMsg

    INTEGER :: es
    CHARACTER(LEN(ErrMsg)) :: em

    IF (info /= CD_BLAS_UNAVAILABLE_INFO) RETURN
    CALL CD_Blas_Runtime_Check(routine, es, em)
    IF (es == CD_LINALG_OK) RETURN
    ErrStat = es
    ErrMsg = em
  END SUBROUTINE map_blas_unavailable

END MODULE CableDyn_Linalg
