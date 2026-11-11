! File: src/CableDyn_WaveSpectra.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_WaveSpectra
  !! Wave spectra, directional spreading and multi-train seas of the standalone deck.
  !!
  !! A sea is a list of wave trains, each regular (Airy) or spectral (JONSWAP, ISSC /
  !! Pierson-Moskowitz, Torsethaugen two-peak, Ochi-Hubble two-peak), with its own mean
  !! heading and an optional cos-2s spreading exponent. Every train is discretised into
  !! linear components (frequency x direction), the components of all trains are summed,
  !! and the kinematics follow the conventions of CableDyn_Hydro's component evaluator:
  !! the total surface elevation is summed first, ONE Wheeler mapping of the evaluation
  !! depth is taken against it, and the per-component velocity and local (Eulerian)
  !! acceleration are summed at the stretched depth. The regular nonlinear (stream
  !! function) wave is a separate, single-train model (CableDyn_StreamWave).
  !!
  !! Spectra are one-sided in angular frequency, S(omega) [m^2 s/rad], with the zeroth
  !! moment m0 = Hs^2/16:
  !!   ISSC / Pierson-Moskowitz (Bretschneider):
  !!     S = (5/16) Hs^2 wp^4 w^-5 exp(-(5/4)(wp/w)^4)
  !!   JONSWAP:  S = A_gamma S_PM gamma^exp(-(w-wp)^2/(2 sigma^2 wp^2)),
  !!     A_gamma = 1 - 0.287 ln(gamma), sigma = 0.07 (w <= wp) or 0.09
  !!   Torsethaugen (DNV-RP-C205 Sec. 3.5.6): two JONSWAP-like partitions of form
  !!     E_j G0 A_gj w_j^-4 exp(-w_j^-4) gamma_j^exp(-(w_j-1)^2/(2 sigma^2)),
  !!     w_j = w Tpj/(2 pi), G0 = 3.26, A_g = (1 + 1.1 (ln gamma)^1.19)/gamma, with the
  !!     wind-sea / swell partition of CD_Torsethaugen_Partition
  !!   Ochi-Hubble: S = (1/4) sum_j ((4 l_j+1)/4 wm_j^4)^l_j / Gamma(l_j) Hs_j^2
  !!                    w^-(4 l_j+1) exp(-((4 l_j+1)/4)(wm_j/w)^4)
  !! Spreading (OrcaFlex convention): D(theta) = K(s) cos^2s(theta - theta_p) for
  !! |theta - theta_p| <= pi/2, K(s) = Gamma(s+1)/(sqrt(pi) Gamma(s+1/2)).
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_Is_Finite
  USE CableDyn_Hydro, ONLY: CD_Solve_Dispersion_Wavenumber, CD_HYDRO_OK
  USE CableDyn_WaveMath, ONLY: CD_Wave_SinCos, CD_Wave_Exp, CD_Wave_Sum_Lanes, CD_WAVE_LANES
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: INT64
  IMPLICIT NONE
  PRIVATE

  INTEGER, PARAMETER, PUBLIC :: CD_SEA_OK = 0, CD_SEA_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_TRAIN_AIRY = 1, CD_TRAIN_JONSWAP = 2, CD_TRAIN_PM = 3, &
                                CD_TRAIN_TORSETHAUGEN = 4, CD_TRAIN_OCHIHUBBLE = 5
  INTEGER, PARAMETER, PUBLIC :: CD_SEA_DEFAULT_COMPONENTS = 200
  INTEGER, PARAMETER, PUBLIC :: CD_SEA_DEFAULT_DIRECTIONS = 9
  INTEGER, PARAMETER, PUBLIC :: CD_SEA_MAX_TRAINS = 16
  INTEGER, PARAMETER, PUBLIC :: CD_SEA_MAX_COMPONENTS = 100000
  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  REAL(wp), PARAMETER :: DEG2RAD = PI/180.0_wp
  REAL(wp), PARAMETER :: TORS_G0 = 3.26_wp

  TYPE, PUBLIC :: CD_WaveTrainType
    INTEGER :: kind = CD_TRAIN_AIRY
    ! Airy: height, period; spectral: Hs, Tp (Ochi-Hubble: first partition)
    REAL(wp) :: height = CD_ZERO, period = CD_ZERO
    REAL(wp) :: gamma = CD_ONE
    ! Ochi-Hubble second partition and shape parameters
    REAL(wp) :: height2 = CD_ZERO, period2 = CD_ZERO, lambda1 = CD_ONE, lambda2 = CD_ONE
    REAL(wp) :: direction = CD_ZERO      ! mean heading [deg], waves travel toward it
    REAL(wp) :: spreading = CD_ZERO      ! cos-2s exponent; 0 = long-crested
  END TYPE CD_WaveTrainType

  TYPE, PUBLIC :: CD_SeaType
    INTEGER :: n_trains = 0
    TYPE(CD_WaveTrainType) :: trains(CD_SEA_MAX_TRAINS)
    INTEGER :: n_freq = CD_SEA_DEFAULT_COMPONENTS   ! frequency components per train and direction
    INTEGER :: n_dir = 0                             ! directions of a spread train; 0 = default
    ! the synthesised component table (all trains)
    INTEGER :: n_comp = 0
    REAL(wp), ALLOCATABLE :: omega(:), k(:), amplitude(:), phase(:), cosb(:), sinb(:), e2kd(:)
    REAL(wp) :: depth = CD_ZERO   ! the water depth of the synthesis: k and e2kd = EXP(-2 k depth)
    LOGICAL :: ready = .FALSE.
  END TYPE CD_SeaType

  PUBLIC :: CD_Spectrum_Density, CD_Train_Band, CD_Torsethaugen_Partition
  PUBLIC :: CD_Spreading_Constant, CD_Spreading_Weights
  PUBLIC :: CD_Sea_Parse_Train, CD_Sea_Add_Train, CD_Sea_Validate_Train
  PUBLIC :: CD_Sea_Synthesise, CD_Sea_Kinematics, CD_Sea_Reset

