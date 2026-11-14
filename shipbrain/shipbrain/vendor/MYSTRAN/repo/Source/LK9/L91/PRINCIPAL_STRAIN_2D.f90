! ##################################################################################################################################
! Begin MIT license text.
! _______________________________________________________________________________________________________

! Copyright 2022 Dr William R Case, Jr (mystransolver@gmail.com)

! Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
! associated documentation files (the "Software"), to deal in the Software without restriction, including
! without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
! copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to
! the following conditions:

! The above copyright notice and this permission notice shall be included in all copies or substantial
! portions of the Software and documentation.

! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
! OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
! THE SOFTWARE.
! _______________________________________________________________________________________________________

! End MIT license text.

      SUBROUTINE PRINCIPAL_STRAIN_2D ( SX, SY, SXY, ANGLE, SMAJOR, SMINOR, SXYMAX, MEAN, VONMISES )

! Calculates principal strains for 2-D shell elems:

      USE PENTIUM_II_KIND, ONLY       :  DOUBLE
      USE CONSTANTS_1, ONLY           :  HALF, CONV_RAD_DEG

      IMPLICIT NONE

      REAL(DOUBLE), INTENT(IN)        :: SX                 ! Normal x strain
      REAL(DOUBLE), INTENT(IN)        :: SY                 ! Normal y strain
      REAL(DOUBLE), INTENT(IN)        :: SXY                ! Shear strain
      REAL(DOUBLE), INTENT(OUT)       :: ANGLE              ! Angle of principal strain
      REAL(DOUBLE), INTENT(OUT)       :: MEAN               ! Mean strain
      REAL(DOUBLE), INTENT(OUT)       :: SMAJOR             ! Major principal strain
      REAL(DOUBLE), INTENT(OUT)       :: SMINOR             ! Minor principal strain
      REAL(DOUBLE), INTENT(OUT)       :: SXYMAX             ! Max shear strain
      REAL(DOUBLE), INTENT(OUT)       :: VONMISES           ! von Mises strain

      INTRINSIC                       :: DATAN2, DSQRT


! **********************************************************************************************************************************

      ANGLE = (HALF*DATAN2(SXY,SX - SY))*CONV_RAD_DEG
      SXYMAX = DSQRT((SX - SY)**2 + SXY**2)
      MEAN   = HALF*(SX + SY)
      SMAJOR = MEAN + SXYMAX / 2
      SMINOR = MEAN - SXYMAX / 2
      VONMISES = DSQRT(4.0 / 9.0 * (SX**2 + SY**2 -SX*SY) + 1.0/3.0 * SXY**2)

      RETURN

! **********************************************************************************************************************************

      END SUBROUTINE PRINCIPAL_STRAIN_2D
