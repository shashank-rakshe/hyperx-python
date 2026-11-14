! File: src/CableDyn_PathIO.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_PathIO
  !! File names for the Fortran I/O statements. Names are carried as UTF-8 inside the
  !! program (command-line arguments and the paths a UTF-8 deck names) and converted,
  !! right before an OPEN, to the spelling the narrow Fortran runtime opens exactly
  !! (src/cabledyn_path.c). On Windows that conversion refuses reserved device names
  !! and never lets the ANSI code page substitute a look-alike character, so a name is
  !! either opened exactly or rejected with a reason; on other systems it is the
  !! identity.
  USE, INTRINSIC :: ISO_C_BINDING, ONLY: C_CHAR, C_INT, C_NULL_CHAR
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Get_Argument, CD_Native_Path, CD_Open_Input, CD_Open_Read, CD_Open_Write, CD_Path_Openable
  PUBLIC :: CD_Path_Is_Device, CD_Lock_Path
  PUBLIC :: CD_Strip_BOM

  !> CD_Native_Path status: converted, a reserved device name, a name the ANSI code
  !> page cannot represent (with no 8.3 short spelling), a name longer than the path
  !> limit (with no shorter spelling), or another conversion failure.
  INTEGER, PARAMETER, PUBLIC :: CD_PATH_OK = 0, CD_PATH_ERR_GENERAL = -1, CD_PATH_ERR_DEVICE = -2, &
                                CD_PATH_ERR_UNREPRESENTABLE = -3, CD_PATH_ERR_TOO_LONG = -4
  !> CD_Lock_Path result: the lock is held by this process, held by another process,
  !> or could not be created.
  INTEGER, PARAMETER, PUBLIC :: CD_LOCK_ACQUIRED = 0, CD_LOCK_HELD = 1, CD_LOCK_FAILED = 2

  ! Longest converted name (the Windows extended-length limit, in UTF-8 bytes).
  INTEGER, PARAMETER :: NATIVE_BUFLEN = 4*32768
  ! UTF-8 byte-order mark.
  CHARACTER(3), PARAMETER :: UTF8_BOM = CHAR(239)//CHAR(187)//CHAR(191)

  INTERFACE
    FUNCTION c_path_arg_count() RESULT(n) BIND(C, name='cabledyn_path_arg_count')
      IMPORT :: C_INT
      INTEGER(C_INT) :: n
    END FUNCTION c_path_arg_count
    FUNCTION c_path_arg(idx, buf, buflen) RESULT(n) BIND(C, name='cabledyn_path_arg')
      IMPORT :: C_INT, C_CHAR
      INTEGER(C_INT), VALUE :: idx, buflen
      CHARACTER(KIND=C_CHAR), INTENT(OUT) :: buf(*)
      INTEGER(C_INT) :: n
    END FUNCTION c_path_arg
    FUNCTION c_path_native(in, in_len, for_output, reserve, out, outlen) RESULT(n) &
      BIND(C, name='cabledyn_path_native')
      IMPORT :: C_INT, C_CHAR
      CHARACTER(KIND=C_CHAR), INTENT(IN) :: in(*)
      INTEGER(C_INT), VALUE :: in_len, for_output, reserve, outlen
      CHARACTER(KIND=C_CHAR), INTENT(OUT) :: out(*)
      INTEGER(C_INT) :: n
    END FUNCTION c_path_native
    PURE FUNCTION c_path_is_device(in, in_len) RESULT(n) BIND(C, name='cabledyn_path_is_device')
      IMPORT :: C_INT, C_CHAR
      CHARACTER(KIND=C_CHAR), INTENT(IN) :: in(*)
      INTEGER(C_INT), VALUE :: in_len
      INTEGER(C_INT) :: n
    END FUNCTION c_path_is_device
    FUNCTION c_path_lock(in, in_len) RESULT(n) BIND(C, name='cabledyn_path_lock')
      IMPORT :: C_INT, C_CHAR
      CHARACTER(KIND=C_CHAR), INTENT(IN) :: in(*)
      INTEGER(C_INT), VALUE :: in_len
      INTEGER(C_INT) :: n
    END FUNCTION c_path_lock
    FUNCTION c_path_probe(in, in_len, for_output) RESULT(n) BIND(C, name='cabledyn_path_probe')
      IMPORT :: C_INT, C_CHAR
      CHARACTER(KIND=C_CHAR), INTENT(IN) :: in(*)
      INTEGER(C_INT), VALUE :: in_len, for_output
      INTEGER(C_INT) :: n
    END FUNCTION c_path_probe
  END INTERFACE

