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

      SUBROUTINE FMT_I8_RJ ( V, OUT )

! Right-justify a signed integer into an 8-character field, padded with spaces. Produces the same output
! as Fortran's I8 edit descriptor but avoids the internal WRITE machinery. Used in the LK9 output
! pipeline alongside FMT_ES14_6 to accelerate F06 line assembly. Values with more than 8 significant
! digits (counting the sign) fall back to a Fortran internal WRITE so the field stays well formed.

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG

      USE FMT_I8_RJ_USE_IFs

      IMPLICIT NONE

      INTEGER(LONG), INTENT(IN)       :: V                    ! Integer value to format
      CHARACTER(8*BYTE), INTENT(OUT)  :: OUT                  ! 8-char right-justified result

      INTEGER(LONG)                   :: X, K
      INTEGER(LONG), PARAMETER        :: ZERO_CHAR = IACHAR('0')

! **********************************************************************************************************************************
      OUT = '        '

      IF (V == 0) THEN
         OUT(8:8) = '0'
         RETURN
      ENDIF

      ! Overflow guard: an I8 field holds at most 8 chars (sign + 7 digits for negatives, 8 digits for non-negatives).
      IF ((V > 99999999_LONG) .OR. (V < -9999999_LONG)) THEN
         WRITE(OUT,'(I8)') V
         RETURN
      ENDIF

      X = ABS(V)
      K = 8
      DO WHILE ((X > 0) .AND. (K >= 1))
         OUT(K:K) = ACHAR(ZERO_CHAR + MOD(X, 10_LONG))
         X        = X / 10
         K        = K - 1
      ENDDO
      IF ((V < 0) .AND. (K >= 1)) OUT(K:K) = '-'

      RETURN

! **********************************************************************************************************************************

      END SUBROUTINE FMT_I8_RJ
