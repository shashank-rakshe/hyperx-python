! File: tests/test_stream_wave.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_stream_wave
  !! Stream-function (Dean) regular waves (CableDyn_StreamWave):
  !!   1. Linear limit: a 2 cm wave has the linear wavenumber and the Airy kinematics.
  !!   2. Deep water, ka = 0.1: wavenumber, crest and trough elevations of third-order Stokes
  !!      theory (omega^2 = g k (1 + (ka)^2), eta = a cos + k a^2/2 cos 2 + 3/8 k^2 a^3 cos 3).
  !!   3. OrcaFlex 11.6d "Dean stream" (order 20) for H = 8 m, T = 10 s, d = 50 m
  !!      (validation/scripts/orcaflex_stream_wave_reference.py): crest and trough elevations,
  !!      celerity (dispersion), and the horizontal particle velocity under the crest at the
  !!      surface and at 0, -10 and -30 m, each within 1 %.
  !!   4. The driver: a stream waves row runs, StreamOrder is honoured, a breaking wave and
  !!      spreading are rejected.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_StreamWave
  USE CableDyn_Hydro, ONLY: CD_Airy_Wave_Kinematics_Precomputed, CD_Solve_Dispersion_Wavenumber
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  REAL(wp), PARAMETER :: G = 9.80665_wp
  INTEGER :: nfail

  nfail = 0
  CALL case_linear_limit()
  CALL case_stokes_deep()
  CALL case_orcaflex()
  CALL case_deck()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'test_stream_wave: ', nfail, ' failure(s)'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'test_stream_wave: all checks passed'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'MISMATCH ['//label//']'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE case_linear_limit()
    TYPE(CD_StreamWaveType) :: w
    REAL(wp), PARAMETER :: H = 0.02_wp, T = 8.0_wp, D = 50.0_wp
    REAL(wp) :: k0, e1, e2, v1(3), v2(3), a1(3), a2(3), p1, p2, x, z, tt, sv, sa
    INTEGER :: es, i
    CHARACTER(256) :: em
    CALL CD_Stream_Solve(w, H, T, D, G, 30.0_wp, 0, es, em)
    CALL require(es == CD_STREAM_OK, 'linear:solve: '//TRIM(em))
    IF (es /= CD_STREAM_OK) RETURN
    CALL CD_Solve_Dispersion_Wavenumber(2.0_wp*PI/T, D, G, k0, es, em)
    CALL require(ABS(w%k/k0 - 1.0_wp) < 1.0e-5_wp, 'linear:wavenumber')
    sv = 0.5_wp*H*2.0_wp*PI/T
    sa = sv*2.0_wp*PI/T
    DO i = 1, 6
      x = 7.0_wp*i
      z = -6.0_wp*(i - 1)
      tt = 1.3_wp*i
      CALL CD_Stream_Kinematics(w, x, 0.5_wp*x, z, tt, 1.0_wp, e1, v1, a1, es, em, pdyn=p1)
      CALL CD_Airy_Wave_Kinematics_Precomputed(x, 0.5_wp*x, z, tt, H, 2.0_wp*PI/T, k0, D, 30.0_wp, .FALSE., &
                                               e2, v2, a2, es, em, p2)
      CALL require(ABS(e1 - e2) < 2.0e-3_wp*0.5_wp*H .AND. nan_max_abs(v1 - v2) < 2.0e-3_wp*sv .AND. &
                   nan_max_abs(a1 - a2) < 2.0e-3_wp*sa .AND. ABS(p1 - p2) < 2.0e-3_wp*G*0.5_wp*H, &
                   'linear:airy-kinematics')
    END DO
  END SUBROUTINE case_linear_limit

  SUBROUTINE case_stokes_deep()
    TYPE(CD_StreamWaveType) :: w
    REAL(wp), PARAMETER :: T = 8.0_wp, D = 1000.0_wp, KA = 0.1_wp
    REAL(wp) :: omega, k, a, h, crest, trough, got_c, got_t, v(3), acc(3)
    INTEGER :: es, it
    CHARACTER(256) :: em
    omega = 2.0_wp*PI/T
    ! Stokes third order in deep water with ka = 0.1: omega^2 = g k (1 + (ka)^2)
    k = omega**2/G
    DO it = 1, 50
      k = omega**2/(G*(1.0_wp + KA**2))
    END DO
    a = KA/k
    h = 2.0_wp*a + 0.75_wp*k*k*a**3
    crest = a + 0.5_wp*k*a*a + 0.375_wp*k*k*a**3
    trough = -a + 0.5_wp*k*a*a - 0.375_wp*k*k*a**3
    CALL CD_Stream_Solve(w, h, T, D, G, 0.0_wp, 0, es, em)
    CALL require(es == CD_STREAM_OK, 'stokes:solve: '//TRIM(em))
    IF (es /= CD_STREAM_OK) RETURN
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, 1.0e3_wp, 0.0_wp, 1.0_wp, got_c, v, acc, es, em)
    CALL CD_Stream_Kinematics(w, PI/w%k, 0.0_wp, 1.0e3_wp, 0.0_wp, 1.0_wp, got_t, v, acc, es, em)
    WRITE (*, '(A,3F12.7)') 'Stokes-3 deep water: k ratio, crest ratio, trough ratio: ', w%k/k, got_c/crest, &
      got_t/trough
    CALL require(ABS(w%k/k - 1.0_wp) < 5.0e-4_wp, 'stokes:dispersion')
    CALL require(ABS(got_c/crest - 1.0_wp) < 2.0e-3_wp, 'stokes:crest')
    CALL require(ABS(got_t/trough - 1.0_wp) < 2.0e-3_wp, 'stokes:trough')
  END SUBROUTINE case_stokes_deep

  SUBROUTINE case_orcaflex()
    !! OrcaFlex 11.6d Dean stream, order 20 (validation/scripts/orcaflex_stream_wave_reference.py).
    REAL(wp), PARAMETER :: OF_CREST = 4.385533_wp, OF_TROUGH = -3.614467_wp, OF_CELERITY = 15.507687_wp
    REAL(wp), PARAMETER :: OF_U0 = 2.573135_wp, OF_U10 = 1.739908_wp, OF_U30 = 0.884382_wp
    REAL(wp), PARAMETER :: OF_USURF = 3.070347_wp
    TYPE(CD_StreamWaveType) :: w
    REAL(wp) :: crest, trough, v(3), acc(3), u0, u10, u30, us, e
    INTEGER :: es
    CHARACTER(256) :: em
    CALL CD_Stream_Solve(w, 8.0_wp, 10.0_wp, 50.0_wp, G, 0.0_wp, 20, es, em)
    CALL require(es == CD_STREAM_OK, 'orcaflex:solve: '//TRIM(em))
    IF (es /= CD_STREAM_OK) RETURN
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, 1.0e3_wp, 0.0_wp, 1.0_wp, crest, v, acc, es, em)
    CALL CD_Stream_Kinematics(w, PI/w%k, 0.0_wp, 1.0e3_wp, 0.0_wp, 1.0_wp, trough, v, acc, es, em)
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, e, v, acc, es, em)
    u0 = v(1)
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, -10.0_wp, 0.0_wp, 1.0_wp, e, v, acc, es, em)
    u10 = v(1)
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, -30.0_wp, 0.0_wp, 1.0_wp, e, v, acc, es, em)
    u30 = v(1)
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, crest - 1.0e-6_wp, 0.0_wp, 1.0_wp, e, v, acc, es, em)
    us = v(1)
    WRITE (*, '(A,2F12.6)') 'stream vs OrcaFlex crest (m):         ', crest, OF_CREST
    WRITE (*, '(A,2F12.6)') 'stream vs OrcaFlex trough (m):        ', trough, OF_TROUGH
    WRITE (*, '(A,2F12.6)') 'stream vs OrcaFlex celerity (m/s):    ', w%c, OF_CELERITY
    WRITE (*, '(A,2F12.6)') 'stream vs OrcaFlex u crest surface:   ', us, OF_USURF
    WRITE (*, '(A,2F12.6)') 'stream vs OrcaFlex u(z = 0):          ', u0, OF_U0
    WRITE (*, '(A,2F12.6)') 'stream vs OrcaFlex u(z = -10):        ', u10, OF_U10
    WRITE (*, '(A,2F12.6)') 'stream vs OrcaFlex u(z = -30):        ', u30, OF_U30
    CALL require(ABS(crest/OF_CREST - 1.0_wp) < 0.01_wp, 'orcaflex:crest')
    CALL require(ABS(trough/OF_TROUGH - 1.0_wp) < 0.01_wp, 'orcaflex:trough')
    CALL require(ABS(w%c/OF_CELERITY - 1.0_wp) < 0.01_wp, 'orcaflex:celerity')
    CALL require(ABS(us/OF_USURF - 1.0_wp) < 0.01_wp, 'orcaflex:u-crest-surface')
    CALL require(ABS(u0/OF_U0 - 1.0_wp) < 0.01_wp, 'orcaflex:u-z0')
    CALL require(ABS(u10/OF_U10 - 1.0_wp) < 0.01_wp, 'orcaflex:u-z10')
    CALL require(ABS(u30/OF_U30 - 1.0_wp) < 0.01_wp, 'orcaflex:u-z30')
    ! local acceleration is -c du/dX: zero under the crest, and above the surface nothing
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, -5.0_wp, 0.0_wp, 1.0_wp, e, v, acc, es, em)
    CALL require(ABS(acc(1)) < 1.0e-9_wp .AND. ABS(v(3)) < 1.0e-9_wp, 'orcaflex:crest-symmetry')
    CALL CD_Stream_Kinematics(w, 0.0_wp, 0.0_wp, crest + 0.1_wp, 0.0_wp, 1.0_wp, e, v, acc, es, em)
    CALL require(nan_max_abs(v) <= 0.0_wp .AND. nan_max_abs(acc) <= 0.0_wp, 'orcaflex:above-surface-still')
  END SUBROUTINE case_orcaflex

  SUBROUTINE write_deck(path, rows)
    CHARACTER(*), INTENT(IN) :: path, rows(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'stream-function wave deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 -5.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '2.0 TMax'
    DO i = 1, SIZE(rows)
      IF (LEN_TRIM(rows(i)) > 0) WRITE (u, '(A)') TRIM(rows(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE case_deck()
    CHARACTER(64) :: rows(2)
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    rows = ''
    rows(1) = 'stream 6.0 9.0 0.0 waves'
    CALL write_deck('stream_ok.dat', rows)
    CALL CD_Run_Deck_Driver('stream_ok.dat', 'stream_ok', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'deck:stream-runs: '//TRIM(em))
    rows(2) = '12 StreamOrder'
    CALL write_deck('stream_order.dat', rows)
    CALL CD_Run_Deck_Driver('stream_order.dat', 'stream_order', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'deck:stream-order-runs: '//TRIM(em))
    rows(2) = '1 StreamOrder'
    CALL write_deck('stream_bad_order.dat', rows)
    CALL CD_Run_Deck_Driver('stream_bad_order.dat', 'stream_bad_order', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'deck:stream-order-1-rejected')
    rows(2) = '3 WaveSpreading'
    CALL write_deck('stream_bad_spread.dat', rows)
    CALL CD_Run_Deck_Driver('stream_bad_spread.dat', 'stream_bad_spread', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'deck:stream-spreading-rejected')
    rows(1) = 'stream 45.0 9.0 0.0 waves'
    rows(2) = ''
    CALL write_deck('stream_breaking.dat', rows)
    CALL CD_Run_Deck_Driver('stream_breaking.dat', 'stream_breaking', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'deck:breaking-wave-rejected')
  END SUBROUTINE case_deck

END PROGRAM test_stream_wave
