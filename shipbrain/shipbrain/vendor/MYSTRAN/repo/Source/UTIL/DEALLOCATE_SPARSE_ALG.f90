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

      SUBROUTINE DEALLOCATE_SPARSE_ALG ( NAME )

! Deallocate some ancillary arrays for use in the MYSTRAN sparse matrix (add, multiply, partitition, merge) routines

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, TOT_MB_MEM_ALLOC
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE TIMDAT, ONLY                :  TSEC
      USE DEBUG_PARAMETERS, ONLY      :  DEBUG
      USE CONSTANTS_1, ONLY           :  ZERO
      USE SPARSE_ALG_ARRAYS, ONLY     :  ALG, AROW, J_AROW, LOGICAL_VEC, REAL_VEC

      USE DEALLOCATE_SPARSE_ALG_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'DEALLOCATE_SPARSE_ALG'
      CHARACTER(LEN=*), INTENT(IN)    :: NAME              ! Array name of the matrix to be allocated in sparse format

      INTEGER(LONG)                   :: IERR              ! STAT from DEALLOCATE
      INTEGER(LONG)                   :: JERR              ! Local error indicator


      REAL(DOUBLE)                    :: CUR_MB_ALLOCATED  ! MB of memory that is currently allocated to ARRAY_NAME when subr
!                                                            ALLOCATED_MEMORY is called (before entering MB_ALLOCATED into array
!                                                            ALLOCATED_ARRAY_MEM



! **********************************************************************************************************************************
      JERR = 0

      IF (NAME == 'ALG') THEN                              ! Deallocate arrays for ALG

        IF (ALLOCATED(ALG)) THEN
           DEALLOCATE (ALG,STAT=IERR)
           IF (IERR /= 0) THEN
              WRITE(ERR,992) NAME,SUBR_NAME
              WRITE(F06,992) NAME,SUBR_NAME
              JERR = JERR + 1
           ENDIF
        ENDIF

      ELSE IF (NAME == 'AROW') THEN                        ! Deallocate arrays for AROW

        IF (ALLOCATED(AROW)) THEN
           DEALLOCATE (AROW,STAT=IERR)
           IF (IERR /= 0) THEN
              WRITE(ERR,992) NAME,SUBR_NAME
              WRITE(F06,992) NAME,SUBR_NAME
              JERR = JERR + 1
           ENDIF
        ENDIF

      ELSE IF (NAME == 'J_AROW') THEN                      ! Deallocate arrays for J_AROW

        IF (ALLOCATED(J_AROW)) THEN
           DEALLOCATE (J_AROW,STAT=IERR)
           IF (IERR /= 0) THEN
              WRITE(ERR,992) NAME,SUBR_NAME
              WRITE(F06,992) NAME,SUBR_NAME
              JERR = JERR + 1
           ENDIF
        ENDIF

      ELSE IF (NAME == 'LOGICAL_VEC') THEN                 ! Deallocate arrays for LOGICAL_VEC

        IF (ALLOCATED(LOGICAL_VEC)) THEN
           DEALLOCATE (LOGICAL_VEC,STAT=IERR)
           IF (IERR /= 0) THEN
              WRITE(ERR,992) NAME,SUBR_NAME
              WRITE(F06,992) NAME,SUBR_NAME
              JERR = JERR + 1
           ENDIF
        ENDIF

      ELSE IF (NAME == 'REAL_VEC') THEN                    ! Deallocate arrays for REAL_VEC

        IF (ALLOCATED(REAL_VEC)) THEN
           DEALLOCATE (REAL_VEC,STAT=IERR)
           IF (IERR /= 0) THEN
              WRITE(ERR,992) NAME,SUBR_NAME
              WRITE(F06,992) NAME,SUBR_NAME
              JERR = JERR + 1
           ENDIF
        ENDIF

      ELSE                                                 ! NAME not recognized, so coding error

         WRITE(ERR,915) SUBR_NAME, 'DEALLOCATED', NAME
         WRITE(F06,915) SUBR_NAME, 'DEALLOCATED', NAME
         FATAL_ERR = FATAL_ERR + JERR
         JERR = JERR + 1

      ENDIF

! Quit if there were errors

      IF (JERR /= 0) THEN
         CALL OUTA_HERE ( 'Y' )
      ENDIF

! **********************************************************************************************************************************
      CALL ALLOCATED_MEMORY ( NAME, ZERO, 'DEALLOC', 'Y', CUR_MB_ALLOCATED, SUBR_NAME )


      RETURN

! **********************************************************************************************************************************
  915 FORMAT(' *ERROR   915: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' NAME OF ARRAY TO BE ',A,' IS INCORRECT. INPUT NAME WAS ',A)

  992 FORMAT(' *ERROR   992: CANNOT DEALLOCATE MEMORY FROM ARRAY ',A,' IN SUBROUTINE ',A)


! **********************************************************************************************************************************

      END SUBROUTINE DEALLOCATE_SPARSE_ALG
