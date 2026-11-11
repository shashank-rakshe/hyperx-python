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

      SUBROUTINE ARRAY_SIZE_ERROR_1 ( INP_SUBR_NAME, NTERM_VAL, MATIN_NAME )

! Print error and quit when a subr tries to exceed allocated number of terms when storing/retrieving terms in an array

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR
      USE TIMDAT, ONLY                :  TSEC

      USE ARRAY_SIZE_ERROR_1_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'ARRAY_SIZE_ERROR_1'
      CHARACTER(LEN=*), INTENT(IN)    :: INP_SUBR_NAME     ! Subroutine in which the error was detected
      CHARACTER(LEN=*), INTENT(IN)    :: MATIN_NAME        ! Name of matrix (for output message purposes)

      INTEGER(LONG), INTENT(IN)       :: NTERM_VAL         ! Size of the array that was exceeded




! **********************************************************************************************************************************
      WRITE(ERR,937) INP_SUBR_NAME, NTERM_VAL, MATIN_NAME
      WRITE(F06,937) INP_SUBR_NAME, NTERM_VAL, MATIN_NAME
      FATAL_ERR = FATAL_ERR + 1
      CALL OUTA_HERE ( 'Y' )                               ! Coding error (attempt to exceed allocated array size), so quit



      RETURN

! **********************************************************************************************************************************
  937 FORMAT(' *ERROR   937: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' ATTEMPT TO EXCEED ALLOCATED ARRAY SIZE = ',I12                                                        &
                    ,/,14X,' WHILE STORING OR RETRIEVING TERMS IN ARRAY(S) = ',A)

! **********************************************************************************************************************************

      END SUBROUTINE ARRAY_SIZE_ERROR_1
