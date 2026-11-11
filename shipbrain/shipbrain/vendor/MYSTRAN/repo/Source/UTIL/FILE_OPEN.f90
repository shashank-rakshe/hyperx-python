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

      SUBROUTINE FILE_OPEN (UNIT, FILNAM, OUNT, STATUS, MESSAG, RW_STIME, FORMAT, ACTION, POSITION, WRITE_L1A, WRITE_VER)

      ! Opens formatted files that have STIME for read or write. If open for read, check STIME. If open for write, write STIME
      ! If file needs to be opened for READWRITE, this subr needs to be called twice:
      !     (1) called 1st time for READ (to open file and to read and check STIME)
      !     (2) called 2nd time (after closing by calling subr) to position at end for subsequent writing after returning
      !
      ! Parameters
      ! ----------
      ! UNIT : int
      !    the file number to open
      ! FILNAM : str
      !    the filename to open
      ! OUNT : tuple[int, int]
      !    I think this is Bill's black magic for handling fortran files...
      ! STATUS : str8
      !    not checked....
      !    'NEW': creates a new file
      !    'OLD': opens an existing file
      !    'REPLACE' : If the file doesn't exist, it creates it. If it does exist, then it replaces it.
      !    'UNKNOWN' : ???
      ! MESSAG : str
      !    used for error messages
      ! RW_STIME : ???
      !    'READ_STIME'  : read the stime?
      !    'WRITE_STIME' : write the stime?
      !    'NEITHER'     : skip this
      ! FORMAT : str
      !    'FORMATTED'   : for ASCII files
      !    'UNFORMATTED' : for binary files that have records
      !    'BINARY'      : binary files, but you get to handle everything; no ACCESS or RECL
      !    'SYSTEM'      : ???; no ACCESS or RECL
      !    Opening a file with FORM='BINARY' has roughly the same effect as FORM='UNFORMATTED', except
      !    that no record lengths are embedded in the file. Without this data, there is no way to tell
      !    where one record begins, or ends. Thus, it is impossible to BACKSPACE a FORM='BINARY' file,
      !    because there is no way of telling where to backspace to. A READ on a 'BINARY' file will read
      !    as much data as needed to fill the variables on the input list.
      ! ACTION : str8
      !    'READ' : open the file for reading
      !    'WRITE': open the file for writing
      !    'READWRITE': ???
      ! POSITION : str8
      !    'ASIS'   : ???
      !    'APPEND' : open the file in append mode
      !    'REWIND' : start from the beginning of the file
      ! RW_STIME : ???
      !    ???
      ! WRITE_L1A : str1
      !    Y/N : write to L1A???
      ! WRITE_VER : str1
      !    Y/N : write to VER???
      !
      ! Unused
      ! -------
      ! ACCESS : str
      !    'SEQUENTIAL' : ???; FILE_OPEN always uses this
      !    'DIRECT'     : ???
      !    'STREAM'     : ???
      ! DIRECT="NO"
      ! RECL : int / None
      !    this is not modifyable per block; record_length
      !    int : the size of the record length; if you go over the size, it'll 0-pad
      !    None: automatic
      !
      ! Examples
      ! --------
      ! FILE_OPEN ( OP2, OP2FIL, OUNT,'OLD    ', OP2_MSG,'NEITHER','UNFORMATTED','WRITE','REWIND','N','N')
      !
      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  F06, IN1, SC1, WRT_ERR
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, PROG_NAME
      USE TIMDAT, ONLY                :  STIME, TSEC
      USE DEBUG_PARAMETERS
      USE MYSTRAN_Version, ONLY       :  MYSTRAN_VER_NUM, MYSTRAN_VER_MONTH, MYSTRAN_VER_DAY, MYSTRAN_VER_YEAR, MYSTRAN_AUTHOR,  &
                                         MYSTRAN_COMMENT

      USE FILE_OPEN_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'FILE_OPEN'
      CHARACTER(LEN=*), INTENT(IN)    :: ACTION            ! File description
      CHARACTER(LEN=*), INTENT(IN)    :: FILNAM            ! File name
      CHARACTER(LEN=*), INTENT(IN)    :: FORMAT            ! File format
      CHARACTER(LEN=*), INTENT(IN)    :: MESSAG            ! File description
      CHARACTER(LEN=*), INTENT(IN)    :: POSITION          ! File error message
      CHARACTER(LEN=*), INTENT(IN)    :: STATUS            ! File status indicator (NEW, OLD, REPLACE)
      CHARACTER(LEN=*), INTENT(IN)    :: RW_STIME          ! Indicator of whether to read or write STIME
      CHARACTER(LEN=*), INTENT(IN)    :: WRITE_L1A         ! 'Y'/'N' Arg passed to subr OUTA_HERE
      CHARACTER(LEN=*), INTENT(IN)    :: WRITE_VER         ! 'Y'/'N' Arg to tell whether to write MYSTRAN version info
      CHARACTER( 9*BYTE)              :: NAM_ACT
      CHARACTER(11*BYTE)              :: NAM_FOR
      CHARACTER( 6*BYTE)              :: NAM_POS
      CHARACTER( 7*BYTE)              :: NAM_STA
      CHARACTER(11*BYTE)              :: NAM_RWS

      INTEGER(LONG), INTENT(IN)       :: UNIT              ! Unit number file is attached to
      INTEGER(LONG), INTENT(IN)       :: OUNT(2)           ! File units to write messages to. Input to subr FILE_OPEN
      INTEGER(LONG)                   :: I                 ! DO loop index
      INTEGER(LONG)                   :: IERR              ! Error count
      INTEGER(LONG)                   :: IOCHK             ! IOSTAT error number when opening/reading a file
      INTEGER(LONG)                   :: REC_NO            ! Record number when reading a file
      INTEGER(LONG)                   :: XTIME             ! Time stamp read from file




