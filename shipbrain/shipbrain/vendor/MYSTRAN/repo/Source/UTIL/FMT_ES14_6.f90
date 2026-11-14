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

      SUBROUTINE FMT_ES14_6 ( V, OUT )

! Hand-rolled formatter that produces the same 14-character output as Fortran's 1ES14.6 edit descriptor,
! but bypasses the (relatively expensive) internal WRITE machinery. Used in the LK9 output pipeline to
! accelerate writing of the F06 file. Exact zeros are emitted as ' 0.000000E+00' to match Fortran's
! native 1ES14.6 output byte-for-byte. (Callers that prefer the WRT_REAL_TO_CHAR_VAR style '  0.0         '
! substitution must perform that replacement themselves.)
!
! Layout of OUT (positions 1..14):
!   1 : leading space
!   2 : sign ('-' or ' ')
!   3 : single mantissa digit
!   4 : '.'
!   5-10 : 6 fractional digits
!   11 : 'E'
!   12 : exponent sign ('+' or '-')
!   13-14 : 2-digit exponent
!
! Assumes |decimal exponent| < 100. Values exceeding that range are rare in FEA stress/strain output;
! if encountered the routine falls back to a Fortran internal WRITE so the field is still well formed.

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE CONSTANTS_1, ONLY           :  ZERO

      USE FMT_ES14_6_USE_IFs

      IMPLICIT NONE

      REAL(DOUBLE), INTENT(IN)        :: V                    ! Real value to format
      CHARACTER(14*BYTE), INTENT(OUT) :: OUT                  ! 14-char formatted result

      REAL(DOUBLE)                    :: AV, M
      INTEGER(LONG)                   :: E10, IM, K
      INTEGER(LONG)                   :: DIG(0:6)
      CHARACTER(1*BYTE)               :: ESIGN
      LOGICAL                         :: NEG

      INTEGER(LONG), PARAMETER        :: ZERO_CHAR = IACHAR('0')

! **********************************************************************************************************************************
      IF (V == ZERO) THEN
         OUT = '  0.000000E+00'
         RETURN
      ENDIF

      NEG = V < ZERO
      AV  = ABS(V)

      E10 = FLOOR(LOG10(AV))
      M   = AV * (10.0D0 ** (-E10))

      ! Guard against floating-point rounding in LOG10/FLOOR that could put M outside [1,10).
      IF (M < 1.0D0) THEN
         M   = M * 10.0D0
         E10 = E10 - 1
      ELSE IF (M >= 10.0D0) THEN
         M   = M * 0.1D0
         E10 = E10 + 1
      ENDIF

      IM = NINT(M * 1.0D6, KIND=LONG)
      IF (IM >= 10000000) THEN          ! carry from rounding 9.9999995 -> 10.000000
         IM  = IM / 10
         E10 = E10 + 1
      ENDIF

      ! Fall back to Fortran formatting for the rare |E10| >= 100 case so the field still has 14 chars.
      IF ((E10 >= 100) .OR. (E10 <= -100)) THEN
         WRITE(OUT,'(1ES14.6)') V
         RETURN
      ENDIF

      DO K = 6, 0, -1
         DIG(K) = MOD(IM, 10_LONG)
         IM     = IM / 10
      ENDDO

      IF (E10 < 0) THEN
         ESIGN = '-'
         E10   = -E10
      ELSE
         ESIGN = '+'
      ENDIF

      OUT(1:1)   = ' '
      IF (NEG) THEN
         OUT(2:2) = '-'
      ELSE
         OUT(2:2) = ' '
      ENDIF
      OUT(3:3)   = ACHAR(ZERO_CHAR + DIG(0))
      OUT(4:4)   = '.'
      OUT(5:5)   = ACHAR(ZERO_CHAR + DIG(1))
      OUT(6:6)   = ACHAR(ZERO_CHAR + DIG(2))
      OUT(7:7)   = ACHAR(ZERO_CHAR + DIG(3))
      OUT(8:8)   = ACHAR(ZERO_CHAR + DIG(4))
      OUT(9:9)   = ACHAR(ZERO_CHAR + DIG(5))
      OUT(10:10) = ACHAR(ZERO_CHAR + DIG(6))
      OUT(11:11) = 'E'
      OUT(12:12) = ESIGN
      OUT(13:13) = ACHAR(ZERO_CHAR + E10 / 10)
      OUT(14:14) = ACHAR(ZERO_CHAR + MOD(E10, 10_LONG))

      RETURN

! **********************************************************************************************************************************

      END SUBROUTINE FMT_ES14_6
