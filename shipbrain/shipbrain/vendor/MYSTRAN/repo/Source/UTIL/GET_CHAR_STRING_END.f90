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

      SUBROUTINE GET_CHAR_STRING_END ( CHAR_STRING, IEND )

! Searches integer array ARRAY to find column where data ends (IEND)

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG
      USE SCONTR, ONLY                :  BLNK_SUB_NAM
      USE TIMDAT, ONLY                :  TSEC

      USE GET_CHAR_STRING_END_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'GET_CHAR_STRING_END'
      CHARACTER(LEN=*) , INTENT(IN)   :: CHAR_STRING       ! String to get ending of

      INTEGER(LONG)    , INTENT(OUT)  :: IEND              ! Col where CHAR_STRING stops having non blanks
      INTEGER(LONG)                   :: I                 ! DO loop index




! **********************************************************************************************************************************
      IEND = LEN(CHAR_STRING)
      DO I=LEN(CHAR_STRING),1,-1
         IF (CHAR_STRING(I:I) /= ' ') THEN
            IEND = I
            EXIT
         ENDIF
      ENDDO



      RETURN

! **********************************************************************************************************************************

      END SUBROUTINE GET_CHAR_STRING_END