CONTAINS

  SUBROUTINE CD_Get_Argument(index, value, length, status)
    !! GET_COMMAND_ARGUMENT with the argument as UTF-8. On Windows the argument is
    !! taken from the wide command line (the narrow one has already lost characters
    !! outside the ANSI code page); elsewhere the runtime's argument is used.
    !! status: 0 success, -1 value too short for the argument, > 0 not retrievable.
    INTEGER, INTENT(IN) :: index
    CHARACTER(*), INTENT(OUT) :: value
    INTEGER, INTENT(OUT) :: length, status
    CHARACTER(KIND=C_CHAR), ALLOCATABLE :: buf(:)
    INTEGER :: n, i

    value = ''
    length = 0
    status = 0
    IF (c_path_arg_count() /= COMMAND_ARGUMENT_COUNT()) THEN
      CALL GET_COMMAND_ARGUMENT(index, value, LENGTH=length, STATUS=status)
      RETURN
    END IF
    ALLOCATE (buf(MAX(1, LEN(value)) + 1))
    n = c_path_arg(INT(index, C_INT), buf, INT(SIZE(buf), C_INT))
    IF (n < 0) THEN
      status = 1
      RETURN
    END IF
    length = n
    IF (n > LEN(value)) THEN
      status = -1
      RETURN
    END IF
    DO i = 1, n
      value(i:i) = buf(i)
    END DO
  END SUBROUTINE CD_Get_Argument

  SUBROUTINE CD_Native_Path(path, native, stat, reason, for_output, reserve)
    !! The spelling of path (trailing blanks ignored) that the Fortran runtime opens
    !! exactly. for_output marks a name that may not exist yet (its parent directory
    !! must); reserve is the number of characters the caller will append (an output
    !! root's suffixes). On failure native is path itself, stat is a CD_PATH_ERR_*
    !! code, and reason explains it.
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(:), ALLOCATABLE, INTENT(OUT) :: native
    INTEGER, INTENT(OUT) :: stat
    CHARACTER(*), INTENT(OUT) :: reason
    LOGICAL, INTENT(IN), OPTIONAL :: for_output
    INTEGER, INTENT(IN), OPTIONAL :: reserve
    CHARACTER(KIND=C_CHAR), ALLOCATABLE :: out(:)
    INTEGER :: n, i, mode, extra

    reason = ''
    mode = 0
    IF (PRESENT(for_output)) THEN
      IF (for_output) mode = 1
    END IF
    extra = 0
    IF (PRESENT(reserve)) extra = MAX(0, reserve)
    n = LEN_TRIM(path)
    ALLOCATE (out(NATIVE_BUFLEN))
    n = c_path_native(path, INT(n, C_INT), INT(mode, C_INT), INT(extra, C_INT), out, INT(SIZE(out), C_INT))
    IF (n < 0) THEN
      native = TRIM(path)
      stat = n
      SELECT CASE (n)
      CASE (CD_PATH_ERR_DEVICE)
        reason = 'the name is a reserved Windows device (CON, PRN, AUX, NUL, COM1-9, LPT1-9), '// &
                 'which blocks on the console or discards data; choose another file name'
      CASE (CD_PATH_ERR_UNREPRESENTABLE)
        reason = 'the name has characters the Windows ANSI code page cannot represent and the '// &
                 'file (or its folder) has no 8.3 short name; rename it with characters of the '// &
                 'system code page'
      CASE (CD_PATH_ERR_TOO_LONG)
        reason = 'the full path is longer than the Windows limit of 259 characters and has no '// &
                 'shorter spelling; use a shorter folder path'
      CASE DEFAULT
        stat = CD_PATH_ERR_GENERAL
        reason = 'the name cannot be converted for the file system'
      END SELECT
      RETURN
    END IF
    stat = CD_PATH_OK
    ALLOCATE (CHARACTER(n) :: native)
    DO i = 1, n
      native(i:i) = out(i)
    END DO
  END SUBROUTINE CD_Native_Path

  SUBROUTINE CD_Open_Input(unit, path, ios, reason)
    !! OPEN an existing file for sequential formatted reading by its UTF-8 name.
    !! ios /= 0 on failure; reason is non-blank when the name itself was refused
    !! (a device name, or a name that cannot be spelled for the runtime) and blank
    !! when the OPEN statement failed (typically a missing file).
    INTEGER, INTENT(OUT) :: unit, ios
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(OUT) :: reason
    CHARACTER(:), ALLOCATABLE :: native
    INTEGER :: stat

    unit = -1
    CALL CD_Native_Path(path, native, stat, reason)
    IF (stat /= CD_PATH_OK) THEN
      ios = 1
      RETURN
    END IF
    CALL CD_Open_Read(unit, native, ios)
  END SUBROUTINE CD_Open_Input

  SUBROUTINE CD_Open_Read(unit, name, ios)
    !! OPEN the existing file name (a runtime spelling, such as one CD_Native_Path gave) for
    !! sequential formatted reading. ios /= 0 on failure: the OPEN's IOSTAT, or 1 when
    !! CD_Path_Openable refused the name and no OPEN was attempted.
    INTEGER, INTENT(OUT) :: unit, ios
    CHARACTER(*), INTENT(IN) :: name

    unit = -1
    ios = 1
    IF (.NOT. CD_Path_Openable(name, .FALSE.)) RETURN
    OPEN (NEWUNIT=unit, FILE=name, STATUS='OLD', ACTION='READ', IOSTAT=ios)
  END SUBROUTINE CD_Open_Read

  SUBROUTINE CD_Open_Write(unit, name, ios, status)
    !! OPEN name (a runtime spelling: one CD_Native_Path gave, or an output root's spelling
    !! with a suffix) for sequential formatted writing, STATUS 'REPLACE' or, given, status.
    !! ios /= 0 on failure: the OPEN's IOSTAT, or 1 when CD_Path_Openable refused the name
    !! and no OPEN was attempted.
    INTEGER, INTENT(OUT) :: unit, ios
    CHARACTER(*), INTENT(IN) :: name
    CHARACTER(*), INTENT(IN), OPTIONAL :: status

    unit = -1
    ios = 1
    IF (.NOT. CD_Path_Openable(name, .TRUE.)) RETURN
    IF (PRESENT(status)) THEN
      OPEN (NEWUNIT=unit, FILE=name, STATUS=status, ACTION='WRITE', IOSTAT=ios)
    ELSE
      OPEN (NEWUNIT=unit, FILE=name, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    END IF
  END SUBROUTINE CD_Open_Write

  LOGICAL FUNCTION CD_Path_Openable(name, for_output) RESULT(openable)
    !! Whether the system opens name (a runtime spelling, trailing blanks ignored) for
    !! reading an existing file or, with for_output, for writing (a missing file is then
    !! created empty, an existing one left as it is). Every OPEN of a user-supplied name asks
    !! here first and is not attempted when the answer is no: the Intel Fortran run-time
    !! (ifx 2025.3, Windows) ends the process with a stack buffer overrun (0xC0000409) while
    !! it formats the error of a failing OPEN of a name of about 600 characters or more (the
    !! extended-length \\?\ spelling CD_Native_Path gives a long path), where an INQUIRE or
    !! this probe returns.
    CHARACTER(*), INTENT(IN) :: name
    LOGICAL, INTENT(IN) :: for_output
    INTEGER(C_INT) :: mode

    mode = 0_C_INT
    IF (for_output) mode = 1_C_INT
    openable = c_path_probe(name, INT(LEN_TRIM(name), C_INT), mode) == 0_C_INT
  END FUNCTION CD_Path_Openable

  PURE LOGICAL FUNCTION CD_Path_Is_Device(path) RESULT(is_device)
    !! True on Windows when any component of path is a reserved device name.
    CHARACTER(*), INTENT(IN) :: path
    is_device = c_path_is_device(path, INT(LEN_TRIM(path), C_INT)) /= 0
  END FUNCTION CD_Path_Is_Device

  INTEGER FUNCTION CD_Lock_Path(path) RESULT(stat)
    !! Take an exclusive lock file at the UTF-8 name path for the rest of the process
    !! (CD_LOCK_ACQUIRED, CD_LOCK_HELD, or CD_LOCK_FAILED). The lock ends with the
    !! process, including a killed one; a normal exit also removes the file.
    CHARACTER(*), INTENT(IN) :: path
    stat = INT(c_path_lock(path//C_NULL_CHAR, INT(LEN_TRIM(path), C_INT)))
  END FUNCTION CD_Lock_Path

  PURE SUBROUTINE CD_Strip_BOM(record)
    !! Remove a leading UTF-8 byte-order mark (the first record of a file saved by an
    !! editor that writes one).
    CHARACTER(*), INTENT(INOUT) :: record
    IF (LEN(record) < 3) RETURN
    IF (record(1:3) == UTF8_BOM) record = record(4:)
  END SUBROUTINE CD_Strip_BOM

END MODULE CableDyn_PathIO
