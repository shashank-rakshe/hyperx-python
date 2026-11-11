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

      SUBROUTINE STMERR ( XTIME, FILNAM, OUNT )

! Prints error messages when the wrong time stamp, STIME, is read as the first record in a file that has been opened

      USE PENTIUM_II_KIND, ONLY       :  LONG
      USE IOUNT1, ONLY                :  FILE_NAM_MAXLEN
      USE SCONTR, ONLY                :  FATAL_ERR
      USE TIMDAT, ONLY                :  STIME

      USE STMERR_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=*), INTENT(IN)    :: FILNAM            ! File name

      INTEGER(LONG), INTENT(IN)       :: OUNT(2)           ! File units to write messages to
      INTEGER(LONG), INTENT(IN)       :: XTIME             ! Time stamp read from file LINK1A
      INTEGER(LONG)                   :: I                 ! DO loop index
      INTEGER(LONG)                   :: IEND              ! Index




! **********************************************************************************************************************************
      DO I=FILE_NAM_MAXLEN,1,-1
         IF (FILNAM(I:I) /= ' ') THEN
            IEND = I
            EXIT
         ENDIF
      ENDDO

      DO I=1,2
         WRITE(OUNT(I),908) XTIME, STIME, FILNAM(1:IEND)
         IF (OUNT(2) == OUNT(1)) EXIT
      ENDDO

      FATAL_ERR = FATAL_ERR + 1



      RETURN

! **********************************************************************************************************************************
  908 FORMAT(' *ERROR   908: WRONG SYSTEM TIME STAMP = ',I12,'. SHOULD BE = ',I12                                                  &
                    ,/,14X,' READ FROM FILE:'                                                                                      &
                    ,/,15X,A                                                                                                       &
                    ,/,14X,' IT COULD BE THAT THE FILE DOES NOT EXIST')

! **********************************************************************************************************************************
       END SUBROUTINE STMERR
