! File: tests/test_wave_spectra.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_wave_spectra
  !! Wave spectra, directional spreading and multi-train seas (CableDyn_WaveSpectra):
  !!   1. Each spectrum against its published formula: m0 -> Hs, peak location, the
  !!      JONSWAP peak enhancement A_gamma*gamma, the Torsethaugen wind-sea / swell
  !!      partition (Hs1^2 + Hs2^2 = Hs^2, partition peaks), Ochi-Hubble partitions.
  !!   2. cos-2s spreading: K(s), weights sum to one, the directional moment
  !!      E[cos^2] = (s + 1/2)/(s + 1).
  !!   3. Statistics of the synthesised sea: a long elevation record recovers Hs and its
  !!      band-averaged periodogram matches S(omega); two trains add in energy; a spread
  !!      sea gives the lateral/longitudinal velocity-variance ratio 1/(2s + 1).
  !!   4. A long-crested JONSWAP train reproduces the original JONSWAP synthesis and its
  !!      kinematics (same seed, same components, same Wheeler convention); the kinematics
  !!      of spread seas below and above the kept-phase length of CD_Sea_Kinematics equal a
  !!      direct per-component sum.
  !!   5. Deck rows: spectral waves rows, WaveSpreading, wavetrain rows run end to end, and
  !!      malformed or conflicting rows are rejected.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_WaveSpectra
  USE CableDyn_Hydro, ONLY: CD_JONSWAP_Random_Components, CD_Component_Wave_Kinematics
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  REAL(wp), PARAMETER :: G = 9.80665_wp
  INTEGER :: nfail

  nfail = 0
  CALL case_pm_formula()
  CALL case_jonswap_formula()
  CALL case_torsethaugen()
  CALL case_ochi_hubble()
  CALL case_spreading()
  CALL case_statistics_pm()
  CALL case_statistics_torsethaugen()
  CALL case_two_trains()
  CALL case_spread_velocity_ratio()
  CALL case_legacy_jonswap_identity()
  CALL case_kinematics_reference()
  CALL case_parse_rows()
  CALL case_deck_runs()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'test_wave_spectra: ', nfail, ' failure(s)'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'test_wave_spectra: all checks passed'

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

  SUBROUTINE report(label, value)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: value
    WRITE (*, '(A,A,ES14.6)') label, ' = ', value
  END SUBROUTINE report

  REAL(wp) FUNCTION moment(tr, order, wlo, whi) RESULT(m)
    !! Composite-Simpson moment int S(w) w^order dw over [wlo, whi] (20000 intervals).
    TYPE(CD_WaveTrainType), INTENT(IN) :: tr
    INTEGER, INTENT(IN) :: order
    REAL(wp), INTENT(IN) :: wlo, whi
    INTEGER, PARAMETER :: N = 20000
    INTEGER :: i
    REAL(wp) :: h, w, f
    h = (whi - wlo)/REAL(N, wp)
    m = 0.0_wp
    DO i = 0, N
      w = wlo + h*REAL(i, wp)
      f = CD_Spectrum_Density(tr, w, G)*w**order
      IF (i == 0 .OR. i == N) THEN
        m = m + f
      ELSE IF (MOD(i, 2) == 1) THEN
        m = m + 4.0_wp*f
      ELSE
        m = m + 2.0_wp*f
      END IF
    END DO
    m = m*h/3.0_wp
  END FUNCTION moment

  REAL(wp) FUNCTION argmax_omega(tr, wlo, whi) RESULT(wm)
    TYPE(CD_WaveTrainType), INTENT(IN) :: tr
    REAL(wp), INTENT(IN) :: wlo, whi
    INTEGER :: i
    REAL(wp) :: w, s, smax
    smax = -1.0_wp
    wm = wlo
    DO i = 0, 200000
      w = wlo + (whi - wlo)*REAL(i, wp)/200000.0_wp
      s = CD_Spectrum_Density(tr, w, G)
      IF (s > smax) THEN
        smax = s
        wm = w
      END IF
    END DO
  END FUNCTION argmax_omega

  SUBROUTINE case_pm_formula()
    TYPE(CD_WaveTrainType) :: tr
    REAL(wp) :: m0, wpk, s_pk
    tr%kind = CD_TRAIN_PM
    tr%height = 5.0_wp
    tr%period = 10.0_wp
    wpk = 2.0_wp*PI/tr%period
    m0 = moment(tr, 0, 0.05_wp*wpk, 40.0_wp*wpk)
    CALL report('PM m0/(Hs^2/16)', m0/(tr%height**2/16.0_wp))
    CALL require(ABS(m0/(tr%height**2/16.0_wp) - 1.0_wp) < 2.0e-4_wp, 'pm:m0')
    CALL require(ABS(argmax_omega(tr, 0.5_wp*wpk, 2.0_wp*wpk)/wpk - 1.0_wp) < 1.0e-4_wp, 'pm:peak')
    s_pk = (5.0_wp/16.0_wp)*tr%height**2/wpk*EXP(-1.25_wp)
    CALL require(ABS(CD_Spectrum_Density(tr, wpk, G)/s_pk - 1.0_wp) < 1.0e-12_wp, 'pm:peak-value')
    ! Tz from m0/m2 of the full PM: Tz = Tp/1.408 (Tp/Tz = (5/4)^(1/4) sqrt(pi)/... ) -> 0.7104 Tp
    CALL require(ABS(2.0_wp*PI*SQRT(m0/moment(tr, 2, 0.05_wp*wpk, 200.0_wp*wpk))/tr%period - 0.7104_wp) &
                 < 2.0e-3_wp, 'pm:tz-over-tp')
  END SUBROUTINE case_pm_formula

  SUBROUTINE case_jonswap_formula()
    TYPE(CD_WaveTrainType) :: tr, pm
    REAL(wp) :: m0, wpk, ratio
    tr%kind = CD_TRAIN_JONSWAP
    tr%height = 6.0_wp
    tr%period = 12.0_wp
    tr%gamma = 3.3_wp
    pm = tr
    pm%kind = CD_TRAIN_PM
    wpk = 2.0_wp*PI/tr%period
    m0 = moment(tr, 0, 0.05_wp*wpk, 40.0_wp*wpk)
    CALL report('JONSWAP m0/(Hs^2/16)', m0/(tr%height**2/16.0_wp))
    ! A_gamma = 1 - 0.287 ln(gamma) normalises to within ~1% (DNV-RP-C205)
    CALL require(ABS(m0/(tr%height**2/16.0_wp) - 1.0_wp) < 0.015_wp, 'jonswap:m0')
    CALL require(ABS(argmax_omega(tr, 0.5_wp*wpk, 2.0_wp*wpk)/wpk - 1.0_wp) < 1.0e-4_wp, 'jonswap:peak')
    ratio = CD_Spectrum_Density(tr, wpk, G)/CD_Spectrum_Density(pm, wpk, G)
    CALL require(ABS(ratio - (1.0_wp - 0.287_wp*LOG(3.3_wp))*3.3_wp) < 1.0e-12_wp, 'jonswap:enhancement')
  END SUBROUTINE case_jonswap_formula

  SUBROUTINE case_torsethaugen()
    TYPE(CD_WaveTrainType) :: tr
    REAL(wp) :: h1, tp1, g1, h2, tp2, g2, m0, wpk, w2, tf, eps, r
    ! wind dominated: Hs 6 m, Tp 8 s (Tf = 6.6*6^(1/3) = 11.99 s)
    CALL CD_Torsethaugen_Partition(6.0_wp, 8.0_wp, G, h1, tp1, g1, h2, tp2, g2)
    tf = 6.6_wp*6.0_wp**(1.0_wp/3.0_wp)
    eps = (tf - 8.0_wp)/(tf - 2.0_wp*SQRT(6.0_wp))
    r = 0.7_wp + 0.3_wp*EXP(-(2.0_wp*eps)**2)
    CALL require(ABS(h1 - r*6.0_wp) < 1.0e-12_wp, 'tors:wind:h1')
    CALL require(ABS(h1*h1 + h2*h2 - 36.0_wp) < 1.0e-10_wp, 'tors:wind:energy-partition')
    CALL require(ABS(tp1 - 8.0_wp) < 1.0e-12_wp .AND. ABS(tp2 - (tf + 2.0_wp)) < 1.0e-12_wp, 'tors:wind:periods')
    CALL require(ABS(g1 - MAX(1.0_wp, 35.0_wp*(2.0_wp*PI*h1/(G*64.0_wp))**0.857_wp)) < 1.0e-12_wp, &
                 'tors:wind:gamma')
    CALL require(ABS(g2 - 1.0_wp) < 1.0e-15_wp, 'tors:wind:gamma2')
    CALL report('Torsethaugen wind r = Hs1/Hs', h1/6.0_wp)
    CALL report('Torsethaugen wind gamma1', g1)
    tr%kind = CD_TRAIN_TORSETHAUGEN
    tr%height = 6.0_wp
    tr%period = 8.0_wp
    wpk = 2.0_wp*PI/8.0_wp
    m0 = moment(tr, 0, 0.02_wp*wpk, 40.0_wp*wpk)
    CALL report('Torsethaugen wind m0/(Hs^2/16)', m0/(36.0_wp/16.0_wp))
    CALL require(ABS(m0/(36.0_wp/16.0_wp) - 1.0_wp) < 0.03_wp, 'tors:wind:m0')
    CALL require(ABS(argmax_omega(tr, 0.6_wp*wpk, 2.0_wp*wpk)/wpk - 1.0_wp) < 0.01_wp, 'tors:wind:primary-peak')
    w2 = 2.0_wp*PI/tp2
    CALL require(ABS(argmax_omega(tr, 0.8_wp*w2, 1.1_wp*w2)/w2 - 1.0_wp) < 0.03_wp, 'tors:wind:swell-peak')
    ! swell dominated: Hs 4 m, Tp 16 s (Tf = 10.48 s)
    CALL CD_Torsethaugen_Partition(4.0_wp, 16.0_wp, G, h1, tp1, g1, h2, tp2, g2)
    tf = 6.6_wp*4.0_wp**(1.0_wp/3.0_wp)
    eps = (16.0_wp - tf)/(25.0_wp - tf)
    r = 0.6_wp + 0.4_wp*EXP(-(eps/0.3_wp)**2)
    CALL require(ABS(h1 - r*4.0_wp) < 1.0e-12_wp, 'tors:swell:h1')
    CALL require(ABS(h1*h1 + h2*h2 - 16.0_wp) < 1.0e-10_wp, 'tors:swell:energy-partition')
    CALL require(ABS(tp2 - 6.6_wp*h2**(1.0_wp/3.0_wp)) < 1.0e-12_wp, 'tors:swell:wind-period')
    CALL require(ABS(g1 - 35.0_wp*(2.0_wp*PI*4.0_wp/(G*tf*tf))**0.857_wp*(1.0_wp + 6.0_wp*eps)) < 1.0e-12_wp, &
                 'tors:swell:gamma')
    CALL report('Torsethaugen swell r = Hs1/Hs', h1/4.0_wp)
    tr%height = 4.0_wp
    tr%period = 16.0_wp
    wpk = 2.0_wp*PI/16.0_wp
    m0 = moment(tr, 0, 0.02_wp*wpk, 60.0_wp*wpk)
    CALL require(ABS(m0/1.0_wp - 1.0_wp) < 0.03_wp, 'tors:swell:m0')
    CALL require(ABS(argmax_omega(tr, 0.6_wp*wpk, 1.5_wp*wpk)/wpk - 1.0_wp) < 0.01_wp, 'tors:swell:primary-peak')
    ! (the swell-dominated wind-sea partition sits on the swell tail and has no separate
    ! maximum at these parameters; its period and height are checked above)
  END SUBROUTINE case_torsethaugen

  SUBROUTINE case_ochi_hubble()
    TYPE(CD_WaveTrainType) :: tr
    REAL(wp) :: m0, w1
    tr%kind = CD_TRAIN_OCHIHUBBLE
    tr%height = 3.0_wp
    tr%period = 14.0_wp
    tr%lambda1 = 3.0_wp
    tr%height2 = 0.0_wp
    tr%period2 = 7.0_wp
    tr%lambda2 = 1.0_wp
    w1 = 2.0_wp*PI/14.0_wp
    m0 = moment(tr, 0, 0.05_wp*w1, 60.0_wp*w1)
    CALL require(ABS(m0/(9.0_wp/16.0_wp) - 1.0_wp) < 2.0e-4_wp, 'ochi:partition1-m0')
    CALL require(ABS(argmax_omega(tr, 0.5_wp*w1, 2.0_wp*w1)/w1 - 1.0_wp) < 1.0e-4_wp, 'ochi:partition1-peak')
    ! lambda = 1 is the Bretschneider (PM) form
    tr%lambda1 = 1.0_wp
    BLOCK
      TYPE(CD_WaveTrainType) :: pm
      pm%kind = CD_TRAIN_PM
      pm%height = 3.0_wp
      pm%period = 14.0_wp
      CALL require(ABS(CD_Spectrum_Density(tr, 0.7_wp*w1, G)/CD_Spectrum_Density(pm, 0.7_wp*w1, G) - 1.0_wp) &
                   < 1.0e-12_wp, 'ochi:lambda1-is-pm')
    END BLOCK
    tr%lambda1 = 3.0_wp
    tr%height2 = 2.0_wp
    tr%lambda2 = 1.5_wp
    m0 = moment(tr, 0, 0.05_wp*w1, 60.0_wp*w1)
    CALL require(ABS(m0/(13.0_wp/16.0_wp) - 1.0_wp) < 2.0e-4_wp, 'ochi:two-partition-m0')
  END SUBROUTINE case_ochi_hubble

  SUBROUTINE case_spreading()
    INTEGER, PARAMETER :: N = 45
    REAL(wp) :: off(N), w(N), off9(9), w9(9), s, ec2
    REAL(wp), PARAMETER :: S_LIST(3) = [1.0_wp, 4.0_wp, 12.0_wp]
    INTEGER :: j
    CALL require(ABS(CD_Spreading_Constant(1.0_wp) - 2.0_wp/PI) < 1.0e-14_wp, 'spread:K(1)=2/pi')
    CALL require(ABS(CD_Spreading_Constant(0.0_wp) - 1.0_wp/PI) < 1.0e-14_wp, 'spread:K(0)=1/pi')
    DO j = 1, 3
      s = S_LIST(j)
      CALL CD_Spreading_Weights(s, N, off, w)
      CALL require(ABS(SUM(w) - 1.0_wp) < 1.0e-14_wp, 'spread:weights-sum')
      ec2 = SUM(w*COS(off)**2)
      CALL require(ABS(ec2 - (s + 0.5_wp)/(s + 1.0_wp)) < 1.0e-3_wp, 'spread:cos2-moment')
      CALL require(ALL(w > 0.0_wp) .AND. ABS(SUM(w*off)) < 1.0e-12_wp, 'spread:symmetric')
      CALL CD_Spreading_Weights(s, 9, off9, w9)
      CALL require(ABS(SUM(w9*COS(off9)**2) - (s + 0.5_wp)/(s + 1.0_wp)) < 0.02_wp, 'spread:cos2-moment-9dir')
    END DO
  END SUBROUTINE case_spreading

  SUBROUTINE elevation_record(sea, depth, x, y, dt, n, eta)
    TYPE(CD_SeaType), INTENT(IN) :: sea
    REAL(wp), INTENT(IN) :: depth, x, y, dt
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(OUT) :: eta(n)
    INTEGER :: i, es
    CHARACTER(256) :: em
    REAL(wp) :: v(3), a(3)
    DO i = 1, n
      CALL CD_Sea_Kinematics(sea, x, y, 1.0e3_wp, dt*REAL(i - 1, wp), depth, 1.0_wp, eta(i), v, a, es, em)
    END DO
  END SUBROUTINE elevation_record

  SUBROUTINE fft(re, im)
    !! In-place radix-2 complex FFT (length a power of two).
    REAL(wp), INTENT(INOUT) :: re(:), im(:)
    INTEGER :: n, i, j, k, m, step
    REAL(wp) :: tr_, ti, ang, wr, wi, ur, ui
    n = SIZE(re)
    j = 1
    DO i = 1, n
      IF (i < j) THEN
        tr_ = re(j); re(j) = re(i); re(i) = tr_
        ti = im(j); im(j) = im(i); im(i) = ti
      END IF
      m = n/2
      DO WHILE (m >= 2 .AND. j > m)
        j = j - m
        m = m/2
      END DO
      j = j + m
    END DO
    step = 1
    DO WHILE (step < n)
      ang = -PI/REAL(step, wp)
      DO k = 0, step - 1
        wr = COS(ang*REAL(k, wp))
        wi = SIN(ang*REAL(k, wp))
        DO i = k + 1, n, 2*step
          j = i + step
          ur = wr*re(j) - wi*im(j)
          ui = wr*im(j) + wi*re(j)
          re(j) = re(i) - ur
          im(j) = im(i) - ui
          re(i) = re(i) + ur
          im(i) = im(i) + ui
        END DO
      END DO
      step = 2*step
    END DO
  END SUBROUTINE fft

  SUBROUTINE check_record(tr_list, ntr, label, dt, nbands, tol_band)
    !! Synthesise a sea of the trains, record 2^15 elevation samples at the origin, and
    !! compare Hs = 4 std and the band-averaged one-sided periodogram with the analytic S.
    TYPE(CD_WaveTrainType), INTENT(IN) :: tr_list(:)
    INTEGER, INTENT(IN) :: ntr, nbands
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: dt, tol_band
    INTEGER, PARAMETER :: NS = 32768
    TYPE(CD_SeaType) :: sea
    REAL(wp), ALLOCATABLE :: eta(:), re(:), im(:), psd(:)
    REAL(wp) :: hs_target, hs_rec, dw, wlo, whi, band_psd, band_s, w, peak_s, ww
    INTEGER :: i, es, b, k, nb, cnt, cnt_s, it
    CHARACTER(256) :: em
    ALLOCATE (eta(NS), re(NS), im(NS), psd(NS/2))
    hs_target = 0.0_wp
    DO i = 1, ntr
      CALL CD_Sea_Add_Train(sea, tr_list(i), es, em)
      CALL require(es == CD_SEA_OK, label//':add-train: '//TRIM(em))
      hs_target = hs_target + tr_list(i)%height**2
      IF (tr_list(i)%kind == CD_TRAIN_OCHIHUBBLE) hs_target = hs_target + tr_list(i)%height2**2
    END DO
    hs_target = SQRT(hs_target)
    CALL CD_Sea_Synthesise(sea, 300.0_wp, G, 7, es, em)
    CALL require(es == CD_SEA_OK, label//':synthesise: '//TRIM(em))
    IF (es /= CD_SEA_OK) RETURN
    CALL elevation_record(sea, 300.0_wp, 0.0_wp, 0.0_wp, dt, NS, eta)
    hs_rec = 4.0_wp*SQRT(SUM((eta - SUM(eta)/NS)**2)/REAL(NS, wp))
    CALL report(label//' Hs record/target', hs_rec/hs_target)
    CALL require(ABS(hs_rec/hs_target - 1.0_wp) < 0.03_wp, label//':hs-recovered')
    IF (tol_band < 0.0_wp) RETURN
    re = eta
    im = 0.0_wp
    CALL fft(re, im)
    dw = 2.0_wp*PI/(REAL(NS, wp)*dt)
    DO k = 1, NS/2
      psd(k) = 2.0_wp*(re(k)**2 + im(k)**2)/REAL(NS, wp)**2/dw
    END DO
    ! band-average the periodogram and the analytic density over the synthesis band
    wlo = HUGE(1.0_wp)
    whi = 0.0_wp
    peak_s = 0.0_wp
    DO it = 1, ntr
      CALL CD_Train_Band(tr_list(it), G, w, ww)
      wlo = MIN(wlo, w)
      whi = MAX(whi, ww)
    END DO
    nb = nbands
    cnt = 0
    cnt_s = 0
    DO b = 1, nb
      band_psd = 0.0_wp
      band_s = 0.0_wp
      i = 0
      DO k = 2, NS/2
        w = dw*REAL(k - 1, wp)
        IF (w < wlo + (whi - wlo)*REAL(b - 1, wp)/nb .OR. w >= wlo + (whi - wlo)*REAL(b, wp)/nb) CYCLE
        band_psd = band_psd + psd(k)
        DO it = 1, ntr
          band_s = band_s + CD_Spectrum_Density(tr_list(it), w, G)
        END DO
        i = i + 1
      END DO
      IF (i == 0) CYCLE
      peak_s = MAX(peak_s, band_s/i)
    END DO
    DO b = 1, nb
      band_psd = 0.0_wp
      band_s = 0.0_wp
      i = 0
      DO k = 2, NS/2
        w = dw*REAL(k - 1, wp)
        IF (w < wlo + (whi - wlo)*REAL(b - 1, wp)/nb .OR. w >= wlo + (whi - wlo)*REAL(b, wp)/nb) CYCLE
        band_psd = band_psd + psd(k)
        DO it = 1, ntr
          band_s = band_s + CD_Spectrum_Density(tr_list(it), w, G)
        END DO
        i = i + 1
      END DO
      IF (i == 0) CYCLE
      ! bands holding at least 10% of the peak density are scored
      IF (band_s/i < 0.1_wp*peak_s) CYCLE
      cnt_s = cnt_s + 1
      IF (.NOT. (ABS(band_psd/band_s - 1.0_wp) <= tol_band)) THEN
        cnt = cnt + 1
        WRITE (*, '(A,I0,A,2ES12.4)') label//' band ', b, ' psd/S off: ', band_psd/i, band_s/i
      END IF
    END DO
    CALL report(label//' scored bands', REAL(cnt_s, wp))
    CALL require(cnt_s >= 5 .AND. cnt == 0, label//':band-density')
  END SUBROUTINE check_record

  SUBROUTINE case_statistics_pm()
    TYPE(CD_WaveTrainType) :: tr(1)
    tr(1)%kind = CD_TRAIN_PM
    tr(1)%height = 5.0_wp
    tr(1)%period = 10.0_wp
    CALL check_record(tr, 1, 'stat-pm', 0.5_wp, 40, 0.10_wp)
    tr(1)%kind = CD_TRAIN_JONSWAP
    tr(1)%gamma = 3.3_wp
    CALL check_record(tr, 1, 'stat-jonswap', 0.5_wp, 40, 0.10_wp)
  END SUBROUTINE case_statistics_pm

  SUBROUTINE case_statistics_torsethaugen()
    TYPE(CD_WaveTrainType) :: tr(1)
    tr(1)%kind = CD_TRAIN_TORSETHAUGEN
    tr(1)%height = 4.0_wp
    tr(1)%period = 16.0_wp
    CALL check_record(tr, 1, 'stat-torsethaugen', 0.5_wp, 40, 0.12_wp)
    tr(1)%kind = CD_TRAIN_OCHIHUBBLE
    tr(1)%height = 3.0_wp
    tr(1)%period = 15.0_wp
    tr(1)%lambda1 = 3.0_wp
    tr(1)%height2 = 2.5_wp
    tr(1)%period2 = 7.0_wp
    tr(1)%lambda2 = 1.2_wp
    CALL check_record(tr, 1, 'stat-ochi', 0.5_wp, 40, 0.12_wp)
  END SUBROUTINE case_statistics_torsethaugen

  SUBROUTINE case_two_trains()
    TYPE(CD_WaveTrainType) :: tr(2)
    tr(1)%kind = CD_TRAIN_PM
    tr(1)%height = 3.0_wp
    tr(1)%period = 12.0_wp
    tr(1)%direction = 0.0_wp
    tr(2)%kind = CD_TRAIN_JONSWAP
    tr(2)%height = 4.0_wp
    tr(2)%period = 7.0_wp
    tr(2)%gamma = 2.0_wp
    tr(2)%direction = 90.0_wp
    CALL check_record(tr, 2, 'stat-two-trains', 0.25_wp, 20, 0.15_wp)
    ! spread: the point record sums every direction, so Hs is kept (the band periodogram of a
    ! multi-directional point record carries cross-direction interference; not scored)
    tr(2)%spreading = 3.0_wp
    CALL check_record(tr, 2, 'stat-two-trains-spread', 0.25_wp, 40, -1.0_wp)
  END SUBROUTINE case_two_trains

  SUBROUTINE case_spread_velocity_ratio()
    !! Deep-water spread sea heading +x: var(v)/var(u) near the surface -> E[sin^2]/E[cos^2]
    !! = 1/(2s + 1).
    INTEGER, PARAMETER :: NS = 16384
    TYPE(CD_SeaType) :: sea
    TYPE(CD_WaveTrainType) :: tr
    REAL(wp) :: eta, v(3), a(3), su, sv, s
    INTEGER :: i, es, js
    CHARACTER(256) :: em
    REAL(wp), PARAMETER :: S_LIST(2) = [2.0_wp, 8.0_wp]
    DO js = 1, 2
      s = S_LIST(js)
      CALL CD_Sea_Reset(sea)
      tr%kind = CD_TRAIN_JONSWAP
      tr%height = 4.0_wp
      tr%period = 9.0_wp
      tr%gamma = 3.3_wp
      tr%direction = 0.0_wp
      tr%spreading = s
      sea%n_dir = 31
      CALL CD_Sea_Add_Train(sea, tr, es, em)
      CALL CD_Sea_Synthesise(sea, 500.0_wp, G, 11, es, em)
      CALL require(es == CD_SEA_OK, 'spread-ratio:synth: '//TRIM(em))
      su = 0.0_wp
      sv = 0.0_wp
      DO i = 1, NS
        CALL CD_Sea_Kinematics(sea, 0.0_wp, 0.0_wp, -8.0_wp, 0.5_wp*REAL(i, wp), 500.0_wp, 1.0_wp, eta, v, a, es, em)
        su = su + v(1)**2
        sv = sv + v(2)**2
      END DO
      CALL report('spread var(v)/var(u)*(2s+1)', sv/su*(2.0_wp*s + 1.0_wp))
      CALL require(ABS(sv/su*(2.0_wp*s + 1.0_wp) - 1.0_wp) < 0.15_wp, 'spread-ratio:1/(2s+1)')
    END DO
  END SUBROUTINE case_spread_velocity_ratio

  SUBROUTINE case_legacy_jonswap_identity()
    INTEGER, PARAMETER :: N = 200
    TYPE(CD_SeaType), SAVE :: sea
    TYPE(CD_WaveTrainType) :: tr
    REAL(wp) :: om(N), kk(N), amp(N), ph(N), e1, e2, v1(3), v2(3), a1(3), a2(3), p1, p2
    INTEGER :: es, i
    CHARACTER(256) :: em
    CALL CD_JONSWAP_Random_Components(4.0_wp, 8.0_wp, 3.3_wp, 50.0_wp, G, 5, om, kk, amp, ph, es, em)
    tr%kind = CD_TRAIN_JONSWAP
    tr%height = 4.0_wp
    tr%period = 8.0_wp
    tr%gamma = 3.3_wp
    tr%direction = 30.0_wp
    CALL CD_Sea_Add_Train(sea, tr, es, em)
    CALL CD_Sea_Synthesise(sea, 50.0_wp, G, 5, es, em)
    CALL require(es == CD_SEA_OK .AND. sea%n_comp == N, 'legacy:synth')
    IF (es /= CD_SEA_OK .OR. sea%n_comp /= N) RETURN
    DO i = 1, N
      CALL require(ABS(sea%omega(i) - om(i)) <= 0.0_wp .AND. ABS(sea%phase(i) - ph(i)) <= 0.0_wp, &
                   'legacy:same-frequencies-and-phases')
      CALL require(ABS(sea%amplitude(i)/amp(i) - 1.0_wp) < 1.0e-12_wp, 'legacy:same-amplitudes')
    END DO
    DO i = 1, 5
      CALL CD_Component_Wave_Kinematics(10.0_wp*i, -3.0_wp*i, -2.0_wp*i, 1.7_wp*i, 50.0_wp, 30.0_wp, .TRUE., &
                                        om, kk, amp, ph, e1, v1, a1, es, em, pdyn=p1)
      CALL CD_Sea_Kinematics(sea, 10.0_wp*i, -3.0_wp*i, -2.0_wp*i, 1.7_wp*i, 50.0_wp, 1.0_wp, e2, v2, a2, es, em, &
                             pdyn=p2)
      CALL require(ABS(e1 - e2) < 1.0e-10_wp .AND. nan_max_abs(v1 - v2) < 1.0e-10_wp .AND. &
                   nan_max_abs(a1 - a2) < 1.0e-10_wp .AND. ABS(p1 - p2) < 1.0e-9_wp, 'legacy:same-kinematics')
    END DO
  END SUBROUTINE case_legacy_jonswap_identity

  SUBROUTINE case_kinematics_reference()
    !! CD_Sea_Kinematics against a direct per-component sum of the same linear kinematics with
    !! Wheeler stretching, at points below the surface (one near the seabed) and one above it:
    !!   1. 9 x 200 components: every phase cosine kept between the two passes;
    !!   2. 31 x 200 components: the components past the kept length recomputed;
    !!   3. a short sea in 1000 m: EXP(-2 k h), and near the seabed EXP(k z), underflow for the
    !!      short components, which take the two-exponential form;
    !!   4. kinematics asked at another depth than the synthesis: the two-exponential form.
    ! allocatable: a default-initialised local with allocatable components draws spurious
    ! -Wuninitialized warnings from gfortran 16 (DEVELOPMENT.md)
    TYPE(CD_SeaType), ALLOCATABLE :: sea
    TYPE(CD_WaveTrainType) :: tr
    REAL(wp), PARAMETER :: SCL = 0.85_wp
    REAL(wp), PARAMETER :: PX(4) = [0.0_wp, 37.5_wp, -210.0_wp, 4.0_wp]
    REAL(wp), PARAMETER :: PY(4) = [0.0_wp, -12.0_wp, 95.0_wp, 1.0_wp]
    REAL(wp), PARAMETER :: PT(4) = [0.0_wp, 13.7_wp, 401.25_wp, 7.0_wp]
    INTEGER, PARAMETER :: NDIR(4) = [9, 31, 9, 9]
    REAL(wp), PARAMETER :: SYNTH_DEPTH(4) = [120.0_wp, 120.0_wp, 1000.0_wp, 120.0_wp]
    REAL(wp), PARAMETER :: CALL_DEPTH(4) = [120.0_wp, 120.0_wp, 1000.0_wp, 150.0_wp]
    REAL(wp), PARAMETER :: PERIOD(4) = [10.0_wp, 10.0_wp, 4.0_wp, 10.0_wp]
    REAL(wp) :: eta, v(3), a(3), p, eta_r, v_r(3), a_r(3), p_r, th, z_e, e1, e2, ch, sh, amp, depth, pz(4)
    INTEGER :: es, js, ip, i
    CHARACTER(256) :: em
    CHARACTER(48) :: tag
    ALLOCATE (sea)
    DO js = 1, SIZE(NDIR)
      CALL CD_Sea_Reset(sea)
      tr%kind = CD_TRAIN_JONSWAP
      tr%height = MERGE(1.0_wp, 6.0_wp, PERIOD(js) < 5.0_wp)
      tr%period = PERIOD(js)
      tr%gamma = 3.3_wp
      tr%direction = 20.0_wp
      tr%spreading = 4.0_wp
      sea%n_dir = NDIR(js)
      CALL CD_Sea_Add_Train(sea, tr, es, em)
      CALL CD_Sea_Synthesise(sea, SYNTH_DEPTH(js), G, 3, es, em)
      WRITE (tag, '(A,I0,A,I0)') 'sea-reference:case ', js, ', n_comp=', sea%n_comp
      CALL require(es == CD_SEA_OK .AND. sea%n_comp == 200*NDIR(js), TRIM(tag)//':synth')
      IF (es /= CD_SEA_OK) CYCLE
      depth = CALL_DEPTH(js)
      pz = [-1.5_wp, -20.0_wp, -0.95_wp*depth, 30.0_wp]
      DO ip = 1, SIZE(PX)
        CALL CD_Sea_Kinematics(sea, PX(ip), PY(ip), pz(ip), PT(ip), depth, SCL, eta, v, a, es, em, pdyn=p)
        CALL require(es == CD_SEA_OK, TRIM(tag)//':kinematics: '//TRIM(em))
        eta_r = 0.0_wp
        DO i = 1, sea%n_comp
          th = sea%k(i)*(PX(ip)*sea%cosb(i) + PY(ip)*sea%sinb(i)) - sea%omega(i)*PT(ip) + sea%phase(i)
          eta_r = eta_r + SCL*sea%amplitude(i)*COS(th)
        END DO
        v_r = 0.0_wp
        a_r = 0.0_wp
        p_r = 0.0_wp
        IF (pz(ip) <= eta_r) THEN
          z_e = MIN(0.0_wp, (pz(ip) - eta_r)*depth/(depth + eta_r))
          DO i = 1, sea%n_comp
            th = sea%k(i)*(PX(ip)*sea%cosb(i) + PY(ip)*sea%sinb(i)) - sea%omega(i)*PT(ip) + sea%phase(i)
            e1 = EXP(sea%k(i)*z_e)
            e2 = EXP(-sea%k(i)*(z_e + 2.0_wp*depth))
            ch = (e1 + e2)/(1.0_wp - sea%e2kd(i))
            sh = (e1 - e2)/(1.0_wp - sea%e2kd(i))
            amp = SCL*sea%amplitude(i)*sea%omega(i)
            v_r = v_r + amp*[ch*COS(th)*sea%cosb(i), ch*COS(th)*sea%sinb(i), sh*SIN(th)]
            amp = amp*sea%omega(i)
            a_r = a_r + amp*[ch*SIN(th)*sea%cosb(i), ch*SIN(th)*sea%sinb(i), -sh*COS(th)]
            p_r = p_r + amp/sea%k(i)*ch*COS(th)
          END DO
        END IF
        CALL require(ABS(eta - eta_r) <= 1.0e-11_wp*MAX(1.0_wp, ABS(eta_r)), TRIM(tag)//':eta')
        CALL require(nan_max_abs(v - v_r) <= 1.0e-11_wp*MAX(1.0_wp, MAXVAL(ABS(v_r))), TRIM(tag)//':velocity')
        CALL require(nan_max_abs(a - a_r) <= 1.0e-11_wp*MAX(1.0_wp, MAXVAL(ABS(a_r))), TRIM(tag)//':acceleration')
        CALL require(ABS(p - p_r) <= 1.0e-11_wp*MAX(1.0_wp, ABS(p_r)), TRIM(tag)//':pressure')
      END DO
      ! the last point lies above the surface: the elevation only, no kinematics
      CALL require(pz(SIZE(pz)) > eta_r .AND. MAXVAL(ABS(v)) <= 0.0_wp .AND. MAXVAL(ABS(a)) <= 0.0_wp, &
                   TRIM(tag)//':above-surface')
      ! case 3 reaches both underflows that the two-exponential form handles
      IF (js == 3) CALL require(ANY(sea%e2kd <= TINY(1.0_wp)) .AND. &
                                ANY(EXP(sea%k*(-0.95_wp*depth)) <= TINY(1.0_wp)), TRIM(tag)//':underflow-reached')
    END DO
  END SUBROUTINE case_kinematics_reference

  SUBROUTINE case_parse_rows()
    TYPE(CD_WaveTrainType) :: tr
    CHARACTER(16) :: kw
    LOGICAL :: handled
    INTEGER :: es
    CHARACTER(256) :: em
    CALL CD_Sea_Parse_Train('torsethaugen 6 10 30 waves', kw, handled, tr, es, em)
    CALL require(handled .AND. es == 0 .AND. tr%kind == CD_TRAIN_TORSETHAUGEN .AND. TRIM(kw) == 'waves' &
                 .AND. ABS(tr%direction - 30.0_wp) < 1.0e-12_wp .AND. tr%spreading <= 0.0_wp, &
                 'parse:torsethaugen-waves')
    CALL CD_Sea_Parse_Train('ISSC 3 9 0 4 wavetrain', kw, handled, tr, es, em)
    CALL require(handled .AND. es == 0 .AND. tr%kind == CD_TRAIN_PM .AND. TRIM(kw) == 'wavetrain' &
                 .AND. ABS(tr%spreading - 4.0_wp) < 1.0e-12_wp, 'parse:issc-wavetrain')
    CALL CD_Sea_Parse_Train('ochihubble 3 15 3 2 7 1.2 45 waves', kw, handled, tr, es, em)
    CALL require(handled .AND. es == 0 .AND. tr%kind == CD_TRAIN_OCHIHUBBLE .AND. &
                 ABS(tr%height2 - 2.0_wp) < 1.0e-12_wp &
                 .AND. ABS(tr%lambda2 - 1.2_wp) < 1.0e-12_wp .AND. &
                 ABS(tr%direction - 45.0_wp) < 1.0e-12_wp, 'parse:ochi')
    CALL CD_Sea_Parse_Train('airy 2 8 0 wavetrain', kw, handled, tr, es, em)
    CALL require(handled .AND. es == 0 .AND. tr%kind == CD_TRAIN_AIRY, 'parse:airy-train')
    CALL CD_Sea_Parse_Train('jonswap 2 8 3.3 0 waves', kw, handled, tr, es, em)
    CALL require(.NOT. handled, 'parse:legacy-jonswap-row-left-alone')
    CALL CD_Sea_Parse_Train('airy 2 8 0 waves', kw, handled, tr, es, em)
    CALL require(.NOT. handled, 'parse:legacy-airy-row-left-alone')
    CALL CD_Sea_Parse_Train('pm 3 9 waves', kw, handled, tr, es, em)
    CALL require(handled .AND. es /= 0, 'parse:missing-value')
    CALL CD_Sea_Parse_Train('pm -3 9 0 waves', kw, handled, tr, es, em)
    CALL require(handled .AND. es /= 0, 'parse:negative-hs')
    CALL CD_Sea_Parse_Train('pm 3 9 0 -1 wavetrain', kw, handled, tr, es, em)
    CALL require(handled .AND. es /= 0, 'parse:negative-spreading')
    CALL CD_Sea_Parse_Train('jonswap 3 9 0.5 0 2 wavetrain', kw, handled, tr, es, em)
    CALL require(handled .AND. es /= 0, 'parse:gamma-below-one')
    CALL CD_Sea_Parse_Train('pm 3,5 9 0 waves', kw, handled, tr, es, em)
    CALL require(handled .AND. es /= 0, 'parse:list-separator')
  END SUBROUTINE case_parse_rows

  SUBROUTINE write_deck(path, rows)
    CHARACTER(*), INTENT(IN) :: path, rows(:)
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'spectral sea deck'
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

  LOGICAL FUNCTION files_identical(a, b) RESULT(same)
    CHARACTER(*), INTENT(IN) :: a, b
    INTEGER :: ua, ub, ia, ib
    CHARACTER(4096) :: la, lb
    same = .FALSE.
    OPEN (NEWUNIT=ua, FILE=a, STATUS='OLD', ACTION='READ', IOSTAT=ia)
    OPEN (NEWUNIT=ub, FILE=b, STATUS='OLD', ACTION='READ', IOSTAT=ib)
    IF (ia /= 0 .OR. ib /= 0) RETURN
    DO
      READ (ua, '(A)', IOSTAT=ia) la
      READ (ub, '(A)', IOSTAT=ib) lb
      IF (ia /= 0 .OR. ib /= 0) EXIT
      IF (la /= lb) THEN
        CLOSE (ua)
        CLOSE (ub)
        RETURN
      END IF
    END DO
    same = (ia < 0 .AND. ib < 0)
    CLOSE (ua)
    CLOSE (ub)
  END FUNCTION files_identical

  SUBROUTINE run_ok(tag, rows)
    CHARACTER(*), INTENT(IN) :: tag, rows(:)
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_deck('wspec_'//tag//'.dat', rows)
    CALL CD_Run_Deck_Driver('wspec_'//tag//'.dat', 'wspec_'//tag, conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'deck:'//tag//':runs: '//TRIM(em))
  END SUBROUTINE run_ok

  SUBROUTINE run_bad(tag, rows)
    CHARACTER(*), INTENT(IN) :: tag, rows(:)
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL write_deck('wspec_'//tag//'.dat', rows)
    CALL CD_Run_Deck_Driver('wspec_'//tag//'.dat', 'wspec_'//tag, conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'deck:'//tag//':rejected')
  END SUBROUTINE run_bad

  SUBROUTINE case_deck_runs()
    CHARACTER(64) :: r(4)
    r = ''
    r(1) = 'jonswap 4.0 8.0 3.3 0.0 waves'
    CALL run_ok('legacy', r)
    r(2) = '200 WaveComponents'
    CALL run_ok('legacy_explicit_200', r)
    CALL require(files_identical('wspec_legacy.out', 'wspec_legacy_explicit_200.out'), &
                 'deck:default-WaveComponents-keeps-legacy-bit-identical')
    r = ''
    r(1) = 'jonswap 4.0 8.0 3.3 0.0 waves'
    r(2) = '100 WaveComponents'
    CALL run_ok('jonswap_100', r)
    r = ''
    r(1) = 'torsethaugen 4.0 12.0 20.0 waves'
    CALL run_ok('torsethaugen', r)
    r(2) = '4 WaveSpreading'
    r(3) = '5 WaveDirections'
    r(4) = '60 WaveComponents'
    CALL run_ok('torsethaugen_spread', r)
    CALL require(.NOT. files_identical('wspec_torsethaugen.out', 'wspec_torsethaugen_spread.out'), &
                 'deck:spreading-changes-the-sea')
    r = ''
    r(1) = 'pm 3.0 9.0 0.0 waves'
    CALL run_ok('pm', r)
    r(1) = 'ochihubble 2.0 14.0 3.0 2.5 7.0 1.0 0.0 waves'
    CALL run_ok('ochi', r)
    r(1) = 'jonswap 3.0 8.0 3.3 0.0 2.0 wavetrain'
    r(2) = 'issc 2.0 13.0 60.0 0.0 wavetrain'
    r(3) = 'airy 1.0 10.0 -30.0 wavetrain'
    r(4) = '4 WaveDirections'
    CALL run_ok('three_trains', r)
    r = ''
    r(1) = 'jonswap 3.0 8.0 3.3 0.0 2.0 wavetrain'
    r(2) = 'airy 1.0 10.0 0.0 waves'
    CALL run_bad('train_and_waves', r)
    r = ''
    r(1) = 'airy 1.0 10.0 0.0 waves'
    r(2) = '2 WaveSpreading'
    CALL run_bad('spread_regular', r)
    r(1) = 'jonswap 3.0 8.0 3.3 0.0 2.0 wavetrain'
    CALL run_bad('spread_option_with_trains', r)
    r = ''
    r(1) = '2 WaveSpreading'
    CALL run_bad('spread_without_waves', r)
    r(1) = '1 WaveComponents'
    CALL run_bad('one_component', r)
    r(1) = 'pm 3.0 9.0 0.0 waves'
    r(2) = '2.5 WaveDirections'
    CALL run_bad('fractional_directions', r)
  END SUBROUTINE case_deck_runs

END PROGRAM test_wave_spectra
