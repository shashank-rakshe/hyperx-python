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

      SUBROUTINE CRDERR ( CARD )

! Prints Bulk Data card errors and warnings

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, ECHO, IERRFL
      USE TIMDAT, ONLY                :  TSEC

      USE CRDERR_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'CRDERR'
      CHARACTER(LEN=*), INTENT(IN)    :: CARD              ! A Bulk Data card
      CHARACTER( 1*BYTE)              :: CARD_ERR          ! = 'Y' if IERRFL is 'Y' for any Bulk Data card field

      INTEGER(LONG)                   :: I                 ! DO loop index




! **********************************************************************************************************************************
      CARD_ERR = 'N'
      DO I=1,10
         IF (IERRFL(I) == 'Y') THEN
            CARD_ERR = 'Y'
            EXIT
         ENDIF
      ENDDO

      IF (CARD_ERR == 'Y') THEN
         IF (ECHO == 'NONE  ') THEN
            WRITE(ERR,101) CARD
            WRITE(F06,101) CARD
         ENDIF
         DO I=1,10
            IF (IERRFL(I) == 'Y') THEN
               WRITE(ERR,1702) I
               WRITE(F06,1702) I
            ENDIF
         ENDDO
      ENDIF

      DO I=1,10
         IERRFL(I) = 'N'
      ENDDO



      RETURN

! **********************************************************************************************************************************
  101 FORMAT(A)

 1702 FORMAT(' *ERROR  1702: FORMAT ERROR IN FIELD',I3,' OF PREVIOUS CARD')

! **********************************************************************************************************************************

      END SUBROUTINE CRDERR
