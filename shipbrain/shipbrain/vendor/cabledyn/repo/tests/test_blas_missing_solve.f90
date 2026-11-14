! File: tests/test_blas_missing_solve.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_blas_missing_solve
  !! Run by tests/check_blas_missing_runtime.cmake from a directory without
  !! openblas.dll: a banded solve (DGBSV) and a banded factorisation (DGBTRF) that
  !! bypass model initialisation must report the load failure, not a singular system.
  !! Prints each status and message; the script asserts on them.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Linalg, ONLY: CD_Solve_Banded, CD_Factor_Banded
  IMPLICIT NONE

  REAL(wp) :: ab(4, 3), rhs(3)
  INTEGER :: ipiv(3), es
  CHARACTER(2048) :: em

  ab = 0.0_wp
  ab(3, :) = 2.0_wp
  ab(2, 2:3) = -1.0_wp
  ab(4, 1:2) = -1.0_wp
  rhs = 1.0_wp
  CALL CD_Solve_Banded(ab, 1, 1, rhs, es, em)
  WRITE (*, '(A,I0)') 'solve status: ', es
  WRITE (*, '(A,A)') 'solve message: ', TRIM(em)
  CALL CD_Factor_Banded(ab, 1, 1, ipiv, es, em)
  WRITE (*, '(A,I0)') 'factor status: ', es
  WRITE (*, '(A,A)') 'factor message: ', TRIM(em)
END PROGRAM test_blas_missing_solve
