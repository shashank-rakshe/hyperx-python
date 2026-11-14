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

      SUBROUTINE DEALLOCATE_IN4_FILES ( NAME )

! Deallocate arrays for IN4 files (USERIN elements)

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  ERR, F06, IN4FIL, IN4FIL_NUM, WRT_ERR
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, TOT_MB_MEM_ALLOC
      USE TIMDAT, ONLY                :  TSEC
      USE DEBUG_PARAMETERS, ONLY      :  DEBUG
      USE CONSTANTS_1, ONLY           :  ZERO
      USE INPUTT4_MATRICES, ONLY      :  IN4_COL_MAP, IN4_MAT

      USE DEALLOCATE_IN4_FILES_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'DEALLOCATE_IN4_FILES'
      CHARACTER(LEN=*), INTENT(IN)    :: NAME              ! Array name (used for output error message)

      INTEGER(LONG)                   :: IERR              ! STAT from DEALLOCATE
      INTEGER(LONG)                   :: JERR              ! Local error indicator


      REAL(DOUBLE)                    :: CUR_MB_ALLOCATED  ! MB of memory that is currently allocated to ARRAY_NAME when subr
!                                                            ALLOCATED_MEMORY is called (before entering MB_ALLOCATED into array
!                                                            ALLOCATED_ARRAY_MEM



! **********************************************************************************************************************************
!  Deallocate IN4 files

      IF (NAME == 'IN4FIL') THEN
         IF (ALLOCATED(IN4FIL)) THEN
            DEALLOCATE (IN4FIL,STAT=IERR)
            IF (IERR /= 0) THEN
               WRITE(ERR,992) NAME,SUBR_NAME
               WRITE(F06,992) NAME,SUBR_NAME
               JERR = JERR + 1
            ENDIF
         ENDIF
         IF (ALLOCATED(IN4FIL_NUM)) THEN
            DEALLOCATE (IN4FIL_NUM,STAT=IERR)
            IF (IERR /= 0) THEN
               WRITE(ERR,992) NAME,SUBR_NAME
               WRITE(F06,992) NAME,SUBR_NAME
               JERR = JERR + 1
            ENDIF
         ENDIF

      ELSE IF (NAME == 'IN4_COL_MAP') THEN
         IF (ALLOCATED(IN4_COL_MAP)) THEN
            DEALLOCATE (IN4_COL_MAP,STAT=IERR)
            IF (IERR /= 0) THEN
               WRITE(ERR,992) NAME,SUBR_NAME
               WRITE(F06,992) NAME,SUBR_NAME
               JERR = JERR + 1
            ENDIF
         ENDIF

      ELSE IF (NAME == 'IN4_MAT') THEN
         IF (ALLOCATED(IN4_MAT)) THEN
            DEALLOCATE (IN4_MAT,STAT=IERR)
            IF (IERR /= 0) THEN
               WRITE(ERR,992) NAME,SUBR_NAME
               WRITE(F06,992) NAME,SUBR_NAME
               JERR = JERR + 1
            ENDIF
         ENDIF

      ENDIF

! **********************************************************************************************************************************
      CALL ALLOCATED_MEMORY ( NAME, ZERO, 'DEALLOC', 'Y', CUR_MB_ALLOCATED, SUBR_NAME )

      RETURN

! **********************************************************************************************************************************
  992 FORMAT(' *ERROR   992: CANNOT DEALLOCATE MEMORY FROM ARRAY ',A,' IN SUBROUTINE ',A)


! **********************************************************************************************************************************

      END SUBROUTINE DEALLOCATE_IN4_FILES
