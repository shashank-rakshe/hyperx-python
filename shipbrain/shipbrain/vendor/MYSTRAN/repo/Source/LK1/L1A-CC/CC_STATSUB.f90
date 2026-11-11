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

      SUBROUTINE CC_STATSUB ( CARD )

! Processes Case Control STATSUB entries for SOL 105 buckling. Syntax accepted:
!   STATSUB           = n
!   STATSUB(PRELOAD)  = n
! The describer (BUCKLING) is recognized and rejected as FATAL since nonlinear preload integration is not implemented.
! "n" is a static SUBCASE id (the external subcase number) whose linear-static solution provides the prestress used to
! build KGGD for the buckling eigenproblem in this subcase. Resolution of "n" against the actual subcase table happens
! later in LOADC, after all SUBCASE cards have been seen.

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06
      USE SCONTR, ONLY                :  WARN_ERR, BLNK_SUB_NAM, FATAL_ERR, NSUB
      USE TIMDAT, ONLY                :  TSEC
      USE PARAMS, ONLY                :  SUPWARN
      USE MODEL_STUF, ONLY            :  CC_STATSUB_DECK, CC_STATSUB_SUB

      USE CC_STATSUB_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'CC_STATSUB'
      CHARACTER(LEN=*), INTENT(IN)    :: CARD              ! A Case Control card

      INTEGER(LONG)                   :: SETID             ! Integer following '=' on the card (the static subcase id)
      INTEGER(LONG)                   :: LP, RP            ! Positions of '(' and ')' in CARD (0 if absent)
      INTEGER(LONG)                   :: EQ                ! Position of '=' in CARD




! **********************************************************************************************************************************
! Process STATSUB cards

      ! Detect an optional describer ( PRELOAD or BUCKLING ) before the '=' sign.
      EQ = INDEX(CARD,'=')
      LP = INDEX(CARD,'(')
      RP = INDEX(CARD,')')

      IF ((LP > 0) .AND. (RP > LP) .AND. ((EQ == 0) .OR. (LP < EQ))) THEN
         IF (INDEX(CARD(LP+1:RP-1),'BUCKLING') > 0) THEN
            FATAL_ERR = FATAL_ERR + 1
            WRITE(ERR,9881)
            WRITE(F06,9881)
            RETURN
         ENDIF
         ! Any describer other than PRELOAD is treated as a warning. Empty describer is silently accepted.
         IF ((INDEX(CARD(LP+1:RP-1),'PRELOAD') == 0) .AND. (LEN_TRIM(CARD(LP+1:RP-1)) > 0)) THEN
            WARN_ERR = WARN_ERR + 1
            WRITE(ERR,9882) CARD(LP:RP)
            IF (SUPWARN == 'N') THEN
               WRITE(F06,9882) CARD(LP:RP)
            ENDIF
         ENDIF
      ENDIF

      ! Pull the integer following '=' (this is a SUBCASE id, not a bulk-data set id, but the parser is identical).
      CALL GET_SETID ( CARD, SETID )

      ! Record the per-subcase or deck-level value. NSUB is incremented by CC_SUBC at parse time, so:
      !   * NSUB == 0  -> this STATSUB appears above any SUBCASE card; it is the deck-default that any subcase lacking
      !                   its own STATSUB inherits during LOADC's post-parse pass.
      !   * NSUB >  0  -> this STATSUB belongs to the current (most-recently-opened) subcase.

      IF (NSUB == 0) THEN

         IF ((CC_STATSUB_DECK /= 0) .AND. (CC_STATSUB_DECK /= SETID)) THEN
            WARN_ERR = WARN_ERR + 1
            WRITE(ERR,9883) CC_STATSUB_DECK, SETID
            IF (SUPWARN == 'N') THEN
               WRITE(F06,9883) CC_STATSUB_DECK, SETID
            ENDIF
         ENDIF
         CC_STATSUB_DECK = SETID

      ELSE

         IF (ALLOCATED(CC_STATSUB_SUB)) THEN
            IF ((CC_STATSUB_SUB(NSUB) /= 0) .AND. (CC_STATSUB_SUB(NSUB) /= SETID)) THEN
               WARN_ERR = WARN_ERR + 1
               WRITE(ERR,9884) NSUB, CC_STATSUB_SUB(NSUB), SETID
               IF (SUPWARN == 'N') THEN
                  WRITE(F06,9884) NSUB, CC_STATSUB_SUB(NSUB), SETID
               ENDIF
            ENDIF
            CC_STATSUB_SUB(NSUB) = SETID
         ENDIF

      ENDIF



      RETURN

! **********************************************************************************************************************************
 9881 FORMAT(' *ERROR  9881: STATSUB(BUCKLING) IS NOT SUPPORTED. ONLY STATSUB(PRELOAD) (OR THE EQUIVALENT BARE "STATSUB=n")',       &
             ' IS RECOGNIZED.')
 9882 FORMAT(' *WARNING    : UNRECOGNIZED DESCRIBER ',A,' ON STATSUB CASE CONTROL ENTRY. PRELOAD INTERPRETATION ASSUMED.')
 9883 FORMAT(' *WARNING    : MORE THAN ONE DECK-LEVEL STATSUB ENTRY IN CASE CONTROL. PREVIOUS VALUE = ',I8,', NEW VALUE = ',I8,     &
             '. NEW VALUE WILL BE USED AS THE DECK DEFAULT.')
 9884 FORMAT(' *WARNING    : MORE THAN ONE STATSUB ENTRY IN SUBCASE ',I8,'. PREVIOUS VALUE = ',I8,', NEW VALUE = ',I8,              &
             '. NEW VALUE WILL BE USED.')

! **********************************************************************************************************************************

      END SUBROUTINE CC_STATSUB
