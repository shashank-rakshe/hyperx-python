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

MODULE COMPUTE_OUTPUT_TARGETS_MOD

  CONTAINS
  SUBROUTINE COMPUTE_OUTPUT_TARGETS(REQUEST_OUT)
    USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
    USE IOUNT1, ONLY                :  PCHSTAT
    USE SCONTR, ONLY                :  CC_CMD_DESCRIBERS, NCCCD
    USE DERIVED_DATA_TYPES, ONLY    :  OUTPUT_TARGETS

    IMPLICIT NONE

    TYPE(OUTPUT_TARGETS), INTENT(OUT) :: REQUEST_OUT
    LOGICAL                           :: FOUND_PRINT       ! CC_CMD_DESCRIBERS has request for "PRINT"
    LOGICAL                           :: FOUND_PLOT        ! CC_CMD_DESCRIBERS has request for "PLOT"
    LOGICAL                           :: FOUND_PUNCH       ! CC_CMD_DESCRIBERS has request for "PUNCH"
    LOGICAL                           :: FOUND_NEU         ! CC_CMD_DESCRIBERS has request for "NEU"
    LOGICAL                           :: FOUND_CSV         ! CC_CMD_DESCRIBERS has request for "CSV"

    INTEGER(LONG)                     :: I                 ! DO loop index

    ! Check to see if PLOT, PRINT, PUNCH, NEU, CSV were in the request
    FOUND_PRINT = .FALSE.
    FOUND_PLOT  = .FALSE.
    FOUND_PUNCH = .FALSE.
    FOUND_NEU   = .FALSE.
    FOUND_CSV   = .FALSE.
    DO I=1,NCCCD
      IF (CC_CMD_DESCRIBERS(I)(1:5) == 'PRINT') FOUND_PRINT = .TRUE.
      IF (CC_CMD_DESCRIBERS(I)(1:4) == 'PLOT')  FOUND_PLOT  = .TRUE.
      IF (CC_CMD_DESCRIBERS(I)(1:5) == 'PUNCH') FOUND_PUNCH = .TRUE.
      IF (CC_CMD_DESCRIBERS(I)(1:3) == 'NEU')   FOUND_NEU   = .TRUE.
      IF (CC_CMD_DESCRIBERS(I)(1:3) == 'CSV')   FOUND_CSV   = .TRUE.
    ENDDO

    ! only write files specifically requested
    REQUEST_OUT%WRITE_F06 = FOUND_PRINT
    REQUEST_OUT%WRITE_OP2 = FOUND_PLOT
    REQUEST_OUT%WRITE_PCH = FOUND_PUNCH

    ! no PRINT nor PLOT nor PUNCH? default to PRINT+PLOT
    IF (.NOT. (FOUND_PRINT .OR. FOUND_PLOT .OR. FOUND_PUNCH)) THEN
      REQUEST_OUT%WRITE_F06 = .TRUE.
      REQUEST_OUT%WRITE_OP2 = .TRUE.
    END IF
  END SUBROUTINE COMPUTE_OUTPUT_TARGETS
END MODULE COMPUTE_OUTPUT_TARGETS_MOD
