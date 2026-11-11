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

      SUBROUTINE CC_METH ( CARD )

! Processes Case Control eigenvalue METHOD cards

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  WARN_ERR, BLNK_SUB_NAM, NSUB
      USE TIMDAT, ONLY                :  TSEC
      USE PARAMS, ONLY                :  SUPWARN
      USE MODEL_STUF, ONLY            :  CC_EIGR_SID, CC_EIGR_SID_SUB, CC_EIGR_SID_DECK, IS_MODES_SUBCASE

      USE CC_METH_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'CC_METH'
      CHARACTER(LEN=*), INTENT(IN)    :: CARD              ! A Bulk Data card

      INTEGER(LONG)                   :: SETID             ! Set ID on this Case Control card




! **********************************************************************************************************************************
! Process METHOD cards

! Get SETID

      CALL GET_SETID ( CARD, SETID )

! Record per-subcase METHOD assignment so that SOL 103 decks can request a different set of modes for each subcase.
! NSUB is incremented by CC_SUBC at parse time, so:
!   * NSUB == 0  -> this METHOD appears above any SUBCASE card; it is the deck-default that any subcase lacking its own
!                   METHOD inherits during LOADC's post-parse pass.
!   * NSUB >  0  -> this METHOD belongs to the current (most-recently-opened) subcase.

      IF (NSUB == 0) THEN

         IF ((CC_EIGR_SID_DECK /= 0) .AND. (CC_EIGR_SID_DECK /= SETID)) THEN
            WARN_ERR = WARN_ERR + 1
            WRITE(ERR,8867) CC_EIGR_SID_DECK, SETID
            IF (SUPWARN == 'N') THEN
               WRITE(F06,8867) CC_EIGR_SID_DECK, SETID
            ENDIF
         ENDIF
         CC_EIGR_SID_DECK = SETID

      ELSE

         IF (ALLOCATED(CC_EIGR_SID_SUB)) THEN
            IF ((CC_EIGR_SID_SUB(NSUB) /= 0) .AND. (CC_EIGR_SID_SUB(NSUB) /= SETID)) THEN
               WARN_ERR = WARN_ERR + 1
               WRITE(ERR,8868) NSUB, CC_EIGR_SID_SUB(NSUB), SETID
               IF (SUPWARN == 'N') THEN
                  WRITE(F06,8868) NSUB, CC_EIGR_SID_SUB(NSUB), SETID
               ENDIF
            ENDIF
            CC_EIGR_SID_SUB(NSUB) = SETID
            IS_MODES_SUBCASE(NSUB) = 'Y'
         ENDIF

      ENDIF

! Maintain the legacy scalar CC_EIGR_SID so existing single-METHOD code paths (BD_EIGR scalar match, WRITE_L1Z, restart
! sanity check, etc.) continue to work unchanged. After LOADC inheritance the scalar reflects the last seen SID.

      CC_EIGR_SID = SETID



      RETURN

! **********************************************************************************************************************************
 8867 FORMAT(' *WARNING    : MORE THAN ONE DECK-LEVEL METHOD ENTRY IN CASE CONTROL. PREVIOUS SET ID = ',I8,', NEW SET ID = ',I8,    &
             '. NEW VALUE WILL BE USED AS THE DECK DEFAULT.')
 8868 FORMAT(' *WARNING    : MORE THAN ONE METHOD ENTRY IN SUBCASE ',I8,'. PREVIOUS SET ID = ',I8,', NEW SET ID = ',I8,             &
             '. NEW VALUE WILL BE USED.')

! **********************************************************************************************************************************

      END SUBROUTINE CC_METH
