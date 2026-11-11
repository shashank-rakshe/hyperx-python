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

       SUBROUTINE RIGID_BODY_DISP_MAT ( GRD_COORDS, REF_COORDS, RB_DISP )

! Generates a set of 6 rigid body displacement vectors for the 6 displacement components for one grid. The rigid body displacements
! are relative to REF_GRID and are in basic coords

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE SCONTR, ONLY                :  BLNK_SUB_NAM
      USE TIMDAT, ONLY                :  TSEC
      USE CONSTANTS_1, ONLY           :  ZERO, ONE

      USE RIGID_BODY_DISP_MAT_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'RIGID_BODY_DISP_MAT'

      INTEGER(LONG)                   :: I,J               ! DO loop indices


      REAL(DOUBLE) , INTENT(IN)       :: GRD_COORDS(3)     ! Coords of grid point for which the RB matrix is to be formulated
      REAL(DOUBLE) , INTENT(IN)       :: REF_COORDS(3)     ! Coords of reference grid (grid about which the RB disps occur)
      REAL(DOUBLE) , INTENT(OUT)      :: RB_DISP(6,6)      ! The set of 6 RB displ vectors for the 6 disp components for GRID_NUM
      REAL(DOUBLE)                    :: XBAR              ! Basic X coordinate of GRID_NUM relative to REF_GRID
      REAL(DOUBLE)                    :: YBAR              ! Basic Y coordinate of GRID_NUM relative to REF_GRID
      REAL(DOUBLE)                    :: ZBAR              ! Basic Z coordinate of GRID_NUM relative to REF_GRID



! **********************************************************************************************************************************
! Initialize outputs

      DO I=1,6
         DO J=1,6
            RB_DISP(I,J) = ZERO
         ENDDO
      ENDDO

! Calc outputs

      XBAR = GRD_COORDS(1) - REF_COORDS(1)
      YBAR = GRD_COORDS(2) - REF_COORDS(2)
      ZBAR = GRD_COORDS(3) - REF_COORDS(3)

! Calc 6 x 6 RB matrix

      DO I=1,6
         DO J=1,6
            RB_DISP(I,J) = ZERO
         ENDDO
         RB_DISP(I,I) = ONE
      ENDDO

      RB_DISP(1,5) =  ZBAR
      RB_DISP(1,6) = -YBAR

      RB_DISP(2,4) = -ZBAR
      RB_DISP(2,6) =  XBAR

      RB_DISP(3,4) =  YBAR
      RB_DISP(3,5) = -XBAR



      RETURN

! **********************************************************************************************************************************

      END SUBROUTINE RIGID_BODY_DISP_MAT
