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

      SUBROUTINE FILE_CLOSE ( UNIT, FILNAM, CLOSE_STAT )

! Closes files and writes message if the close fails

      USE PENTIUM_II_KIND, ONLY       :  LONG
      USE IOUNT1, ONLY                :  SC1

      USE FILE_CLOSE_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=*)   , INTENT(IN) :: FILNAM            ! File name

      CHARACTER(LEN=*)   , INTENT(IN) :: CLOSE_STAT        ! Status for close

      INTEGER(LONG), INTENT(IN)       :: UNIT              ! File unit number
      INTEGER(LONG)                   :: IOCHK             ! IOSTAT error number when closing a file




! **********************************************************************************************************************************
      CLOSE ( UNIT,STATUS=CLOSE_STAT,IOSTAT=IOCHK )

      IF (IOCHK /= 0) THEN
         WRITE(SC1,903) IOCHK
         CALL WRITE_FILNAM ( FILNAM, SC1, 15 )
         WRITE(SC1,9232)
         STOP
      ENDIF


      RETURN

! **********************************************************************************************************************************
  903 FORMAT(' *ERROR   903: ERROR ENCOUNTERED WITH IOSTAT = ',I8,' CLOSING FILE:')

 9232 FORMAT('               IT MAY BE OPEN IN ANOTHER PROGRAM. IF SO, CLOSE IT & START AGAIN.')

! **********************************************************************************************************************************

      END SUBROUTINE FILE_CLOSE
