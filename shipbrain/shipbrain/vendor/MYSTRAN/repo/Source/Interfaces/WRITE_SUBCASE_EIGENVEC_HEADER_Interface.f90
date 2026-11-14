! ###############################################################################################################################
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

   MODULE WRITE_SUBCASE_EIGENVEC_HEADER_Interface

   INTERFACE

      SUBROUTINE WRITE_SUBCASE_EIGENVEC_HEADER ( JSUB, WRITE_F06 )

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, INT_EIG_NUM, INT_SC_NUM, NDOFR, NUM_CB_DOFS, NVEC, SOL_NAME
      USE NONLINEAR_PARAMS, ONLY      :  LOAD_ISTEP
      USE MODEL_STUF, ONLY            :  LABEL, SCNUM, STITLE, TITLE

      IMPLICIT NONE

      INTEGER(LONG), INTENT(IN)       :: JSUB
      LOGICAL,       INTENT(IN)       :: WRITE_F06

      END SUBROUTINE WRITE_SUBCASE_EIGENVEC_HEADER

   END INTERFACE

   END MODULE WRITE_SUBCASE_EIGENVEC_HEADER_Interface
