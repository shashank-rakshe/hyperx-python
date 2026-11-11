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

      SUBROUTINE ALLOCATE_L6_2 ( NAME, CALLING_SUBR )

! Allocate some arrays for use in LINK6

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE CONSTANTS_1, ONLY           :  ZERO, ONEPP6
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, NTERM_DLR, NTERM_PHIZL1, TOT_MB_MEM_ALLOC
      USE TIMDAT, ONLY                :  TSEC
      USE DEBUG_PARAMETERS, ONLY      :  DEBUG
      USE SPARSE_MATRICES, ONLY       :  I2_DLR, I2_DLRt, I2_PHIZL1, I2_PHIZL1t

      USE ALLOCATE_L6_2_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'ALLOCATE_L6_2'
      CHARACTER(LEN=*), INTENT(IN)    :: CALLING_SUBR      ! Array name of the matrix to be allocated in sparse format
      CHARACTER(LEN=*), INTENT(IN)    :: NAME              ! Array name (used for output error message)

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
      MB_ALLOCATED = ZERO
      JERR = 0

      IF (NAME == 'DLR') THEN                              ! Allocate array I2_DLR
         NROWS = NTERM_DLR
         IF (ALLOCATED(I2_DLR)) THEN
            WRITE(ERR,990) SUBR_NAME, NAME
            WRITE(F06,990) SUBR_NAME, NAME
            FATAL_ERR = FATAL_ERR + 1
            JERR = JERR + 1
         ELSE
            ALLOCATE (I2_DLR(NTERM_DLR),STAT=IERR)
            IF (IERR == 0) THEN
               DO I=1,NTERM_DLR
                  I2_DLR(I) = 0
               ENDDO
            ELSE
               WRITE(ERR,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               WRITE(F06,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               FATAL_ERR = FATAL_ERR + 1
               JERR = JERR + 1
            ENDIF
         ENDIF

      ELSE IF (NAME == 'DLRt') THEN                        ! Allocate array I2_DLRt
         NROWS = NTERM_DLR
         IF (ALLOCATED(I2_DLRt  )) THEN
            WRITE(ERR,990) SUBR_NAME, NAME
            WRITE(F06,990) SUBR_NAME, NAME
            FATAL_ERR = FATAL_ERR + 1
            JERR = JERR + 1
         ELSE
            ALLOCATE (I2_DLRt(NTERM_DLR),STAT=IERR)        ! Number of terms in DLRt is same as in DLR
            IF (IERR == 0) THEN
               DO I=1,NTERM_DLR
                  I2_DLRt(I) = 0
               ENDDO
            ELSE
               WRITE(ERR,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               WRITE(F06,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               FATAL_ERR = FATAL_ERR + 1
               JERR = JERR + 1
            ENDIF
         ENDIF

      ELSE IF (NAME == 'PHIZL1') THEN                      ! Allocate array I2_PHIZL1
         NROWS = NTERM_PHIZL1
         IF (ALLOCATED(I2_PHIZL1  )) THEN
            WRITE(ERR,990) SUBR_NAME, NAME
            WRITE(F06,990) SUBR_NAME, NAME
            FATAL_ERR = FATAL_ERR + 1
            JERR = JERR + 1
         ELSE
            ALLOCATE (I2_PHIZL1(NTERM_PHIZL1),STAT=IERR)
            IF (IERR == 0) THEN
               DO I=1,NTERM_PHIZL1
                  I2_PHIZL1(I) = 0
               ENDDO
            ELSE
               WRITE(ERR,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               WRITE(F06,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               FATAL_ERR = FATAL_ERR + 1
               JERR = JERR + 1
            ENDIF
         ENDIF

      ELSE IF (NAME == 'PHIZL1t') THEN                     ! Allocate array I2_PHIZL1t
         NROWS = NTERM_PHIZL1
         IF (ALLOCATED(I2_PHIZL1t  )) THEN
            WRITE(ERR,990) SUBR_NAME, NAME
            WRITE(F06,990) SUBR_NAME, NAME
            FATAL_ERR = FATAL_ERR + 1
            JERR = JERR + 1
         ELSE
            ALLOCATE (I2_PHIZL1t(NTERM_PHIZL1),STAT=IERR)  ! Number of terms in PHIZL1t is same as in PHIZL1
            IF (IERR == 0) THEN
               DO I=1,NTERM_PHIZL1
                  I2_PHIZL1t(I) = 0
               ENDDO
            ELSE
               WRITE(ERR,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               WRITE(F06,991) MB_ALLOCATED,NAME,SUBR_NAME,IERR
               FATAL_ERR = FATAL_ERR + 1
               JERR = JERR + 1
            ENDIF
         ENDIF

      ELSE                                                 ! NAME not recognized, so coding error

         WRITE(ERR,915) SUBR_NAME, 'ALLOCATED', NAME
         WRITE(F06,915) SUBR_NAME, 'ALLOCATED', NAME
         FATAL_ERR = FATAL_ERR + JERR
         JERR = JERR + 1

      ENDIF

! Quit if there were errors

      IF (JERR /= 0) THEN
         WRITE(ERR,1699) TRIM(SUBR_NAME), CALLING_SUBR
         WRITE(F06,1699) SUBR_NAME, CALLING_SUBR
         CALL OUTA_HERE ( 'Y' )
      ENDIF

! **********************************************************************************************************************************
      MB_ALLOCATED = (REAL(DOUBLE))*(REAL(NROWS))/ONEPP6
      CALL ALLOCATED_MEMORY ( NAME, MB_ALLOCATED, 'ALLOC', 'Y', CUR_MB_ALLOCATED, SUBR_NAME )


      RETURN

! **********************************************************************************************************************************
  915 FORMAT(' *ERROR   915: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' NAME OF ARRAY TO BE ',A,' IS INCORRECT. INPUT NAME WAS ',A)

  990 FORMAT(' *ERROR   990: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' CANNOT ALLOCATE MEMORY TO ARRAY ',A,'. IT IS ALREADY ALLOCATED')

  991 FORMAT(' *ERROR   991: CANNOT ALLOCATE ',F10.3,' MB OF MEMORY TO ARRAY ',A,' IN SUBROUTINE ',A                               &
                    ,/,14X,' ALLOCATION STAT = ',I8)

 1699 FORMAT('               THE SUBR IN WHICH THESE ERRORS WERE FOUND (',A,') WAS CALLED BY SUBR ',A)


! **********************************************************************************************************************************

      END SUBROUTINE ALLOCATE_L6_2
