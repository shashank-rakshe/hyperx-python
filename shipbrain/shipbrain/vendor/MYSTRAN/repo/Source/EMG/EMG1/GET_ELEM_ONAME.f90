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

      SUBROUTINE GET_ELEM_ONAME ( NAME )

! Gets element output name (used in LINK9 subr's which write elem and/or ply outputs) for a given element type

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, METYPE
      USE TIMDAT, ONLY                :  TSEC
      USE MODEL_STUF, ONLY            :  ELEM_ONAME, ELMTYP, TYPE

      USE GET_ELEM_ONAME_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM))            :: SUBR_NAME = 'GET_ELEM_ONAME'
      CHARACTER( 1*BYTE)                          :: FOUND       = 'N' ! 'Y' if we find the requested element tyoe
      CHARACTER(LEN=LEN(ELEM_ONAME)), INTENT(OUT) :: NAME              ! Name of an elem for output purposes in LINK9 WRTELi subr's

      INTEGER(LONG)                               :: I                 ! DO loop index




! **********************************************************************************************************************************
      NAME = ' '

      FOUND = 'N'
      DO I=1,METYPE
         IF (TYPE == ELMTYP(I)) THEN
            NAME  = ELEM_ONAME(I)
            FOUND = 'Y'
         ENDIF
      ENDDO

! Make sure we found a valid element type

      IF (FOUND == 'N') THEN
         WRITE(ERR,1940) SUBR_NAME, TYPE
         WRITE(F06,1940) SUBR_NAME, TYPE
         FATAL_ERR = FATAL_ERR + 1
         CALL OUTA_HERE ( 'Y' )
      ENDIF

! **********************************************************************************************************************************
 1940 FORMAT(' *ERROR  1940: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' ELEMENT TYPE "',A,'" NOT FOUND IN ARRAY ELMTYP')



      RETURN

      END SUBROUTINE GET_ELEM_ONAME
