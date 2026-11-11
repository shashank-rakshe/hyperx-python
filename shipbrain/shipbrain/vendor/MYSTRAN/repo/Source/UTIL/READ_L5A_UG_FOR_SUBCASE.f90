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

      SUBROUTINE READ_L5A_UG_FOR_SUBCASE ( ISUB, IERROR )

! Reads the G-set displacement vector (UG_COL) for a specific internal subcase index from file LINK5A.
! File LINK5A is written by LINK5 during the linear-static portion of an analysis: for each of NUM_SOLNS solution columns,
! LINK5 writes NDOFG unformatted records, one per G-set DOF, holding the column's UG values. For SOL 105 (BUCKLING) the
! step-1 LINK5 invocation writes one full UG vector per subcase (NUM_SOLNS == NSUB), so seeking past (ISUB-1)*NDOFG records
! and reading the next NDOFG records yields subcase ISUB's UG displacements.
!
! Caller responsibilities:
!   * UG_COL must already be allocated to size NDOFG (use ALLOCATE_COL_VEC('UG_COL',NDOFG,SUBR_NAME) if not).
!   * The L5A file must contain at least ISUB columns of NDOFG records each (i.e. LINK5 step 1 must have run with
!     NUM_SOLNS >= ISUB).
! On error, IERROR is incremented; on success it is left unchanged.

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  ERR, F06, L5A, LINK5A, L5A_MSG
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, NDOFG
      USE COL_VECS, ONLY              :  UG_COL

      USE READ_L5A_UG_FOR_SUBCASE_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'READ_L5A_UG_FOR_SUBCASE'

      INTEGER(LONG), INTENT(IN)       :: ISUB              ! Internal subcase index (1..NSUB) to fetch UG_COL for
      INTEGER(LONG), INTENT(INOUT)    :: IERROR            ! Cumulative error count, incremented on any IO failure

      INTEGER(LONG)                   :: I                 ! DO loop index
      INTEGER(LONG)                   :: IOCHK             ! IOSTAT from READ
      INTEGER(LONG)                   :: REC_NO            ! Record number for READERR diagnostics
      INTEGER(LONG)                   :: SKIP              ! Number of records to skip before reaching subcase ISUB
      INTEGER(LONG)                   :: OUNT(2)           ! File units for READERR



! **********************************************************************************************************************************
      OUNT(1) = ERR
      OUNT(2) = F06

      IF (ISUB < 1) THEN
         WRITE(ERR,9101) SUBR_NAME, ISUB
         WRITE(F06,9101) SUBR_NAME, ISUB
         FATAL_ERR = FATAL_ERR + 1
         IERROR = IERROR + 1
         RETURN
      ENDIF

      IF (.NOT. ALLOCATED(UG_COL)) THEN
         WRITE(ERR,9102) SUBR_NAME
         WRITE(F06,9102) SUBR_NAME
         FATAL_ERR = FATAL_ERR + 1
         IERROR = IERROR + 1
         RETURN
      ENDIF

      IF (SIZE(UG_COL) < NDOFG) THEN
         WRITE(ERR,9103) SUBR_NAME, SIZE(UG_COL), NDOFG
         WRITE(F06,9103) SUBR_NAME, SIZE(UG_COL), NDOFG
         FATAL_ERR = FATAL_ERR + 1
         IERROR = IERROR + 1
         RETURN
      ENDIF

      ! Open L5A fresh in READ/REWIND mode. If it is already open elsewhere we close it first so we can rewind cleanly.
      CALL FILE_CLOSE ( L5A, LINK5A, 'KEEP' )
      CALL FILE_OPEN  ( L5A, LINK5A, OUNT, 'OLD', L5A_MSG, 'READ_STIME', 'UNFORMATTED', 'READ', 'REWIND', 'Y', 'N' )

      ! Skip (ISUB-1)*NDOFG records to position at the start of subcase ISUB's UG vector.
      SKIP = (ISUB - 1) * NDOFG
      REC_NO = 0
      DO I = 1, SKIP
         REC_NO = REC_NO + 1
         READ(L5A,IOSTAT=IOCHK)
         IF (IOCHK /= 0) THEN
            CALL READERR ( IOCHK, LINK5A, L5A_MSG, REC_NO, OUNT )
            IERROR = IERROR + 1
            CALL FILE_CLOSE ( L5A, LINK5A, 'KEEP' )
            RETURN
         ENDIF
      ENDDO

      ! Read NDOFG records into UG_COL.
      DO I = 1, NDOFG
         REC_NO = REC_NO + 1
         READ(L5A,IOSTAT=IOCHK) UG_COL(I)
         IF (IOCHK /= 0) THEN
            CALL READERR ( IOCHK, LINK5A, L5A_MSG, REC_NO, OUNT )
            IERROR = IERROR + 1
            CALL FILE_CLOSE ( L5A, LINK5A, 'KEEP' )
            RETURN
         ENDIF
      ENDDO

      ! Leave L5A closed so the next writer (e.g. step-2 LINK5) can REPLACE it cleanly.
      CALL FILE_CLOSE ( L5A, LINK5A, 'KEEP' )



      RETURN

! **********************************************************************************************************************************
 9101 FORMAT(' *ERROR  9101: PROGRAMMING ERROR IN ',A,': ISUB MUST BE >= 1 BUT IS ',I8)
 9102 FORMAT(' *ERROR  9102: PROGRAMMING ERROR IN ',A,': UG_COL IS NOT ALLOCATED')
 9103 FORMAT(' *ERROR  9103: PROGRAMMING ERROR IN ',A,': SIZE(UG_COL)=',I8,' IS LESS THAN NDOFG=',I8)

! **********************************************************************************************************************************

      END SUBROUTINE READ_L5A_UG_FOR_SUBCASE
