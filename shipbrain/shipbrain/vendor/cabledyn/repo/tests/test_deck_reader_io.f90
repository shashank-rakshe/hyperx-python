! File: tests/test_deck_reader_io.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_deck_reader_io
  !! Gate for the deck and auxiliary-file readers at the byte level: record framing
  !! (byte-order mark, an unterminated final record that fills the record buffer,
  !! whitespace-only rows, ASCII whitespace separators), rejected characters (NUL and
  !! non-ASCII whitespace outside comments), whole-record section headers, row-level
  !! diagnostics that name the deck line, per-row OPTIONS validation (a shadowed invalid
  !! row still fails), bathymetry grids in any row order, reserved device names, and files
  !! that do not open: a failing OPEN of a name of 600 characters or more ends an ifx-built
  !! program inside the Intel run-time (0xC0000409), so the opens of names beyond the Windows
  !! path limit in a folder that does not exist, and of a folder, must return a status (and
  !! the deck run with such an output root a message) instead; this program then ends.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_Deck_Query_dtM, CD_DECKDRV_OK, CD_DECKDRV_BADINPUT
  USE CableDyn_PathIO, ONLY: CD_Path_Is_Device, CD_Native_Path, CD_PATH_OK, CD_PATH_ERR_DEVICE, &
                             CD_Open_Read, CD_Open_Write, CD_Open_Input, CD_Path_Openable
  IMPLICIT NONE

  CHARACTER(*), PARAMETER :: ANCHOR = '1 Fixed 400.0 0.0 -50.0', SECTION = '1 chain 410.0 41'
  CHARACTER(1), PARAMETER :: LF = ACHAR(10), TAB = ACHAR(9)
  INTEGER :: nfail

  nfail = 0
  CALL check_record_framing()
  CALL check_rejected_characters()
  CALL check_section_headers()
  CALL check_row_diagnostics()
  CALL check_option_rows()
  CALL check_bathymetry_row_order()
  CALL check_waterkin_diagnostics()
  CALL check_device_names()
  CALL check_files_that_do_not_open()
  CALL check_nonfinite_and_subnormal_values()
  CALL check_admissible_magnitudes()
  CALL check_strict_line_attachments()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'test_deck_reader_io: ', nfail, ' check(s) FAILED'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'test_deck_reader_io: all checks passed'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: '//label
    END IF
  END SUBROUTINE require

  FUNCTION chain_deck(point1, extra_option, outputs, point2) RESULT(body)
    !! The WD0050 single-section chain deck (LF-separated records). Deck lines: 5 the
    !! LINE TYPES row, 9 point1, 10 point2, 18 the SECTIONS row, 21.. OPTIONS.
    CHARACTER(*), INTENT(IN) :: point1, extra_option, outputs
    CHARACTER(*), INTENT(IN), OPTIONAL :: point2
    CHARACTER(:), ALLOCATABLE :: body
    body = 'WD0050 reader deck'//LF//'--- LINE TYPES ---'//LF// &
           'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//LF// &
           '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//LF// &
           'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//LF// &
           '--- POINTS ---'//LF//'ID Type X Y Z'//LF//'(-) (-) (m) (m) (m)'//LF//point1//LF
    IF (PRESENT(point2)) THEN
      body = body//point2//LF
    ELSE
      body = body//'2 Coupled 0.0 0.0 0.0'//LF
    END IF
    body = body//'--- LINES ---'//LF//'ID NodeA NodeB Outputs'//LF//'(-) (-) (-) (-)'//LF// &
           '1 2 1 -'//LF//'--- SECTIONS ---'//LF//'LineID LineType Length NumSegs'//LF// &
           '(-) (-) (m) (-)'//LF//SECTION//LF//'--- OPTIONS ---'//LF//'9.80665 g'//LF// &
           '1025.0 rhoW'//LF//'50.0 WtrDpth'//LF//'1.0e5 kBot'//LF
    IF (LEN(extra_option) > 0) body = body//extra_option//LF
    body = body//'--- OUTPUTS ---'//LF//outputs//LF//'--- need this line ---'//LF
  END FUNCTION chain_deck

  SUBROUTINE write_bytes(path, bytes)
    !! Write the exact bytes (stream access: no record terminator is added).
    CHARACTER(*), INTENT(IN) :: path, bytes
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', ACCESS='STREAM', FORM='UNFORMATTED', &
          IOSTAT=ios)
    CALL require(ios == 0, 'open '//path)
    IF (ios /= 0) RETURN
    WRITE (u) bytes
    CLOSE (u)
  END SUBROUTINE write_bytes

  SUBROUTINE parse(path, bytes, es, em)
    !! Write a deck and run the standalone parse (no solve).
    CHARACTER(*), INTENT(IN) :: path, bytes
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp) :: dtm
    LOGICAL :: has_dtm
    CALL write_bytes(path, bytes)
    CALL CD_Deck_Query_dtM(path, dtm, has_dtm, es, em, standalone_scan=.TRUE.)
  END SUBROUTINE parse

  SUBROUTINE expect_ok(path, bytes, what)
    CHARACTER(*), INTENT(IN) :: path, bytes, what
    INTEGER :: es
    CHARACTER(1024) :: em
    CALL parse(path, bytes, es, em)
    CALL require(es == CD_DECKDRV_OK, what//' is accepted: '//TRIM(em))
  END SUBROUTINE expect_ok

  SUBROUTINE expect_bad(path, bytes, what, fragment)
    CHARACTER(*), INTENT(IN) :: path, bytes, what, fragment
    INTEGER :: es
    CHARACTER(1024) :: em
    CALL parse(path, bytes, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT, what//' is rejected: '//TRIM(em))
    CALL require(INDEX(em, fragment) > 0, what//' names "'//fragment//'": '//TRIM(em))
  END SUBROUTINE expect_bad

  SUBROUTINE expect_bad_run(path, bytes, what, fragment)
    !! As expect_bad, through the full standalone run (auxiliary files are read there).
    CHARACTER(*), INTENT(IN) :: path, bytes, what, fragment
    INTEGER :: es
    CHARACTER(1024) :: em
    LOGICAL :: conv
    CALL write_bytes(path, bytes)
    CALL CD_Run_Deck_Driver(path, path//'.run', conv, es, em)
    CALL require(es == CD_DECKDRV_BADINPUT, what//' is rejected: '//TRIM(em))
    CALL require(INDEX(em, fragment) > 0, what//' names "'//fragment//'": '//TRIM(em))
  END SUBROUTINE expect_bad_run

  SUBROUTINE check_record_framing()
    CHARACTER(:), ALLOCATABLE :: body, last
    ! a UTF-8 byte-order mark before line 1 (here a section header) is not deck text
    body = chain_deck(ANCHOR, '', 'FairTen1')
    CALL expect_ok('reader_bom.dat', CHAR(239)//CHAR(187)//CHAR(191)//body(INDEX(body, LF) + 1:), &
                   'deck opening with a byte-order mark before a section header')
    ! an unterminated final record exactly 512 characters long (and one byte longer)
    last = 'FairTen1'//REPEAT(' ', 504)
    body = chain_deck(ANCHOR, '', last)
    body = body(1:INDEX(body, last) + LEN(last) - 1)
    CALL expect_ok('reader_512.dat', body, 'unterminated 512-character final record')
    CALL expect_ok('reader_512_lf.dat', body//LF, 'terminated 512-character final record')
    CALL expect_bad('reader_513.dat', body//'x', 'unterminated 513-character final record', &
                    'longer than 512 characters')
    ! a final record filling the buffer plus a whole remainder chunk
    CALL expect_ok('reader_768.dat', chain_deck(ANCHOR, '', 'FairTen1'//REPEAT(' ', 760))// &
                   '# '//REPEAT('c', 766), 'unterminated comment record of 768 characters')
    ! whitespace-only rows are blank wherever they appear
    CALL expect_ok('reader_tab.dat', chain_deck(ANCHOR, TAB, 'FairTen1'), 'tab-only OPTIONS row')
    CALL expect_ok('reader_ws.dat', chain_deck(ANCHOR, ' '//TAB//ACHAR(12)//ACHAR(11)//ACHAR(13), 'FairTen1'), &
                   'OPTIONS row of mixed ASCII whitespace')
    ! form feed and vertical tab separate tokens like spaces
    CALL expect_ok('reader_vt.dat', chain_deck(ANCHOR, '1.0e4'//ACHAR(11)//'cBot', 'FairTen1'), &
                   'OPTIONS row separated by a vertical tab')
    CALL expect_ok('reader_ff.dat', chain_deck('1'//ACHAR(12)//'Fixed 400.0 0.0 -50.0', '', 'FairTen1'), &
                   'POINTS row separated by a form feed')
  END SUBROUTINE check_record_framing

  SUBROUTINE check_rejected_characters()
    CHARACTER(*), PARAMETER :: NBSP = CHAR(194)//CHAR(160), IDEO = CHAR(227)//CHAR(128)//CHAR(128)
    CALL expect_bad('reader_nul.dat', chain_deck(ANCHOR, '1.0e4 cBot'//ACHAR(0), 'FairTen1'), &
                    'NUL in an OPTIONS row', 'deck line 24 contains a NUL character')
    CALL expect_bad('reader_nbsp.dat', chain_deck('1 Fixed'//NBSP//'400.0 0.0 -50.0', '', 'FairTen1'), &
                    'no-break space in a POINTS row', 'deck line 9 contains a non-ASCII whitespace')
    CALL expect_bad('reader_ideo.dat', chain_deck(ANCHOR, '', IDEO//'FairTen1'), &
                    'ideographic space in an OUTPUTS row', 'non-ASCII whitespace')
    CALL expect_ok('reader_nbsp_comment.dat', chain_deck(ANCHOR, '1.0e4 cBot # note'//NBSP//ACHAR(0), &
                                                         'FairTen1'), 'NUL and no-break space in a comment')
    ! a Hangul syllable (not whitespace) in a comment and in the title is ordinary text
    CALL expect_ok('reader_hangul.dat', CHAR(237)//CHAR(149)//CHAR(156)//chain_deck(ANCHOR, '', 'FairTen1'), &
                   'Hangul title text')
  END SUBROUTINE check_rejected_characters

  SUBROUTINE check_section_headers()
    CHARACTER(:), ALLOCATABLE :: body
    body = chain_deck(ANCHOR, '', 'FairTen1')
    ! a title banner whose "INPUT FILE" lies beyond column 64
    CALL expect_ok('reader_banner.dat', REPEAT('-', 70)//' CableDyn Input File '//REPEAT('-', 20)//LF//body, &
                   'long title banner')
    CALL expect_bad('reader_longname.dat', '--- '//REPEAT('Z', 90)//' ---'//LF//body, 'long unknown header', &
                    'unknown deck section "'//REPEAT('Z', 64)//'..."')
  END SUBROUTINE check_section_headers

  SUBROUTINE check_row_diagnostics()
    CALL expect_bad('reader_dup_point.dat', chain_deck(ANCHOR, '', 'FairTen1', '1 Coupled 0.0 0.0 0.0'), &
                    'duplicate POINT id', 'deck line 10: duplicate POINT id 1')
    CALL expect_bad('reader_nan_point.dat', chain_deck('1 Fixed 400.0 0.0 NaN', '', 'FairTen1'), &
                    'non-finite POINT', 'deck line 9: column 5 value "NaN" is not a finite number')
    CALL expect_bad('reader_channel.dat', chain_deck(ANCHOR, '', 'XYZ'), 'unsupported channel', &
                    'deck line 25: OUTPUT channel "XYZ" not supported')
    CALL expect_bad('reader_negcd.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), '1.37 0.64', &
                                                     '-1.37 0.64'), 'negative Cd', &
                    'deck line 5: LINE TYPES drag and added-mass coefficients')
    CALL expect_bad('reader_numsegs.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), SECTION, &
                                                       '1 chain 410.0 0'), 'NumSegs 0', 'deck line 18: SECTION needs')
    CALL expect_bad('reader_undef.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), '1 2 1 -', '1 2 9 -'), &
                    'undefined POINT reference', 'deck line 14: LINE 1 references undefined POINT id 9')
  END SUBROUTINE check_row_diagnostics

  SUBROUTINE check_option_rows()
    ! every OPTIONS row is validated, including one a later row overrides
    CALL expect_bad('reader_nan_rhow.dat', chain_deck(ANCHOR, 'NaN rhoW'//LF//'1025.0 rhoW', 'FairTen1'), &
                    'shadowed NaN rhoW', 'deck line 24: OPTIONS value "NaN" is not a finite number')
    CALL expect_bad('reader_neg_depth.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), '50.0 WtrDpth', &
                                                         '-5.0 WtrDpth'//LF//'50.0 WtrDpth'), &
                    'shadowed negative WtrDpth', 'OPTION WtrDpth must be positive')
    CALL expect_bad('reader_quad.dat', chain_deck(ANCHOR, '7 axial_quadrature_order'//LF// &
                                                  '4 axial_quadrature_order', 'FairTen1'), &
                    'shadowed quadrature order', 'axial_quadrature_order must be an integer from 1 to 6')
    CALL expect_bad('reader_rhoinf.dat', chain_deck(ANCHOR, '1.5 rhoInf'//LF//'0.4 rhoInf', 'FairTen1'), &
                    'shadowed rhoInf', 'OPTION rhoInf must lie in [0, 1]')
    CALL expect_bad('reader_solver.dat', chain_deck(ANCHOR, 'dynamic_solver -1 1e-14 30 12'//LF// &
                                                    'dynamic_solver 1e-8 1e-14 30 12', 'FairTen1'), &
                    'shadowed dynamic_solver', 'dynamic_solver needs finite positive tolerances')
    CALL expect_bad('reader_waves.dat', chain_deck(ANCHOR, 'airy 0 8 0 waves'//LF//'none waves', 'FairTen1'), &
                    'shadowed airy row', 'positive height/period')
    CALL expect_ok('reader_friction_none.dat', chain_deck(ANCHOR, 'none frictionMu', 'FairTen1'), &
                   'frictionMu none')
  END SUBROUTINE check_option_rows

  SUBROUTINE check_bathymetry_row_order()
    !! A constant-depth grid written with rows in descending and in scattered order must
    !! load (the sort must not read outside its buffer) and reproduce the flat seabed.
    CHARACTER(:), ALLOCATABLE :: rows_desc, rows_mixed, base
    REAL(wp) :: ten_flat, ten_desc, ten_mixed
    INTEGER :: es
    CHARACTER(1024) :: em
    LOGICAL :: conv
    rows_desc = '500 20 50'//LF//'500 -20 50'//LF//'-50 20 50'//LF//'-50 -20 50'//LF
    rows_mixed = '-50 20 50'//LF//'500 -20 50'//LF//'200 20 50'//LF//'-50 -20 50'//LF// &
                 '500 20 50'//LF//'200 -20 50'//LF
    CALL write_bytes('reader_bathy_desc.xyz', rows_desc)
    CALL write_bytes('reader_bathy_mixed.xyz', rows_mixed)
    base = chain_deck(ANCHOR, '', 'FairTen1')
    CALL write_bytes('reader_bathy_flat.dat', base)
    CALL CD_Run_Deck_Driver('reader_bathy_flat.dat', 'reader_bathy_flat', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'flat-seabed reference run: '//TRIM(em))
    ten_flat = first_fairten('reader_bathy_flat.out')
    CALL write_bytes('reader_bathy_desc.dat', replace_once(base, '50.0 WtrDpth', &
                                                           'reader_bathy_desc.xyz bathymetryFile'))
    CALL CD_Run_Deck_Driver('reader_bathy_desc.dat', 'reader_bathy_desc', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'descending-order bathymetry grid loads: '//TRIM(em))
    ten_desc = first_fairten('reader_bathy_desc.out')
    CALL write_bytes('reader_bathy_mixed.dat', replace_once(base, '50.0 WtrDpth', &
                                                            'reader_bathy_mixed.xyz bathymetryFile'))
    CALL CD_Run_Deck_Driver('reader_bathy_mixed.dat', 'reader_bathy_mixed', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'scattered-order bathymetry grid loads: '//TRIM(em))
    ten_mixed = first_fairten('reader_bathy_mixed.out')
    CALL require(ABS(ten_desc - ten_flat) <= 1.0e-6_wp*ten_flat, 'descending grid reproduces the flat seabed')
    CALL require(ABS(ten_mixed - ten_flat) <= 1.0e-6_wp*ten_flat, 'scattered grid reproduces the flat seabed')
  END SUBROUTINE check_bathymetry_row_order

  SUBROUTINE check_waterkin_diagnostics()
    CHARACTER(:), ALLOCATABLE :: wk
    wk = 'MoorDyn water kinematics'//LF//'header'//LF//'--- WAVES ---'//LF//'0 WaveKinMod'//LF// &
         '"" WaveKinFile'//LF//'0.25 dtWave'//LF//'0 WaveDir'//LF//'0 x'//LF//'0'//LF//'0 y'//LF//'0'//LF// &
         '0 z'//LF//'0'//LF//'--- CURRENT ---'//LF//'banana CurrentMod'//LF
    CALL write_bytes('reader_waterkin.dat', wk)
    CALL expect_bad('reader_waterkin_deck.dat', chain_deck(ANCHOR, 'reader_waterkin.dat WaterKin', 'FairTen1'), &
                    'malformed WaterKin CurrentMod', 'WaterKin file line 15: WaterKin CurrentMod must be an integer')
    CALL write_bytes('reader_waterkin_bom.dat', CHAR(239)//CHAR(187)//CHAR(191)//replace_once(wk, 'banana', '0'))
    CALL expect_ok('reader_waterkin_bom_deck.dat', chain_deck(ANCHOR, 'reader_waterkin_bom.dat WaterKin', &
                                                              'FairTen1'), 'WaterKin file with a byte-order mark')
  END SUBROUTINE check_waterkin_diagnostics

  SUBROUTINE check_device_names()
    !! Reserved Windows device names read the console or discard data; they are refused
    !! by name there and are ordinary file names elsewhere.
    CHARACTER(:), ALLOCATABLE :: native
    CHARACTER(512) :: why
    INTEGER :: stat
    IF (.NOT. CD_Path_Is_Device('CON')) THEN
      CALL require(.NOT. CD_Path_Is_Device('dir/nul.dat'), 'device names are ordinary off Windows')
      RETURN
    END IF
    CALL require(CD_Path_Is_Device('dir/nul.dat') .AND. CD_Path_Is_Device('COM1.txt') .AND. &
                 CD_Path_Is_Device('CON:') .AND. CD_Path_Is_Device('lpt9') .AND. &
                 CD_Path_Is_Device('\\.\pipe\x'), 'reserved device names are recognized')
    CALL require(.NOT. (CD_Path_Is_Device('console.dat') .OR. CD_Path_Is_Device('com10') .OR. &
                        CD_Path_Is_Device('nulls/deck.dat')), 'ordinary names are not devices')
    CALL CD_Native_Path('aux.dat', native, stat, why)
    CALL require(stat == CD_PATH_ERR_DEVICE, 'a device name has no native spelling')
    CALL CD_Native_Path('reader_bathy_flat.dat', native, stat, why)
    CALL require(stat == CD_PATH_OK .AND. native == 'reader_bathy_flat.dat', 'an ASCII name is its own spelling')
    CALL expect_bad_run('reader_motion_con.dat', chain_deck(ANCHOR, '0.1 dtM'//LF//'1.0 TMax'//LF// &
                                                            'CON motionFile', 'FairTen1'), 'motionFile CON', &
                        'reserved Windows device')
    CALL expect_bad_run('reader_bathy_con.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), '50.0 WtrDpth', &
                                                             'nul.xyz bathymetryFile'), 'bathymetryFile nul.xyz', &
                        'reserved Windows device')
  END SUBROUTINE check_device_names

  SUBROUTINE check_files_that_do_not_open()
    !! Opens that fail return a status without attempting the OPEN (CD_Path_Openable): a
    !! folder, and names of about 680 characters (three 200-character folders that do not
    !! exist, spelt for the runtime as CD_Native_Path spells them, extended-length on Windows)
    !! for writing, for reading and as a deck run's output root. A short name still writes
    !! and reads back, and a probe for writing leaves an existing file as it is.
    CHARACTER(:), ALLOCATABLE :: native, long_name
    CHARACTER(512) :: why
    CHARACTER(64) :: line
    INTEGER :: stat, unit, ios, es
    CHARACTER(1024) :: em
    LOGICAL :: conv

    long_name = 'reader_missing_folder/'//REPEAT('a', 200)//'/'//REPEAT('b', 200)//'/'//REPEAT('c', 200)//'/run'
    CALL CD_Native_Path(long_name, native, stat, why, for_output=.TRUE.)
    CALL require(stat == CD_PATH_OK .AND. LEN(native) >= LEN(long_name), &
                 'a long output name has a runtime spelling: '//TRIM(why))
    IF (stat /= CD_PATH_OK) RETURN
    WRITE (*, '(A,I0,A)') '    files that do not open: a runtime spelling of ', LEN(native), ' characters'
    CALL require(.NOT. CD_Path_Openable(native//'.out', .TRUE.), 'a name in a missing folder does not open')
    CALL CD_Open_Write(unit, native//'.out', ios)
    CALL require(ios /= 0, 'writing a long name in a missing folder fails with a status')
    CALL CD_Open_Read(unit, native//'.out', ios)
    CALL require(ios /= 0, 'reading a long missing name fails with a status')
    CALL CD_Open_Input(unit, long_name//'.dat', ios, why)
    CALL require(ios /= 0, 'a long missing input fails with a status')
    CALL CD_Open_Read(unit, '.', ios)
    CALL require(ios /= 0, 'a folder does not open for reading')
    CALL write_bytes('reader_long_root.dat', chain_deck(ANCHOR, '', 'FairTen1'))
    CALL CD_Run_Deck_Driver('reader_long_root.dat', native, conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'cannot open output file') > 0, &
                 'a deck run with a long output root in a missing folder reports it: '//TRIM(em(1:200)))
    ! a short name still opens, and a write probe leaves the file as it is
    CALL CD_Open_Write(unit, 'reader_open_probe.txt', ios)
    CALL require(ios == 0, 'a short name opens for writing')
    IF (ios /= 0) RETURN
    WRITE (unit, '(A)') 'kept'
    CLOSE (unit)
    CALL require(CD_Path_Openable('reader_open_probe.txt', .TRUE.), 'an existing file opens for writing')
    CALL CD_Open_Read(unit, 'reader_open_probe.txt', ios)
    CALL require(ios == 0, 'a short name opens for reading')
    IF (ios /= 0) RETURN
    line = ''
    READ (unit, '(A)', IOSTAT=ios) line
    CLOSE (unit, STATUS='DELETE')
    CALL require(ios == 0 .AND. line == 'kept', 'a write probe leaves the file as it is')
  END SUBROUTINE check_files_that_do_not_open

  SUBROUTINE check_nonfinite_and_subnormal_values()
    !! Every number of an OPTIONS row and of a numeric table column must be finite and
    !! normal: "x < lo .OR. x > hi" is false for NaN, so a NaN must never reach a range
    !! guard, and a subnormal overflows the first division that uses it. Each case fails
    !! at its own row with a typed message (and never raises a trapped FPE).
    CHARACTER(*), PARAMETER :: NF = 'is not a finite number', SUB = 'is subnormal'
    CHARACTER(*), PARAMETER :: DYN = '0.05 dtM'//LF//'0.1 TMax'
    CALL expect_bad('reader_nan_currents.dat', chain_deck(ANCHOR, 'NaN Currents', 'FairTen1'), &
                    'NaN Currents', 'OPTIONS value "NaN" '//NF)
    CALL expect_bad('reader_nan_wavekin.dat', chain_deck(ANCHOR, 'NaN WaveKin', 'FairTen1'), &
                    'NaN WaveKin', 'OPTIONS value "NaN" '//NF)
    CALL expect_bad('reader_nan_waterkin_q.dat', chain_deck(ANCHOR, '"-Inf" WaterKin', 'FairTen1'), &
                    'quoted -Inf WaterKin', 'OPTIONS value "-Inf" '//NF)
    CALL expect_bad('reader_nan_mu.dat', chain_deck(ANCHOR, 'NaN mu', 'FairTen1'), &
                    'NaN frictionMu', 'OPTIONS value "NaN" '//NF)
    CALL expect_bad('reader_nan_substeps.dat', chain_deck(ANCHOR, '-NaN recovery_max_substeps', 'FairTen1'), &
                    'NaN recovery_max_substeps', 'OPTIONS value "-NaN" '//NF)
    CALL expect_bad('reader_nan_solver.dat', chain_deck(ANCHOR, 'dynamic_solver -NaN 1.0e-14 30 12', &
                                                        'FairTen1'), 'NaN dynamic_solver tolerance', &
                    'OPTIONS value "-NaN" '//NF)
    CALL expect_bad('reader_inf_wave.dat', chain_deck(ANCHOR, DYN//LF//'airy 2.0 Infinity 0.0 waves', &
                                                      'FairTen1'), 'Inf waves period', &
                    'OPTIONS value "Infinity" '//NF)
    CALL expect_bad('reader_big_train.dat', chain_deck(ANCHOR, DYN//LF//'pm 1e309 8.0 0.0 waves', 'FairTen1'), &
                    'overflowing spectral wave height', 'OPTIONS value "1e309" '//NF)
    CALL expect_bad('reader_sub_dtm.dat', chain_deck(ANCHOR, '5e-324 dtM'//LF//'0.1 TMax', 'FairTen1'), &
                    'subnormal dtM', 'OPTIONS value "5e-324" '//SUB)
    CALL expect_bad('reader_sub_kbot.dat', chain_deck(ANCHOR, '4.9e-324 kBot', 'FairTen1'), &
                    'subnormal kBot', 'OPTIONS value "4.9e-324" '//SUB)
    CALL expect_bad('reader_sub_diam.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), 'chain 0.252', &
                                                        'chain 5e-324'), 'subnormal Diam', &
                    'deck line 5: column 2 value "5e-324" '//SUB)
    CALL expect_bad('reader_sub_ea.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), '1.674e9', '5e-324'), &
                    'subnormal EA', 'LINE TYPES EA value "5e-324" '//SUB)
    CALL expect_bad('reader_nan_ba.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), '-1.0 0.0', &
                                                      'NaN 0.0'), 'NaN BA', 'LINE TYPES BA value "NaN" '//NF)
    CALL expect_bad('reader_big_point.dat', chain_deck('1 Fixed 1e309 0.0 -50.0', '', 'FairTen1'), &
                    'beyond-HUGE coordinate', 'deck line 9: column 3 value "1e309" '//NF)
    CALL expect_bad('reader_sub_length.dat', replace_once(chain_deck(ANCHOR, '', 'FairTen1'), SECTION, &
                                                          '1 chain 4.9e-324 41'), 'subnormal section Length', &
                    'deck line 18: column 3 value "4.9e-324" '//SUB)
  END SUBROUTINE check_nonfinite_and_subnormal_values

  SUBROUTINE check_admissible_magnitudes()
    !! Finite but absurdly scaled inputs overflow the solver's force, length or time
    !! scales; they fail validation with the documented limit instead.
    CHARACTER(*), PARAMETER :: DYN = '0.05 dtM'//LF//'0.1 TMax'
    CHARACTER(:), ALLOCATABLE :: base
    INTEGER :: u, ios
    base = chain_deck(ANCHOR, '', 'FairTen1')
    CALL expect_bad('reader_mag_x.dat', chain_deck('1 Fixed 1e300 0.0 -50.0', '', 'FairTen1'), &
                    'huge anchor coordinate', 'deck line 9: POINTS row outside the admissible range')
    CALL expect_bad('reader_mag_ea.dat', replace_once(base, '1.674e9', '1e-300'), 'tiny EA', &
                    '(EA >= 1e-3 N, Diam >= 1e-6 m')
    CALL expect_bad('reader_mag_diam.dat', replace_once(base, 'chain 0.252', 'chain 1e-300'), 'tiny Diam', &
                    '(EA >= 1e-3 N, Diam >= 1e-6 m')
    CALL expect_bad('reader_mag_cd.dat', replace_once(base, '1.37 0.64', '1e100 0.64'), 'huge Cd', &
                    'Cd and Ca <= 1e3')
    CALL expect_bad('reader_mag_g.dat', replace_once(base, '9.80665 g', '1e300 g'), 'huge g', &
                    'OPTIONS g must be at most 1e3')
    CALL expect_bad('reader_mag_kbot.dat', replace_once(base, '1.0e5 kBot', '1e300 kBot'), 'huge kBot', &
                    'kBot and cBot must be at most 1e15')
    CALL expect_bad('reader_mag_wave.dat', chain_deck(ANCHOR, DYN//LF//'airy 1e300 8.0 0.0 waves', 'FairTen1'), &
                    'huge wave height', 'OPTION waves needs height <= 1e3 m')
    CALL expect_bad('reader_mag_period.dat', chain_deck(ANCHOR, DYN//LF//'airy 2.0 1e-300 0.0 waves', &
                                                        'FairTen1'), 'tiny wave period', 'period in [0.1, 1e5] s')
    CALL expect_bad('reader_mag_train.dat', chain_deck(ANCHOR, DYN//LF//'pm 1e30 8.0 0.0 waves', 'FairTen1'), &
                    'huge spectral wave height', 'a wave train needs height <= 1e3 m')
    CALL expect_bad('reader_mag_current.dat', chain_deck(ANCHOR, DYN//LF//'uniform 1e100 0.0 0.0 current', &
                                                         'FairTen1'), 'huge current', 'at most 1e3 m/s')
    ! a prescribed-motion row beyond the kinematic scales (read by the full run)
    OPEN (NEWUNIT=u, FILE='reader_mag_motion.txt', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '0.00 2 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.05 2 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 1e20'
    WRITE (u, '(A)') '0.10 2 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    CLOSE (u)
    CALL expect_bad_run('reader_mag_motion.dat', chain_deck(ANCHOR, DYN//LF//'reader_mag_motion.txt motionFile', &
                                                            'FairTen1'), 'huge prescribed acceleration', &
                        'motionFile line 2: value outside the admissible range')
  END SUBROUTINE check_admissible_magnitudes

  SUBROUTINE check_strict_line_attachments()
    !! A LINES attachment is an unquoted point id or rod end taken whole: never the
    !! leading integer of a quoted or trailing-garbage token.
    CHARACTER(:), ALLOCATABLE :: base
    base = chain_deck(ANCHOR, '', 'FairTen1')
    CALL expect_bad('reader_att_quoted_space.dat', replace_once(base, '1 2 1 -', '1 "2 zz" 1 -'), &
                    'quoted "2 zz" attachment', 'deck line 14: malformed LINES row: attachment "2 zz"')
    CALL expect_bad('reader_att_quoted.dat', replace_once(base, '1 2 1 -', "1 2 '1' -"), &
                    'quoted id attachment', "malformed LINES row: attachment '1'")
    CALL expect_bad('reader_att_garbage.dat', replace_once(base, '1 2 1 -', '1 2x 1 -'), &
                    'trailing-garbage attachment', 'malformed LINES row: attachment 2x')
    CALL expect_bad('reader_att_real.dat', replace_once(base, '1 2 1 -', '1 2 1.0 -'), &
                    'non-integer attachment', 'malformed LINES row: attachment 1.0')
    CALL expect_bad('reader_att_stock.dat', replace_once(base, '1 2 1 -', '1 chain "2" 1 410.0 41 -'), &
                    'quoted stock-row attachment', 'malformed LINES row: attachment "2"')
    CALL expect_bad('reader_att_outputs.dat', replace_once(base, '1 2 1 -', '1 2 1 "-'), &
                    'unterminated quote in Outputs', 'column 4 value "- has invalid quoting')
    CALL expect_bad('reader_quoted_number.dat', chain_deck('1 Fixed "400.0" 0.0 -50.0', '', 'FairTen1'), &
                    'quoted POINTS coordinate', 'column 3 must be an unquoted number')
    CALL expect_ok('reader_att_plain_ok.dat', base, 'plain point-id attachments')
  END SUBROUTINE check_strict_line_attachments

  FUNCTION replace_once(text, old, new) RESULT(out)
    CHARACTER(*), INTENT(IN) :: text, old, new
    CHARACTER(:), ALLOCATABLE :: out
    INTEGER :: p
    p = INDEX(text, old)
    IF (p == 0) THEN
      out = text
      CALL require(.FALSE., 'fixture text "'//old//'" present')
    ELSE
      out = text(1:p - 1)//new//text(p + LEN(old):)
    END IF
  END FUNCTION replace_once

  REAL(wp) FUNCTION first_fairten(path) RESULT(ten)
    !! FairTen1 of the first data row of a static .out (row: time, FairTen1).
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(4096) :: line
    REAL(wp) :: t
    INTEGER :: u, ios
    ten = -1.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      READ (line, *, IOSTAT=ios) t, ten
      IF (ios == 0) EXIT
      ten = -1.0_wp
    END DO
    CLOSE (u)
  END FUNCTION first_fairten

END PROGRAM test_deck_reader_io
