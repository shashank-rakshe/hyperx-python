! File: src/CableDyn_Banner.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Banner
  !! The CableDyn startup identity banner for the standalone driver (app/cabledyn.f90),
  !! so a user on any machine sees what -- and whose -- solver is running when they invoke
  !! CableDyn as its own program. Inside OpenFAST the CompMooring=5 module announces itself
  !! the ecosystem way instead (DispNVD one-line version banner + WrScr identity lines, cf.
  !! MoorDyn.f90 Init), so this box is not used there. The lines are exposed one at a time in
  !! case a caller wants to route them through its own writer.
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: output_unit
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: CD_BANNER_NLINE, CD_Banner_Line, CD_Print_Banner

  INTEGER, PARAMETER :: CD_BANNER_NLINE = 9

CONTAINS

  PURE FUNCTION CD_Banner_Line(i) RESULT(s)
    !! Line i of the banner (1 .. CD_BANNER_NLINE); an empty string outside that range.
    INTEGER, INTENT(IN) :: i
    CHARACTER(:), ALLOCATABLE :: s
    SELECT CASE (i)
    CASE (1)
      s = ' ==================================================================='
    CASE (2)
      s = '   CableDyn  v0.4.2'
    CASE (3)
      s = '   Geometrically exact finite-element statics and dynamics of'
    CASE (4)
      s = '   mooring lines and dynamic power cables for floating offshore wind'
    CASE (5)
      s = ' -------------------------------------------------------------------'
    CASE (6)
      s = '   Author    Prof. Jae Hoon Seo'
    CASE (7)
      s = '   Affil.    Inha University, Republic of Korea'
    CASE (8)
      s = '   License   Apache-2.0     github.com/SMI-Lab-Inha/CableDyn'
    CASE (9)
      s = ' ==================================================================='
    CASE DEFAULT
      s = ''
    END SELECT
  END FUNCTION CD_Banner_Line

  SUBROUTINE CD_Print_Banner(unit)
    !! Write the whole banner to `unit` (default: standard output). Used by the standalone
    !! driver; the OpenFAST module announces itself through DispNVD and does not print this
    !! banner.
    INTEGER, INTENT(IN), OPTIONAL :: unit
    INTEGER :: u, i
    u = output_unit
    IF (PRESENT(unit)) u = unit
    DO i = 1, CD_BANNER_NLINE
      WRITE (u, '(A)') CD_Banner_Line(i)
    END DO
  END SUBROUTINE CD_Print_Banner

END MODULE CableDyn_Banner