! **********************************************************************************************************************************
      ! Check inputs for sensibility (coding errors if wrong)
      IERR = 0

      ! Check FORM
      IF ((FORMAT /= 'FORMATTED') .AND. (FORMAT /= 'UNFORMATTED') .AND. (FORMAT /= 'BINARY'))THEN
         IERR = IERR + 1
         DO I=1,2
            IF (OUNT(I) > 0) THEN
               WRITE(OUNT(I),909) SUBR_NAME, 'FORMAT', 'FORMATTED, UNFORMATTED or BINARY', FORMAT
            ELSE
               WRITE(SC1,909) SUBR_NAME, 'FORMAT', 'FORMATTED, UNFORMATTED or BINARY', FORMAT
            ENDIF
            IF (OUNT(2) == OUNT(1)) EXIT
         ENDDO
      ENDIF

      ! Check ACTION
      IF ((ACTION /= 'READ') .AND. (ACTION /= 'WRITE') .AND. (ACTION /= 'READWRITE')) THEN
         IERR = IERR + 1
         DO I=1,2
            IF (OUNT(I) > 0) THEN
               WRITE(OUNT(I),909) SUBR_NAME, 'ACTION', 'READ or WRITE', ACTION
            ELSE
               WRITE(SC1,909) SUBR_NAME, 'ACTION', 'READ or WRITE', ACTION
            ENDIF
            IF (OUNT(2) == OUNT(1)) EXIT
         ENDDO
      ENDIF

      ! Check POSITION
      IF ((POSITION /= 'ASIS') .AND. (POSITION /= 'APPEND') .AND. (POSITION /= 'REWIND')) THEN
         IERR = IERR + 1
         DO I=1,2
            IF (OUNT(I) > 0) THEN
               WRITE(OUNT(I),909) SUBR_NAME, 'POSITION', 'ASIS or APPEND or REWIND', POSITION
            ELSE
               WRITE(SC1,909) SUBR_NAME, 'POSITION', 'ASIS or APPEND or REWIND', POSITION
            ENDIF
            IF (OUNT(2) == OUNT(1)) EXIT
         ENDDO
      ENDIF

      ! Check STATUS