CONTAINS

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_SEA_BADINPUT
    ErrMsg = 'CableDyn_WaveSpectra: '//msg
  END SUBROUTINE fail

  PURE SUBROUTINE CD_Torsethaugen_Partition(hs, tp, gravity, h1, tp1, gamma1, h2, tp2, gamma2)
    !! Wind-sea / swell partition of the simplified Torsethaugen spectrum (DNV-RP-C205,
    !! Sec. 3.5.6). Tf = 6.6 Hs^(1/3) separates the wind-dominated (Tp <= Tf) and the
    !! swell-dominated (Tp > Tf) seas. Partition 1 is the primary (peak) sea with peak
    !! period Tp and enhancement gamma1; partition 2 is the secondary sea (gamma2 = 1),
    !! with h1^2 + h2^2 = Hs^2.
    !!  wind dominated: eps_l = (Tf - Tp)/(Tf - Tl), Tl = 2 Hs^(1/2) (clamped to [0, 1]),
    !!    r = 0.7 + 0.3 exp(-(2 eps_l)^2), h1 = r Hs, gamma1 = 35 (2 pi h1/(g Tp^2))^0.857,
    !!    h2 = sqrt(1 - r^2) Hs, tp2 = Tf + 2
    !!  swell dominated: eps_u = (Tp - Tf)/(Tu - Tf), Tu = 25 s (clamped to [0, 1]),
    !!    r = 0.6 + 0.4 exp(-(eps_u/0.3)^2), h1 = r Hs,
    !!    gamma1 = 35 (2 pi Hs/(g Tf^2))^0.857 (1 + 6 eps_u),
    !!    h2 = sqrt(1 - r^2) Hs, tp2 = 6.6 h2^(1/3)
    !! gamma1 is clamped to >= 1.
    REAL(wp), INTENT(IN) :: hs, tp, gravity
    REAL(wp), INTENT(OUT) :: h1, tp1, gamma1, h2, tp2, gamma2
    REAL(wp) :: tf, tl, eps, r
    REAL(wp), PARAMETER :: TU = 25.0_wp

    tf = 6.6_wp*hs**(CD_ONE/3.0_wp)
    tp1 = tp
    gamma2 = CD_ONE
    IF (tp <= tf) THEN
      tl = 2.0_wp*SQRT(hs)
      IF (tf - tl > CD_ZERO) THEN
        eps = MIN(CD_ONE, MAX(CD_ZERO, (tf - tp)/(tf - tl)))
      ELSE
        eps = CD_ZERO
      END IF
      r = 0.7_wp + 0.3_wp*EXP(-(2.0_wp*eps)**2)
      h1 = r*hs
      gamma1 = 35.0_wp*(2.0_wp*PI*h1/(gravity*tp*tp))**0.857_wp
      h2 = SQRT(MAX(CD_ZERO, CD_ONE - r*r))*hs
      tp2 = tf + 2.0_wp
    ELSE
      IF (TU - tf > CD_ZERO) THEN
        eps = MIN(CD_ONE, MAX(CD_ZERO, (tp - tf)/(TU - tf)))
      ELSE
        eps = CD_ONE
      END IF
      r = 0.6_wp + 0.4_wp*EXP(-(eps/0.3_wp)**2)
      h1 = r*hs
      gamma1 = 35.0_wp*(2.0_wp*PI*hs/(gravity*tf*tf))**0.857_wp*(CD_ONE + 6.0_wp*eps)
      h2 = SQRT(MAX(CD_ZERO, CD_ONE - r*r))*hs
      tp2 = 6.6_wp*h2**(CD_ONE/3.0_wp)
    END IF
    gamma1 = MAX(CD_ONE, gamma1)
  END SUBROUTINE CD_Torsethaugen_Partition

  PURE REAL(wp) FUNCTION jonswap_shape(omega, hs, tp, gamma) RESULT(s)
    !! A_gamma S_PM gamma^r (the DNV-RP-C205 JONSWAP), the formula of the JONSWAP train.
    REAL(wp), INTENT(IN) :: omega, hs, tp, gamma
    REAL(wp) :: wp_, sigma, r
    wp_ = 2.0_wp*PI/tp
    s = (5.0_wp/16.0_wp)*hs*hs*wp_**4*omega**(-5)*EXP(-1.25_wp*(wp_/omega)**4)
    IF (gamma > CD_ONE) THEN
      sigma = MERGE(0.07_wp, 0.09_wp, omega <= wp_)
      r = EXP(-0.5_wp*((omega - wp_)/(sigma*wp_))**2)
      s = (CD_ONE - 0.287_wp*LOG(gamma))*s*gamma**r
    END IF
  END FUNCTION jonswap_shape

  PURE REAL(wp) FUNCTION torsethaugen_part(omega, h, tpj, gamma) RESULT(s)
    !! One Torsethaugen partition: E G0 A_g w^-4 exp(-w^-4) gamma^exp(-(w-1)^2/(2 sigma^2))
    !! with w = omega Tp/(2 pi) and E = h^2 Tp/(16 (2 pi)), so m0 ~= h^2/16.
    REAL(wp), INTENT(IN) :: omega, h, tpj, gamma
    REAL(wp) :: w, sigma, ag, e
    s = CD_ZERO
    IF (.NOT. (h > CD_ZERO .AND. tpj > CD_ZERO)) RETURN
    w = omega*tpj/(2.0_wp*PI)
    IF (gamma > CD_ONE) THEN
      ag = (CD_ONE + 1.1_wp*LOG(gamma)**1.19_wp)/gamma
    ELSE
      ag = CD_ONE
    END IF
    sigma = MERGE(0.07_wp, 0.09_wp, w <= CD_ONE)
    e = h*h*tpj/(16.0_wp*2.0_wp*PI)
    s = e*TORS_G0*ag*w**(-4)*EXP(-w**(-4))*gamma**EXP(-0.5_wp*((w - CD_ONE)/sigma)**2)
  END FUNCTION torsethaugen_part

  PURE REAL(wp) FUNCTION ochi_part(omega, h, tpj, lam) RESULT(s)
    !! One Ochi-Hubble partition (m0 = h^2/16 exactly).
    REAL(wp), INTENT(IN) :: omega, h, tpj, lam
    REAL(wp) :: wm, c
    s = CD_ZERO
    IF (.NOT. (h > CD_ZERO .AND. tpj > CD_ZERO)) RETURN
    wm = 2.0_wp*PI/tpj
    c = (4.0_wp*lam + CD_ONE)/4.0_wp
    s = 0.25_wp*(c*wm**4)**lam/GAMMA(lam)*h*h*omega**(-(4.0_wp*lam + CD_ONE))*EXP(-c*(wm/omega)**4)
  END FUNCTION ochi_part

  PURE REAL(wp) FUNCTION CD_Spectrum_Density(train, omega, gravity) RESULT(s)
    !! One-sided spectral density S(omega) [m^2 s/rad] of a spectral train, from its
    !! published formula (module header). Zero for omega <= 0 and for a regular train.
    TYPE(CD_WaveTrainType), INTENT(IN) :: train
    REAL(wp), INTENT(IN) :: omega, gravity
    REAL(wp) :: h1, tp1, g1, h2, tp2, g2
    s = CD_ZERO
    IF (.NOT. (omega > CD_ZERO)) RETURN
    SELECT CASE (train%kind)
    CASE (CD_TRAIN_PM)
      s = jonswap_shape(omega, train%height, train%period, CD_ONE)
    CASE (CD_TRAIN_JONSWAP)
      s = jonswap_shape(omega, train%height, train%period, train%gamma)
    CASE (CD_TRAIN_TORSETHAUGEN)
      CALL CD_Torsethaugen_Partition(train%height, train%period, gravity, h1, tp1, g1, h2, tp2, g2)
      s = torsethaugen_part(omega, h1, tp1, g1) + torsethaugen_part(omega, h2, tp2, g2)
    CASE (CD_TRAIN_OCHIHUBBLE)
      s = ochi_part(omega, train%height, train%period, train%lambda1) + &
          ochi_part(omega, train%height2, train%period2, train%lambda2)
    END SELECT
  END FUNCTION CD_Spectrum_Density

  PURE SUBROUTINE CD_Train_Band(train, gravity, omega_min, omega_max)
    !! Synthesis band of a spectral train: [0.2, 5] times the lowest and highest partition
    !! peak frequencies.
    TYPE(CD_WaveTrainType), INTENT(IN) :: train
    REAL(wp), INTENT(IN) :: gravity
    REAL(wp), INTENT(OUT) :: omega_min, omega_max
    REAL(wp) :: h1, tp1, g1, h2, tp2, g2, tlo, thi
    tlo = train%period
    thi = train%period
    SELECT CASE (train%kind)
    CASE (CD_TRAIN_TORSETHAUGEN)
      CALL CD_Torsethaugen_Partition(train%height, train%period, gravity, h1, tp1, g1, h2, tp2, g2)
      IF (h2 > CD_ZERO) THEN
        tlo = MIN(tp1, tp2)
        thi = MAX(tp1, tp2)
      END IF
    CASE (CD_TRAIN_OCHIHUBBLE)
      IF (train%height2 > CD_ZERO) THEN
        tlo = MIN(train%period, train%period2)
        thi = MAX(train%period, train%period2)
      END IF
    END SELECT
    ! the expressions of CD_JONSWAP_Random_Components, so a one-peak train reproduces its band
    omega_min = 0.2_wp*(2.0_wp*PI/thi)
    omega_max = 5.0_wp*(2.0_wp*PI/tlo)
  END SUBROUTINE CD_Train_Band

  PURE REAL(wp) FUNCTION CD_Spreading_Constant(s) RESULT(k)
    !! K(s) = Gamma(s+1)/(sqrt(pi) Gamma(s+1/2)), the normalisation of cos^2s on +-pi/2.
    REAL(wp), INTENT(IN) :: s
    k = EXP(LOG_GAMMA(s + CD_ONE) - LOG_GAMMA(s + 0.5_wp))/SQRT(PI)
  END FUNCTION CD_Spreading_Constant

  PURE SUBROUTINE CD_Spreading_Weights(s, n, offset, weight)
    !! Discretise D(theta) = K(s) cos^2s(theta) on [-pi/2, pi/2] into n equal-angle bins:
    !! offset(j) [rad] is the bin centre and weight(j) the bin integral of D (composite
    !! Simpson quadrature, 128 intervals per bin), normalised to sum 1. A bin below the smallest
    !! normal number holds no energy: its weight is exactly zero, so which bins carry the sea
    !! depends on s and n alone, not on where the spectrum's product with it underflows.
    REAL(wp), INTENT(IN) :: s
    INTEGER, INTENT(IN) :: n
    REAL(wp), INTENT(OUT) :: offset(n), weight(n)
    INTEGER, PARAMETER :: NQ = 128
    INTEGER :: j, q
    REAL(wp) :: a, b, h, th, f, total, kc

    kc = CD_Spreading_Constant(s)
    DO j = 1, n
      a = -0.5_wp*PI + PI*REAL(j - 1, wp)/REAL(n, wp)
      b = -0.5_wp*PI + PI*REAL(j, wp)/REAL(n, wp)
      offset(j) = 0.5_wp*(a + b)
      h = (b - a)/REAL(NQ, wp)
      weight(j) = CD_ZERO
      DO q = 0, NQ
        th = a + h*REAL(q, wp)
        f = kc*MAX(CD_ZERO, COS(th))**(2.0_wp*s)
        IF (q == 0 .OR. q == NQ) THEN
          weight(j) = weight(j) + f
        ELSE IF (MOD(q, 2) == 1) THEN
          weight(j) = weight(j) + 4.0_wp*f
        ELSE
          weight(j) = weight(j) + 2.0_wp*f
        END IF
      END DO
      weight(j) = weight(j)*h/3.0_wp
    END DO
    total = SUM(weight)
    IF (total > CD_ZERO) weight = weight/total
    WHERE (weight < TINY(CD_ONE)) weight = CD_ZERO
  END SUBROUTINE CD_Spreading_Weights

  SUBROUTINE CD_Sea_Reset(sea)
    TYPE(CD_SeaType), INTENT(INOUT) :: sea
    sea%n_trains = 0
    sea%n_comp = 0
    sea%ready = .FALSE.
    IF (ALLOCATED(sea%omega)) DEALLOCATE (sea%omega, sea%k, sea%amplitude, sea%phase, sea%cosb, sea%sinb, sea%e2kd)
  END SUBROUTINE CD_Sea_Reset

  SUBROUTINE CD_Sea_Validate_Train(train, ErrStat, ErrMsg)
    TYPE(CD_WaveTrainType), INTENT(IN) :: train
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = CD_SEA_OK
    ErrMsg = ''
    IF (.NOT. (CD_Is_Finite(train%height) .AND. train%height > CD_ZERO .AND. &
               CD_Is_Finite(train%period) .AND. train%period > CD_ZERO .AND. CD_Is_Finite(train%direction))) THEN
      CALL fail(ErrStat, ErrMsg, 'a wave train needs finite positive height and period and a finite direction')
      RETURN
    END IF
    ! admissible magnitudes: a larger height or a shorter period overflows the kinematics
    ! (and the drag on them) instead of failing to converge
    IF (train%height > 1.0e3_wp .OR. train%period < 0.1_wp .OR. train%period > 1.0e5_wp .OR. &
        ABS(train%direction) > 1.0e6_wp) THEN
      CALL fail(ErrStat, ErrMsg, 'a wave train needs height <= 1e3 m, period in [0.1, 1e5] s and '// &
                '|direction| <= 1e6 deg')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(train%spreading) .AND. train%spreading >= CD_ZERO .AND. &
               train%spreading <= 1000.0_wp)) THEN
      CALL fail(ErrStat, ErrMsg, 'the wave spreading exponent s must be finite and in [0, 1000]')
      RETURN
    END IF
    IF (train%kind == CD_TRAIN_AIRY .AND. train%spreading > CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'a regular (airy) wave train cannot be spread')
      RETURN
    END IF
    ! A_gamma = 1 - 0.287 ln(gamma) stays positive for gamma < exp(1/0.287) = 32.6.
    IF (train%kind == CD_TRAIN_JONSWAP .AND. .NOT. (CD_Is_Finite(train%gamma) .AND. train%gamma >= CD_ONE &
                                                    .AND. train%gamma < EXP(CD_ONE/0.287_wp))) THEN
      CALL fail(ErrStat, ErrMsg, 'JONSWAP gamma must be in [1, 32.6)')
      RETURN
    END IF
    IF (train%kind == CD_TRAIN_OCHIHUBBLE) THEN
      IF (.NOT. (CD_Is_Finite(train%height2) .AND. train%height2 >= CD_ZERO .AND. &
                 CD_Is_Finite(train%period2) .AND. train%period2 > CD_ZERO .AND. &
                 CD_Is_Finite(train%lambda1) .AND. train%lambda1 > CD_ZERO .AND. train%lambda1 <= 50.0_wp .AND. &
                 CD_Is_Finite(train%lambda2) .AND. train%lambda2 > CD_ZERO .AND. train%lambda2 <= 50.0_wp)) THEN
        CALL fail(ErrStat, ErrMsg, 'Ochi-Hubble needs Hs1, Tp1 > 0, Hs2 >= 0, Tp2 > 0 and shape '// &
                  'parameters lambda1, lambda2 in (0, 50]')
        RETURN
      END IF
      IF (train%height2 > 1.0e3_wp .OR. train%period2 < 0.1_wp .OR. train%period2 > 1.0e5_wp) THEN
        CALL fail(ErrStat, ErrMsg, 'Ochi-Hubble needs Hs2 <= 1e3 m and Tp2 in [0.1, 1e5] s')
        RETURN
      END IF
    END IF
  END SUBROUTINE CD_Sea_Validate_Train

  SUBROUTINE CD_Sea_Add_Train(sea, train, ErrStat, ErrMsg)
    TYPE(CD_SeaType), INTENT(INOUT) :: sea
    TYPE(CD_WaveTrainType), INTENT(IN) :: train
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL CD_Sea_Validate_Train(train, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SEA_OK) RETURN
    IF (sea%n_trains >= CD_SEA_MAX_TRAINS) THEN
      CALL fail(ErrStat, ErrMsg, 'too many wave trains (at most 16)')
      RETURN
    END IF
    sea%n_trains = sea%n_trains + 1
    sea%trains(sea%n_trains) = train
    sea%ready = .FALSE.
  END SUBROUTINE CD_Sea_Add_Train

  SUBROUTINE CD_Sea_Parse_Train(line, keyword, handled, train, ErrStat, ErrMsg)
    !! Recognise a positional wave-train row "<type> <values...> <keyword>", keyword
    !! "waves"/"wave" (the single-train form, no spreading token) or "wavetrain" (the
    !! multi-train form, which ends with a spreading exponent s except for airy):
    !!   pm|issc|bretschneider Hs Tp dir [s]
    !!   jonswap Hs Tp gamma dir [s]              (wavetrain only; waves keeps the legacy row)
    !!   torsethaugen Hs Tp dir [s]
    !!   ochihubble Hs1 Tp1 lambda1 Hs2 Tp2 lambda2 dir [s]
    !!   airy H T dir                             (wavetrain only)
    !! handled = .TRUE. when the row is one of these forms (then ErrStat reports its
    !! validity); keyword returns 'waves' or 'wavetrain'.
    CHARACTER(*), INTENT(IN) :: line
    CHARACTER(*), INTENT(OUT) :: keyword
    LOGICAL, INTENT(OUT) :: handled
    TYPE(CD_WaveTrainType), INTENT(OUT) :: train
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, PARAMETER :: MAXTOK = 12
    CHARACTER(64) :: tok(MAXTOK)
    INTEGER :: ntok, nval, need, i, ios
    REAL(wp) :: v(MAXTOK)
    CHARACTER(64) :: mode, last
    LOGICAL :: multi

    handled = .FALSE.
    keyword = ''
    ErrStat = CD_SEA_OK
    ErrMsg = ''
    CALL tokenize(line, tok, ntok)
    IF (ntok < 4 .OR. ntok > MAXTOK) RETURN
    mode = lower(tok(1))
    last = lower(tok(ntok))
    IF (TRIM(last) == 'wavetrain' .OR. TRIM(last) == 'wave_train') THEN
      multi = .TRUE.
    ELSE IF (TRIM(last) == 'waves' .OR. TRIM(last) == 'wave') THEN
      multi = .FALSE.
    ELSE
      RETURN
    END IF
    SELECT CASE (TRIM(mode))
    CASE ('pm', 'issc', 'bretschneider', 'piersonmoskowitz', 'pierson-moskowitz')
      train%kind = CD_TRAIN_PM
      need = 3
    CASE ('jonswap')
      IF (.NOT. multi) RETURN
      train%kind = CD_TRAIN_JONSWAP
      need = 4
    CASE ('torsethaugen')
      train%kind = CD_TRAIN_TORSETHAUGEN
      need = 3
    CASE ('ochihubble', 'ochi-hubble', 'ochi_hubble')
      train%kind = CD_TRAIN_OCHIHUBBLE
      need = 7
    CASE ('airy')
      IF (.NOT. multi) RETURN
      train%kind = CD_TRAIN_AIRY
      need = 3
    CASE DEFAULT
      RETURN
    END SELECT
    handled = .TRUE.
    keyword = MERGE('wavetrain', 'waves    ', multi)
    IF (multi .AND. train%kind /= CD_TRAIN_AIRY) need = need + 1
    nval = ntok - 2
    IF (nval /= need) THEN
      CALL fail(ErrStat, ErrMsg, 'wave row "'//TRIM(tok(1))//' ... '//TRIM(tok(ntok))//'" needs '// &
                TRIM(itoa(need))//' values')
      RETURN
    END IF
    DO i = 1, nval
      IF (SCAN(tok(i + 1), '/,;*') > 0) THEN
        CALL fail(ErrStat, ErrMsg, 'wave row value "'//TRIM(tok(i + 1))//'" must be a plain number')
        RETURN
      END IF
      READ (tok(i + 1), *, IOSTAT=ios) v(i)
      IF (ios /= 0) THEN
        CALL fail(ErrStat, ErrMsg, 'wave row value "'//TRIM(tok(i + 1))//'" is not a number')
        RETURN
      END IF
      ! classified before any ordered comparison: NaN/Inf and subnormal values fail here
      IF (.NOT. CD_Is_Finite(v(i))) THEN
        CALL fail(ErrStat, ErrMsg, 'wave row value "'//TRIM(tok(i + 1))//'" must be a finite number')
        RETURN
      END IF
      IF (ABS(v(i)) > CD_ZERO) THEN
        IF (ABS(v(i)) < TINY(v(i))) THEN
          CALL fail(ErrStat, ErrMsg, 'wave row value "'//TRIM(tok(i + 1))//'" is subnormal; write 0 or a '// &
                    'normal number')
          RETURN
        END IF
      END IF
    END DO
    train%height = v(1)
    train%period = v(2)
    SELECT CASE (train%kind)
    CASE (CD_TRAIN_JONSWAP)
      train%gamma = v(3)
      train%direction = v(4)
      IF (multi) train%spreading = v(5)
    CASE (CD_TRAIN_OCHIHUBBLE)
      train%lambda1 = v(3)
      train%height2 = v(4)
      train%period2 = v(5)
      train%lambda2 = v(6)
      train%direction = v(7)
      IF (multi) train%spreading = v(8)
    CASE (CD_TRAIN_AIRY)
      train%direction = v(3)
    CASE DEFAULT
      train%direction = v(3)
      IF (multi) train%spreading = v(4)
    END SELECT
    CALL CD_Sea_Validate_Train(train, ErrStat, ErrMsg)
  END SUBROUTINE CD_Sea_Parse_Train

  SUBROUTINE CD_Sea_Synthesise(sea, depth, gravity, seed, ErrStat, ErrMsg)
    !! Discretise every train into components. A regular train is one component
    !! (amplitude H/2, phase 0). A spectral train uses n_freq equal frequency bins over
    !! its band (CD_Train_Band) per direction; each component sits at a uniformly random
    !! frequency inside its bin with a uniformly random phase (the bin-jittered
    !! random-phase synthesis of the JONSWAP train, same MINSTD stream). A spread train
    !! (s > 0) has n_dir equal-angle direction bins over theta_p +- 90 deg carrying the
    !! cos-2s bin weights (CD_Spreading_Weights), each with its own independent frequency
    !! set. Amplitudes are sqrt(2 S(omega) d_omega w_dir), with the train's discrete zeroth
    !! moment scaled to exactly Hs^2/16. Train i draws from seed + 7919 (i - 1).
    TYPE(CD_SeaType), INTENT(INOUT) :: sea
    REAL(wp), INTENT(IN) :: depth, gravity
    INTEGER, INTENT(IN) :: seed
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: it, n_total, nd, j, i, c, c0, n
    ! The component count is summed in 64-bit: n_freq*n_dir can exceed a default integer.
    INTEGER(INT64) :: n_total64
    REAL(wp) :: wmin, wmax, dw, m0, scale, beta
    REAL(wp), ALLOCATABLE :: off(:), wdir(:)
    INTEGER(INT64) :: state

    ErrStat = CD_SEA_OK
    ErrMsg = ''
    sea%ready = .FALSE.
    IF (sea%n_trains < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'a sea needs at least one wave train')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(depth) .AND. depth > CD_ZERO .AND. CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'sea synthesis needs finite positive depth and gravity')
      RETURN
    END IF
    IF (sea%n_freq < 2 .OR. sea%n_dir < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'WaveComponents must be >= 2 and WaveDirections >= 0 (0 = the default)')
      RETURN
    END IF
    IF (seed < 1) THEN
      CALL fail(ErrStat, ErrMsg, 'the wave seed must be a positive integer')
      RETURN
    END IF
    n_total64 = 0_INT64
    DO it = 1, sea%n_trains
      CALL CD_Sea_Validate_Train(sea%trains(it), ErrStat, ErrMsg)
      IF (ErrStat /= CD_SEA_OK) RETURN
      n_total64 = n_total64 + train_components(sea, sea%trains(it))
    END DO
    IF (n_total64 > INT(CD_SEA_MAX_COMPONENTS, INT64)) THEN
      CALL fail(ErrStat, ErrMsg, 'the sea has more than 100000 components; reduce WaveComponents or '// &
                'WaveDirections')
      RETURN
    END IF
    n_total = INT(n_total64)
    IF (ALLOCATED(sea%omega)) DEALLOCATE (sea%omega, sea%k, sea%amplitude, sea%phase, sea%cosb, sea%sinb, sea%e2kd)
    ALLOCATE (sea%omega(n_total), sea%k(n_total), sea%amplitude(n_total), sea%phase(n_total), &
              sea%cosb(n_total), sea%sinb(n_total), sea%e2kd(n_total))
    c = 0
    DO it = 1, sea%n_trains
      ASSOCIATE (tr => sea%trains(it))
        IF (tr%kind == CD_TRAIN_AIRY) THEN
          c = c + 1
          sea%omega(c) = 2.0_wp*PI/tr%period
          sea%amplitude(c) = 0.5_wp*tr%height
          sea%phase(c) = CD_ZERO
          sea%cosb(c) = COS(tr%direction*DEG2RAD)
          sea%sinb(c) = SIN(tr%direction*DEG2RAD)
          CYCLE
        END IF
        nd = 1
        IF (tr%spreading > CD_ZERO) nd = MERGE(sea%n_dir, CD_SEA_DEFAULT_DIRECTIONS, sea%n_dir > 0)
        IF (ALLOCATED(off)) DEALLOCATE (off, wdir)
        ALLOCATE (off(nd), wdir(nd))
        IF (nd == 1) THEN
          off = CD_ZERO
          wdir = CD_ONE
        ELSE
          CALL CD_Spreading_Weights(tr%spreading, nd, off, wdir)
        END IF
        CALL seed_state(seed_for_train(seed, it), state)
        CALL CD_Train_Band(tr, gravity, wmin, wmax)
        n = sea%n_freq
        dw = (wmax - wmin)/REAL(n, wp)
        c0 = c
        m0 = CD_ZERO
        DO j = 1, nd
          beta = tr%direction*DEG2RAD + off(j)
          DO i = 1, n
            c = c + 1
            sea%omega(c) = wmin + (REAL(i - 1, wp) + next_uniform(state))*dw
            sea%phase(c) = 2.0_wp*PI*next_uniform(state)
            sea%amplitude(c) = CD_Spectrum_Density(tr, sea%omega(c), gravity)*wdir(j)
            m0 = m0 + sea%amplitude(c)*dw
            sea%cosb(c) = COS(beta)
            sea%sinb(c) = SIN(beta)
          END DO
        END DO
        IF (.NOT. (m0 > CD_ZERO .AND. CD_Is_Finite(m0))) THEN
          CALL fail(ErrStat, ErrMsg, 'a wave spectrum has zero or non-finite energy in its band')
          RETURN
        END IF
        scale = (tr%height*tr%height/16.0_wp)/m0
        IF (tr%kind == CD_TRAIN_OCHIHUBBLE) &
          scale = ((tr%height**2 + tr%height2**2)/16.0_wp)/m0
        DO i = c0 + 1, c
          sea%amplitude(i) = SQRT(2.0_wp*sea%amplitude(i)*scale*dw)
        END DO
      END ASSOCIATE
    END DO
    DO i = 1, n_total
      CALL CD_Solve_Dispersion_Wavenumber(sea%omega(i), depth, gravity, sea%k(i), ErrStat, ErrMsg)
      IF (ErrStat /= CD_HYDRO_OK) THEN
        ErrStat = CD_SEA_BADINPUT
        RETURN
      END IF
      sea%e2kd(i) = EXP(-2.0_wp*sea%k(i)*depth)
    END DO
    sea%n_comp = n_total
    sea%depth = depth
    sea%ready = .TRUE.
  END SUBROUTINE CD_Sea_Synthesise

  PURE INTEGER(INT64) FUNCTION train_components(sea, tr) RESULT(n)
    !! Number of components of one train, in 64-bit so that n_freq*n_dir cannot overflow.
    TYPE(CD_SeaType), INTENT(IN) :: sea
    TYPE(CD_WaveTrainType), INTENT(IN) :: tr
    IF (tr%kind == CD_TRAIN_AIRY) THEN
      n = 1_INT64
    ELSE IF (tr%spreading > CD_ZERO) THEN
      n = INT(sea%n_freq, INT64)*INT(MERGE(sea%n_dir, CD_SEA_DEFAULT_DIRECTIONS, sea%n_dir > 0), INT64)
    ELSE
      n = INT(sea%n_freq, INT64)
    END IF
  END FUNCTION train_components

  PURE INTEGER FUNCTION seed_for_train(seed, it) RESULT(s)
    INTEGER, INTENT(IN) :: seed, it
    s = INT(MOD(INT(seed, INT64) - 1_INT64 + 7919_INT64*INT(it - 1, INT64), 2147483646_INT64) + 1_INT64)
  END FUNCTION seed_for_train

  PURE SUBROUTINE seed_state(seed, state)
    !! The seeding of CD_JONSWAP_Random_Components: three xorshift rounds, one MINSTD step.
    INTEGER, INTENT(IN) :: seed
    INTEGER(INT64), INTENT(OUT) :: state
    INTEGER(INT64), PARAMETER :: MINSTD_M = 2147483647_INT64, MINSTD_A = 48271_INT64
    INTEGER(INT64), PARAMETER :: MASK31 = 2147483647_INT64
    INTEGER :: r
    state = IAND(INT(seed, INT64), MASK31)
    DO r = 1, 3
      state = IEOR(state, IAND(ISHFT(state, 13), MASK31))
      state = IEOR(state, ISHFT(state, -17))
      state = IEOR(state, IAND(ISHFT(state, 5), MASK31))
    END DO
    state = MOD(state, MINSTD_M)
    IF (state == 0_INT64) state = 1_INT64
    state = MOD(MINSTD_A*state, MINSTD_M)
  END SUBROUTINE seed_state

  REAL(wp) FUNCTION next_uniform(state) RESULT(u)
    INTEGER(INT64), INTENT(INOUT) :: state
    INTEGER(INT64), PARAMETER :: MINSTD_M = 2147483647_INT64, MINSTD_A = 48271_INT64
    state = MOD(MINSTD_A*state, MINSTD_M)
    u = REAL(state, wp)/REAL(MINSTD_M, wp)
  END FUNCTION next_uniform

  SUBROUTINE CD_Sea_Kinematics(sea, x, y, z, t, depth, scale, eta, velocity, acceleration, ErrStat, ErrMsg, pdyn)
    !! Linear multi-directional sea kinematics at (x, y, z, t) with Wheeler stretching.
    !! scale multiplies every amplitude (the start-up ramp). pdyn: the linear dynamic
    !! pressure per unit density at the stretched depth [m^2/s^2]; zero above the surface.
    !! The phase sines and cosines (one argument reduction for both) and the depth exponentials
    !! come from the block kernels of CableDyn_WaveMath, and the sums run in interleaved lanes
    !! added up at the end (CD_Wave_Sum_Lanes), so that they vectorise in a fixed order; the
    !! amplitude scale multiplies the finished sums.
    TYPE(CD_SeaType), INTENT(IN) :: sea
    REAL(wp), INTENT(IN) :: x, y, z, t, depth, scale
    REAL(wp), INTENT(OUT) :: eta, velocity(3), acceleration(3)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: pdyn
    INTEGER, PARAMETER :: NB = 256
    ! The phase cosines and sines of the elevation pass, kept for the kinematics pass (whose
    ! chunk loop would compute the same values again), for the first NKEEP components; the rest
    ! are recomputed there. A multiple of NB, so each chunk is either kept whole or recomputed.
    INTEGER, PARAMETER :: NKEEP = 16*NB
    REAL(wp) :: th(NB), cth(NB), sth(NB), ch(NB), sh(NB), e_low(NB), ckeep(NKEEP), skeep(NKEEP)
    REAL(wp) :: lane_eta(CD_WAVE_LANES), lane_vx(CD_WAVE_LANES), lane_vy(CD_WAVE_LANES), lane_vz(CD_WAVE_LANES)
    REAL(wp) :: lane_ax(CD_WAVE_LANES), lane_ay(CD_WAVE_LANES), lane_az(CD_WAVE_LANES), lane_p(CD_WAVE_LANES)
    INTEGER :: i0, i1, i, ic, j0, l, m, n_small, lanes
    REAL(wp) :: z_eval, a, e1, e2, den, uh
    LOGICAL :: same_depth

    eta = CD_ZERO
    velocity = CD_ZERO
    acceleration = CD_ZERO
    IF (PRESENT(pdyn)) pdyn = CD_ZERO
    ErrStat = CD_SEA_OK
    ErrMsg = ''
    IF (.NOT. sea%ready) THEN
      CALL fail(ErrStat, ErrMsg, 'sea kinematics called before synthesis')
      RETURN
    END IF
    lanes = MIN(sea%n_comp, CD_WAVE_LANES)
    lane_eta(1:lanes) = CD_ZERO
    DO i0 = 1, sea%n_comp, NB
      i1 = MIN(sea%n_comp, i0 + NB - 1)
      m = i1 - i0 + 1
      DO i = i0, i1
        th(i - i0 + 1) = sea%k(i)*(x*sea%cosb(i) + y*sea%sinb(i)) - sea%omega(i)*t + sea%phase(i)
      END DO
      CALL CD_Wave_SinCos(m, th, sth, cth)
      DO j0 = 0, m - 1, CD_WAVE_LANES
        DO l = 1, MIN(CD_WAVE_LANES, m - j0)
          lane_eta(l) = lane_eta(l) + sea%amplitude(i0 + j0 + l - 1)*cth(j0 + l)
        END DO
      END DO
      IF (i1 <= NKEEP) THEN
        ckeep(i0:i1) = cth(1:m)
        skeep(i0:i1) = sth(1:m)
      END IF
    END DO
    eta = scale*CD_Wave_Sum_Lanes(lane_eta, lanes)
    IF (z > eta) RETURN
    IF (.NOT. (depth + eta > EPSILON(depth)*depth)) THEN
      CALL fail(ErrStat, ErrMsg, 'Wheeler stretching is undefined: the wave trough reaches the seabed '// &
                '(depth + eta <= 0); reduce the wave height or increase the water depth')
      RETURN
    END IF
    z_eval = MIN(CD_ZERO, (z - eta)*depth/(depth + eta))
    same_depth = ABS(depth - sea%depth) <= CD_ZERO
    lane_vx(1:lanes) = CD_ZERO
    lane_vy(1:lanes) = CD_ZERO
    lane_vz(1:lanes) = CD_ZERO
    lane_ax(1:lanes) = CD_ZERO
    lane_ay(1:lanes) = CD_ZERO
    lane_az(1:lanes) = CD_ZERO
    lane_p(1:lanes) = CD_ZERO
    DO i0 = 1, sea%n_comp, NB
      i1 = MIN(sea%n_comp, i0 + NB - 1)
      m = i1 - i0 + 1
      IF (i1 <= NKEEP) THEN
        cth(1:m) = ckeep(i0:i1)
        sth(1:m) = skeep(i0:i1)
      ELSE
        DO i = i0, i1
          th(i - i0 + 1) = sea%k(i)*(x*sea%cosb(i) + y*sea%sinb(i)) - sea%omega(i)*t + sea%phase(i)
        END DO
        CALL CD_Wave_SinCos(m, th, sth, cth)
      END IF
      ! cosh(k(z+h))/sinh(kh) and sinh(k(z+h))/sinh(kh) without overflow, from e1 = EXP(k z)
      ! and e2 = EXP(-2 k h) at the synthesis depth, on one division. A block in which e1^2 or
      ! e2 underflows, or a call at another depth than the synthesis, forms the lower
      ! exponential EXP(-k (z + 2h)) on its own.
      DO i = i0, i1
        th(i - i0 + 1) = sea%k(i)*z_eval
      END DO
      CALL CD_Wave_Exp(m, th, ch)
      n_small = 1
      IF (same_depth) THEN
        n_small = 0
        DO i = i0, i1
          n_small = n_small + MERGE(0, 1, ch(i - i0 + 1)*ch(i - i0 + 1) > TINY(CD_ONE) .AND. sea%e2kd(i) > TINY(CD_ONE))
        END DO
      END IF
      IF (n_small == 0) THEN
        DO i = i0, i1
          e1 = ch(i - i0 + 1)
          e2 = sea%e2kd(i)
          den = CD_ONE/(e1*(CD_ONE - e2))
          ch(i - i0 + 1) = (e1*e1 + e2)*den
          sh(i - i0 + 1) = (e1*e1 - e2)*den
        END DO
      ELSE
        DO i = i0, i1
          th(i - i0 + 1) = -sea%k(i)*(z_eval + 2.0_wp*depth)
        END DO
        CALL CD_Wave_Exp(m, th, e_low)
        DO i = i0, i1
          e1 = ch(i - i0 + 1)
          e2 = e_low(i - i0 + 1)
          den = CD_ONE - sea%e2kd(i)
          ch(i - i0 + 1) = (e1 + e2)/den
          sh(i - i0 + 1) = (e1 - e2)/den
        END DO
      END IF
      DO j0 = 0, m - 1, CD_WAVE_LANES
        DO l = 1, MIN(CD_WAVE_LANES, m - j0)
          i = j0 + l
          ic = i0 + i - 1
          a = sea%amplitude(ic)*sea%omega(ic)
          uh = a*ch(i)*cth(i)
          lane_vx(l) = lane_vx(l) + uh*sea%cosb(ic)
          lane_vy(l) = lane_vy(l) + uh*sea%sinb(ic)
          lane_vz(l) = lane_vz(l) + a*sh(i)*sth(i)
          a = a*sea%omega(ic)
          uh = a*ch(i)*sth(i)
          lane_ax(l) = lane_ax(l) + uh*sea%cosb(ic)
          lane_ay(l) = lane_ay(l) + uh*sea%sinb(ic)
          lane_az(l) = lane_az(l) - a*sh(i)*cth(i)
        END DO
      END DO
      IF (PRESENT(pdyn)) THEN
        DO j0 = 0, m - 1, CD_WAVE_LANES
          DO l = 1, MIN(CD_WAVE_LANES, m - j0)
            i = j0 + l
            ic = i0 + i - 1
            lane_p(l) = lane_p(l) + sea%amplitude(ic)*sea%omega(ic)*sea%omega(ic)/sea%k(ic)*ch(i)*cth(i)
          END DO
        END DO
      END IF
    END DO
    velocity = scale*[CD_Wave_Sum_Lanes(lane_vx, lanes), CD_Wave_Sum_Lanes(lane_vy, lanes), &
                      CD_Wave_Sum_Lanes(lane_vz, lanes)]
    acceleration = scale*[CD_Wave_Sum_Lanes(lane_ax, lanes), CD_Wave_Sum_Lanes(lane_ay, lanes), &
                          CD_Wave_Sum_Lanes(lane_az, lanes)]
    IF (PRESENT(pdyn)) pdyn = scale*CD_Wave_Sum_Lanes(lane_p, lanes)
  END SUBROUTINE CD_Sea_Kinematics

  SUBROUTINE tokenize(line, tok, ntok)
    CHARACTER(*), INTENT(IN) :: line
    CHARACTER(*), INTENT(OUT) :: tok(:)
    INTEGER, INTENT(OUT) :: ntok
    INTEGER :: i, n, start
    LOGICAL :: in_tok
    ntok = 0
    tok = ''
    n = LEN_TRIM(line)
    in_tok = .FALSE.
    start = 1
    DO i = 1, n + 1
      IF (i <= n) THEN
        IF (line(i:i) /= ' ' .AND. line(i:i) /= ACHAR(9) .AND. line(i:i) /= ACHAR(13)) THEN
          IF (.NOT. in_tok) THEN
            in_tok = .TRUE.
            start = i
          END IF
          CYCLE
        END IF
      END IF
      IF (in_tok) THEN
        in_tok = .FALSE.
        ntok = ntok + 1
        IF (ntok > SIZE(tok)) RETURN
        tok(ntok) = line(start:i - 1)
      END IF
    END DO
  END SUBROUTINE tokenize

  PURE FUNCTION lower(s) RESULT(r)
    CHARACTER(*), INTENT(IN) :: s
    CHARACTER(LEN(s)) :: r
    INTEGER :: i, c
    r = s
    DO i = 1, LEN(s)
      c = IACHAR(s(i:i))
      IF (c >= 65 .AND. c <= 90) r(i:i) = ACHAR(c + 32)
    END DO
  END FUNCTION lower

  PURE FUNCTION itoa(i) RESULT(s)
    INTEGER, INTENT(IN) :: i
    CHARACTER(12) :: s
    WRITE (s, '(I0)') i
  END FUNCTION itoa

END MODULE CableDyn_WaveSpectra
