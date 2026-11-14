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

      SUBROUTINE ALLOCATE_L2_GMN_2 ( CALLING_SUBR )

! Allocate some arrays for use in LINK2

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE CONSTANTS_1, ONLY           :  ZERO, ONEPP6
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, NDOFM, NTERM_GMN, TOT_MB_MEM_ALLOC
      USE TIMDAT, ONLY                :  TSEC
      USE DEBUG_PARAMETERS, ONLY      :  DEBUG
      USE SPARSE_MATRICES, ONLY       :  I2_GMN

      USE ALLOCATE_L2_GMN_2_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'ALLOCATE_L2_GMN_2'
      CHARACTER(LEN=*), INTENT(IN)    :: CALLING_SUBR      ! Array name of the matrix to be allocated in sparse format
      CHARACTER(24*BYTE)              :: NAME              ! Array name (used for output error message)

      INTEGER(LONG)                   :: I                 ! DO loop index
      INTEGER(LONG)                   :: IERR              ! STAT from DEALLOCATE
      INTEGER(LONG)                   :: JERR              ! Local error indicator
      INTEGER(LONG)                   :: NROWS             ! Number of rows in array
      INTEGER(LONG), PARAMETER        :: NCOLS     = 1     ! Number of cols in array


      REAL(DOUBLE)                    :: CUR_MB_ALLOCATED  ! MB of memory that is currently allocated to ARRAY_NAME when subr
!                                                            ALLOCATED_MEMORY is called (before entering MB_ALLOCATED into array
!                                                            ALLOCATED_ARRAY_MEM
      REAL(DOUBLE)                    :: MB_ALLOCATED      ! Megabytes of mmemory allocated for the arrays to put into array
!                                                            ALLOCATED_ARRAY_MEM when subr ALLOCATED_MEMORY is called

      INTRINSIC                       :: REAL



! **********************************************************************************************************************************
! Allocate array for I2_GMN
! NOTE: I2_GMN has row no's for ALL terms in GMN - not the sparse format that is compressed row storage.
! This is a temporary allocate for subr SOLVE_GMN

      MB_ALLOCATED = ZERO
      NROWS = NTERM_GMN
      JERR = 0

! Allocate array I2_GMN

      NAME = 'I2_GMN                  '
      IF (ALLOCATED(I2_GMN)) THEN
         WRITE(ERR,990) SUBR_NAME, NAME
         WRITE(F06,990) SUBR_NAME, NAME
         FATAL_ERR = FATAL_ERR + 1
         JERR = JERR + 1
      ELSE
         ALLOCATE (I2_GMN(NTERM_GMN),STAT=IERR)
         IF (IERR == 0) THEN
            DO I=1,NTERM_GMN
               I2_GMN(I) = 0
            ENDDO
         ELSE
            WRITE(ERR,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
            WRITE(F06,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
            FATAL_ERR = FATAL_ERR + 1
            JERR = JERR + 1
         ENDIF
      ENDIF

! Quit if there were errors

      IF (JERR /= 0) THEN
         FATAL_ERR = FATAL_ERR + 1
         WRITE(ERR,1699) TRIM(SUBR_NAME), CALLING_SUBR
         WRITE(F06,1699) SUBR_NAME, CALLING_SUBR
         CALL OUTA_HERE ( 'Y' )
      ENDIF

! **********************************************************************************************************************************
      MB_ALLOCATED = REAL(DOUBLE)*REAL(NROWS)/ONEPP6
      CALL ALLOCATED_MEMORY ( NAME, MB_ALLOCATED, 'ALLOC', 'Y', CUR_MB_ALLOCATED, SUBR_NAME )


      RETURN

! **********************************************************************************************************************************
  990 FORMAT(' *ERROR   990: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' CANNOT ALLOCATE MEMORY TO ARRAY ',A,'. IT IS ALREADY ALLOCATED')

  991 FORMAT(' *ERROR   991: CANNOT ALLOCATE ',F10.3,' MB OF MEMORY TO ARRAY ',A,' IN SUBROUTINE ',A                               &
                    ,/,14X,' ALLOCATION STAT = ',I8)

 1699 FORMAT('               THE SUBR IN WHICH THESE ERRORS WERE FOUND (',A,') WAS CALLED BY SUBR ',A)

! **********************************************************************************************************************************

      END SUBROUTINE ALLOCATE_L2_GMN_2