!     IF ((STATUS /= 'NEW') .AND.(STATUS /= 'OLD') .AND.(STATUS /= 'REPLACE')) THEN
!        IERR = IERR + 1
!        DO I=1,2
!           IF (OUNT(I) > 0) THEN
!              WRITE(OUNT(I),909) SUBR_NAME, 'STATUS', 'NEW or OLD or REPLACE', STATUS
!           ELSE
!              WRITE(SC1,909) SUBR_NAME, 'STATUS', 'NEW or OLD or REPLACE', STATUS
!           ENDIF
!           IF (OUNT(2) == OUNT(1)) EXIT
!        ENDDO
!     ENDIF

      ! Check WRITE_L1A
      IF ((WRITE_L1A /= 'Y') .AND. (WRITE_L1A /= 'N'))THEN
         IERR = IERR + 1
         DO I=1,2
            IF (OUNT(I) > 0) THEN
               WRITE(OUNT(I),909) SUBR_NAME, 'WRITE_L1A', 'Y or N', WRITE_L1A
            ELSE
               WRITE(SC1,909) SUBR_NAME, 'WRITE_L1A', 'Y or N', WRITE_L1A
            ENDIF
            IF (OUNT(2) == OUNT(1)) EXIT
         ENDDO
      ENDIF

      ! Check WRITE_STIME
      IF ((RW_STIME /= 'READ_STIME') .AND. (RW_STIME /= 'WRITE_STIME') .AND. (RW_STIME /= 'NEITHER'))THEN
         IERR = IERR + 1
         DO I=1,2
            IF (OUNT(I) > 0) THEN
               WRITE(OUNT(I),909) SUBR_NAME, 'RW_STIME', 'READ_STIME, WRITE_STIME or NEITHER', RW_STIME
            ELSE
               WRITE(SC1,909) SUBR_NAME, 'RW_STIME', 'READ, WRITE or NEITHER', RW_STIME
            ENDIF
            IF (OUNT(2) == OUNT(1)) EXIT
         ENDDO
      ENDIF

      IF ((WRITE_VER /= 'Y') .AND. (WRITE_VER /= 'N'))THEN
         IERR = IERR + 1
         DO I=1,2
            IF (OUNT(I) > 0) THEN
               WRITE(OUNT(I),909) SUBR_NAME, 'WRITE_VER', 'Y or N', WRITE_VER
            ELSE
               WRITE(SC1,909) SUBR_NAME, 'WRITE_VER', 'Y or N', WRITE_VER
            ENDIF
            IF (OUNT(2) == OUNT(1)) EXIT
         ENDDO
      ENDIF

      IF (IERR > 0) THEN
         FATAL_ERR = FATAL_ERR + 1
         IF (WRITE_L1A == 'Y') THEN
            CALL OUTA_HERE ( 'Y' )
         ELSE
            CALL OUTA_HERE ( 'N' )
         ENDIF
      ENDIF

      ! No problems with inputs, so proceed to open file
      IERR = 0
      OPEN ( UNIT, FILE=FILNAM, STATUS=STATUS, FORM=FORMAT, ACCESS='SEQUENTIAL', ACTION=ACTION, POSITION=POSITION, IOSTAT=IOCHK )

      IF (DEBUG(52) > 0) THEN
         CALL DEB_FILE_OPEN
      ENDIF

      IF (IOCHK == 0) THEN
         IF      (RW_STIME == 'READ_STIME') THEN           ! Read and check STIME
            IF (FORMAT == 'FORMATTED') THEN
               READ(UNIT,'(1X,I11)',IOSTAT=IOCHK) XTIME
            ELSE
               READ(UNIT,IOSTAT=IOCHK) XTIME
            ENDIF
            IF (IOCHK /= 0) THEN
               REC_NO = 1
               CALL READERR ( IOCHK, FILNAM, MESSAG, REC_NO, OUNT )
               IERR = IERR + 1
            ELSE
               IF (XTIME /= STIME) THEN
                  CALL STMERR ( XTIME, FILNAM, OUNT )
                  IERR = IERR +1
               ENDIF
            ENDIF
         ELSE IF (RW_STIME == 'WRITE_STIME') THEN          ! Write STIME
            IF (FORMAT == 'FORMATTED') THEN
               WRITE(UNIT,'(1X,I11)') STIME
            ELSE
               WRITE(UNIT) STIME
            ENDIF
            IF (WRITE_VER == 'Y') THEN
               WRITE(UNIT,117) PROG_NAME, MYSTRAN_VER_NUM, MYSTRAN_VER_MONTH, MYSTRAN_VER_DAY, MYSTRAN_VER_YEAR,                &
                               MYSTRAN_AUTHOR, MYSTRAN_COMMENT
            ENDIF
         ENDIF
      ELSE
         CALL OPNERR ( IOCHK, FILNAM, OUNT )
         IERR = IERR +1
      ENDIF

      IF (IERR > 0) THEN
         CALL FILERR ( OUNT )
         CALL OUTA_HERE ( 'Y' )
      ENDIF


      RETURN

