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

      SUBROUTINE CC_STRE ( CARD )

      ! Processes Case Control STRE cards for element stress output requests
      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, CC_CMD_DESCRIBERS, LSUB, NSUB, NCCCD
      USE TIMDAT, ONLY                :  TSEC
      USE CC_OUTPUT_DESCRIBERS, ONLY  :  STRE_OUT
      USE MODEL_STUF, ONLY            :  SC_STRE

      USE CC_STRE_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'CC_STRE'
      CHARACTER(LEN=*), INTENT(IN)    :: CARD              ! A Bulk Data card

      INTEGER(LONG)                   :: I                 ! DO loop index
      INTEGER(LONG)                   :: SETID             ! Set ID on this Case Control card




! **********************************************************************************************************************************
      ! CC_OUTPUTS processes all output type Case Control entries (they all
      ! have some common code so it is put there)

      CALL CC_OUTPUTS ( CARD, 'STRE', SETID )

      CALL COMPUTE_OUTPUT_TARGETS(STRE_OUT)

      ! Set CASE CONTROL output request variable to SETID
      IF (NSUB == 0) THEN
         DO I = 1,LSUB
            SC_STRE(I) = SETID
         ENDDO
      ELSE
         SC_STRE(NSUB) = SETID
      ENDIF



      RETURN

! **********************************************************************************************************************************

      END SUBROUTINE CC_STRE
