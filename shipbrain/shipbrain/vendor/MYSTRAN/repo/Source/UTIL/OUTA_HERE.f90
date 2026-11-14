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

      SUBROUTINE OUTA_HERE ( WRITE_TO_L1A )

! Routine called when MYSTRAN has to stop due to some error. Writes data to file LINK1A, writes error message and stops

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE

      USE IOUNT1, ONLY                :  BUGOUT, F06FIL, SC1,                                                 &
                                         BUGSTAT, BUGSTAT_OLD, ERRSTAT, ERRSTAT_OLD,                          &
                                         OP2STAT, PCHSTAT, L1ASTAT

      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, LINKNO, WARN_ERR
      USE TIMDAT, ONLY                :  TSEC
      USE PARAMS, ONLY                :  SUPWARN

      USE OUTA_HERE_USE_IFs

      IMPLICIT NONE


      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'OUTA_HERE'
      CHARACTER( 1*BYTE), INTENT(IN)  :: WRITE_TO_L1A      ! Y/N indicator of whether to call subr WRITE_L1A



! **********************************************************************************************************************************


! Write data to LINK1A, if we are in LINK1

      IF (WRITE_TO_L1A == 'Y') THEN

         IF (FATAL_ERR > 0) THEN                           ! Check fatal error flag and write message
            WRITE(SC1,9992) FATAL_ERR
         ENDIF

         IF (WARN_ERR > 0) THEN                            ! Check warning flag and write message
            IF (SUPWARN == 'Y') THEN
               WRITE(SC1,9994) WARN_ERR
            ELSE
               WRITE(SC1,9993) WARN_ERR
            ENDIF
         ENDIF

         WRITE(SC1,9999)
         CALL WRITE_FILNAM ( F06FIL, SC1, 1 )

         CALL WRITE_L1A ( L1ASTAT, 'N' )

! Set close status for output files

         IF (BUGOUT == 'Y') THEN
            BUGSTAT = 'KEEP'
         ELSE
            IF (BUGSTAT_OLD == 'KEEP    ') THEN
               BUGSTAT = 'KEEP'
            ELSE
               BUGSTAT = 'DELETE'
            ENDIF
         ENDIF

         IF ((FATAL_ERR > 0) .OR. (WARN_ERR > 0)) THEN
            ERRSTAT = 'KEEP'
         ELSE
            IF (ERRSTAT_OLD == 'KEEP    ') THEN
               ERRSTAT = 'KEEP'
            ELSE
               ERRSTAT = 'DELETE'
            ENDIF
         ENDIF


      ELSE

         WRITE(SC1,9999)
         CALL WRITE_FILNAM ( F06FIL, SC1, 1 )

      ENDIF

      CALL CLOSE_OUTFILES ( BUGSTAT, ERRSTAT, OP2STAT, PCHSTAT )

      STOP

! **********************************************************************************************************************************
 9992 FORMAT(' CHECK F06 OUTPUT FILE FOR ',I8,' FATAL MESSAGE(S)')

 9993 FORMAT(' CHECK F06 OUTPUT FILE FOR ',I8,' WARNING MESSAGE(S)')

 9994 FORMAT(' CHECK ERR OUTPUT FILE FOR ',I8,' WARNING MESSAGE(S)')

 9999 FORMAT(' Processing terminated. Check for error messages in output file:')

! **********************************************************************************************************************************

      END SUBROUTINE OUTA_HERE