! **********************************************************************************************************************************
  909 FORMAT(' *ERROR   909: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' ILLEGAL INPUT FOR ARGUMENT ',A,'. MUST BE ',A,' BUT IS "',A,'". ERROR OCCURRED OPENING FILE:')

  117 FORMAT(/,1X,A,' Version',5(1X,A),/,A)

  118 FORMAT(/,1X,A,' Version',5(1X,A),/)

! ##################################################################################################################################

      CONTAINS

! ##################################################################################################################################

      SUBROUTINE DEB_FILE_OPEN

      IMPLICIT NONE

! **********************************************************************************************************************************
      WRITE(F06,98720)

      WRITE(F06,'(A,I8)') ' In file OPEN, UNIT     = ', UNIT
      WRITE(F06,'(A,A) ') ' In file OPEN, FILE     = ', FILNAM(1:40)
      WRITE(F06,'(A,A) ') ' In file OPEN, STATUS   = ', STATUS
      WRITE(F06,'(A,A) ') ' In file OPEN, FORM     = ', FORMAT
      WRITE(F06,'(A,A) ') ' In file OPEN, ACTION   = ', ACTION
      WRITE(F06,'(A,A) ') ' In file OPEN, POSITION = ', POSITION
      WRITE(F06,'(A,I8)') ' In file OPEN, IOCHK    = ', IOCHK
      WRITE(F06,*)
      WRITE(F06,*) ' Open ', filnam(1:32), 'RW_STIME, STIME = "', rw_stime, '"   ', stime

      WRITE(F06,*)

      WRITE(F06,98799)

      WRITE(F06,*)

! **********************************************************************************************************************************
98720 FORMAT(' __________________________________________________________________________________________________________________',&
             '_________________'                                                                                               ,//,&
             ' :::::::::::::::::::::::::::::::::::::::::START DEBUG(52) OUTPUT FROM SUBROUTINE FILE_OPEN:::::::::::::::::::::::::',&
             ':::::::::::::::::',/)

98799 FORMAT(' ::::::::::::::::::::::::::::::::::::::::::END DEBUG(52) OUTPUT FROM SUBROUTINE FILE_OPEN::::::::::::::::::::::::::',&
             ':::::::::::::::::'                                                                                                ,/,&
             ' __________________________________________________________________________________________________________________',&
             '_________________',/)

! **********************************************************************************************************************************

      END SUBROUTINE DEB_FILE_OPEN


      END SUBROUTINE FILE_OPEN
