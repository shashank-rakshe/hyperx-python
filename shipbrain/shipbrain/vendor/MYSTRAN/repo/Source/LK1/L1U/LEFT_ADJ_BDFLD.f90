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

      SUBROUTINE LEFT_ADJ_BDFLD ( CHR_FLD )

! Shifts a character string so that it is left adjusted

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, JCARD_LEN
      USE TIMDAT, ONLY                :  TSEC

      USE LEFT_ADJ_BDFLD_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM))       :: SUBR_NAME = 'LEFT_ADJ_BDFLD'
      CHARACTER(LEN=JCARD_LEN), INTENT(INOUT):: CHR_FLD           ! Char field to left adjust and return
      CHARACTER(LEN=JCARD_LEN)               :: TCHR_FLD          ! Temporary char field

      INTEGER(LONG)                          :: I                 ! DO loop index




! **********************************************************************************************************************************
      IF (CHR_FLD(1:1) == ' ') THEN                        ! We need to shift:

         TCHR_FLD(1:) = CHR_FLD(1:)                        ! Set temporary field to CHR8_FLD

         DO I = 2,JCARD_LEN                                ! Perform shift
            IF (CHR_FLD(I:I) /= ' ') THEN
               TCHR_FLD(1:) = CHR_FLD(I:)
               EXIT
            ENDIF
         ENDDO

         CHR_FLD(1:) = TCHR_FLD(1:)                        ! Reset CHR_FLD and return

      ENDIF



      RETURN

! **********************************************************************************************************************************


      END SUBROUTINE LEFT_ADJ_BDFLD
