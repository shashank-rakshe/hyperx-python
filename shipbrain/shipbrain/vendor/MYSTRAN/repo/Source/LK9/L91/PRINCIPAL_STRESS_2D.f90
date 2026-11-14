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

      SUBROUTINE PRINCIPAL_STRESS_2D ( SX, SY, SXY, ANGLE, SMAJOR, SMINOR, SXYMAX, MEAN, VONMISES )

! Calculates principal stresses for 2-D shell elems:

      USE PENTIUM_II_KIND, ONLY       :  DOUBLE
      USE CONSTANTS_1, ONLY           :  ZERO, QUARTER, HALF, TWO, CONV_RAD_DEG

      IMPLICIT NONE

      REAL(DOUBLE), INTENT(IN)        :: SX                 ! Normal x stress
      REAL(DOUBLE), INTENT(IN)        :: SY                 ! Normal y stress
      REAL(DOUBLE), INTENT(IN)        :: SXY                ! Shear stress
      REAL(DOUBLE), INTENT(OUT)       :: ANGLE              ! Angle of principal stresses
      REAL(DOUBLE), INTENT(OUT)       :: MEAN               ! Mean stresses
      REAL(DOUBLE), INTENT(OUT)       :: SMAJOR             ! Major principal stress
      REAL(DOUBLE), INTENT(OUT)       :: SMINOR             ! Minor principal stress
      REAL(DOUBLE), INTENT(OUT)       :: SXYMAX             ! Max shear stress
      REAL(DOUBLE), INTENT(OUT)       :: VONMISES           ! von Mises stress
      REAL(DOUBLE)                    :: DENR               ! Denominator in arctan calculation of ANGLE
      REAL(DOUBLE)                    :: SAVG               ! Average of SX and SY
      REAL(DOUBLE)                    :: NUMR               ! Numerator in arctan calculation of ANGLE

      INTRINSIC                       :: DATAN2, DSQRT



! **********************************************************************************************************************************
! Initialize outputs

      ANGLE  = ZERO
      SMINOR = ZERO
      SXYMAX = ZERO

! Calc outputs

      DENR     = SX - SY
      NUMR     = TWO*SXY

! Calculate angle for principal axes.

      ANGLE = (HALF*DATAN2(NUMR,DENR))*CONV_RAD_DEG

! Calculate the principal stresses and max shear

      SXYMAX = DSQRT(QUARTER*DENR*DENR + SXY*SXY)
      SAVG   = HALF*(SX + SY)
      SMAJOR = SAVG + SXYMAX
      SMINOR = SAVG - SXYMAX

! Calculate mean andvon Mises stress for 2D stress state

      MEAN     = HALF*(SMAJOR + SMINOR)
      VONMISES = DSQRT( SMAJOR*SMAJOR - SMAJOR*SMINOR + SMINOR*SMINOR)

      RETURN

! **********************************************************************************************************************************

      END SUBROUTINE PRINCIPAL_STRESS_2D
