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

      SUBROUTINE WRITE_SUBCASE_EIGENVEC_HEADER ( JSUB, WRITE_F06 )

! Writes the complete per-vector block header to F06 for all LINK9 WRITE_* subroutines:
!   - Two blank separator lines
!   - "OUTPUT FOR SUBCASE x"         (all except GEN CB MODEL)
!   - "OUTPUT FOR EIGENVECTOR y"     (MODES and BUCKLING step 2 only)
!   - TITLE / SUBTITLE / LABEL lines  (each written only if non-blank)
!   - One trailing blank line
!
! This is the central single point for the per-vector F06 header emitted by all LINK9 WRITE_* subroutines.
! For GEN CB MODEL the SUBCASE/EIGENVECTOR lines are skipped; the caller writes the CB DOF line after returning.
!
! JSUB  = global solution-vector index (subcase number for STATICS, or global eigenvector index for MODES/BUCKLING)
!
! Module variables consumed (set by LINK9 before each call into the WRITE_* routines):
!   INT_SC_NUM  - owning internal subcase index (for TITLE/STITLE/LABEL lookup in the caller)
!   INT_EIG_NUM - per-subcase local eigenvector counter (1-based, reset per subcase); 0 for non-eigen solutions
!
! Craig-Bampton: the two blank lines are written here; the caller is responsible for the CB DOF line itself,
! since that requires grid/component lookup data not available here.

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, INT_EIG_NUM, INT_SC_NUM, NDOFR, NUM_CB_DOFS, NVEC, SOL_NAME
      USE NONLINEAR_PARAMS, ONLY      :  LOAD_ISTEP
      USE MODEL_STUF, ONLY            :  LABEL, SCNUM, STITLE, TITLE

      USE WRITE_SUBCASE_EIGENVEC_HEADER_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'WRITE_SUBCASE_EIGENVEC_HEADER'

      INTEGER(LONG), INTENT(IN)       :: JSUB              ! Global solution-vector index passed in by the caller
      LOGICAL,       INTENT(IN)       :: WRITE_F06         ! If .FALSE., suppress all F06 output (mirrors caller guard)

! **********************************************************************************************************************************

      IF (.NOT. WRITE_F06) RETURN

      WRITE(F06,*)
      WRITE(F06,*)

      IF    ((SOL_NAME(1:7) == 'STATICS') .OR. (SOL_NAME(1:8) == 'NLSTATIC')) THEN

         WRITE(F06,9011) SCNUM(JSUB)

      ELSE IF ((SOL_NAME(1:8) == 'BUCKLING') .AND. (LOAD_ISTEP == 1)) THEN

         WRITE(F06,9011) SCNUM(JSUB)

      ELSE IF ((SOL_NAME(1:8) == 'BUCKLING') .AND. (LOAD_ISTEP == 2)) THEN

         WRITE(F06,9011) SCNUM(INT_SC_NUM)
         WRITE(F06,9012) INT_EIG_NUM

      ELSE IF (SOL_NAME(1:5) == 'MODES') THEN

         WRITE(F06,9011) SCNUM(INT_SC_NUM)
         WRITE(F06,9012) INT_EIG_NUM

      ! GEN CB MODEL: caller must write the CB DOF line -- just emit the blank lines (done above) and return
      ENDIF

      IF (TITLE(INT_SC_NUM)(1:)   /= ' ') WRITE(F06,9013) TITLE(INT_SC_NUM)
      IF (STITLE(INT_SC_NUM)(1:)  /= ' ') WRITE(F06,9013) STITLE(INT_SC_NUM)
      IF (LABEL(INT_SC_NUM)(1:)   /= ' ') WRITE(F06,9013) LABEL(INT_SC_NUM)
      WRITE(F06,*)

      RETURN

! **********************************************************************************************************************************
 9011 FORMAT(' OUTPUT FOR SUBCASE ',I8)
 9012 FORMAT(' OUTPUT FOR EIGENVECTOR ',I8)
 9013 FORMAT(1X,A)

      END SUBROUTINE WRITE_SUBCASE_EIGENVEC_HEADER
