! File: src/CableDyn_Syrope.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Syrope
  !! The production MoorDyn-F/C Syrope polyester constitutive kernel:
  !! an ORIGINAL WORKING CURVE (OWC) strain-tension table split into an
  !! EXPONENTIAL fast spring, eps_fast(T) = (1/beta)*ln(1 + (beta/alpha)*T)
  !! (so dT/deps_fast = alpha + beta*T, the mean-load-dependent dynamic
  !! stiffness), and a slow-spring static strain eps_slow = eps_curve - eps_fast.
  !! A WORKING CURVE is regenerated from the running maximum tension T_max with
  !! a LINEAR / QUADRATIC / EXP shape between eps_min = eps0 + p1*(eps_max -
  !! eps0) (or eps_max - T_max/p1 for the linear p1 >= 1 stiffness form) and
  !! eps_max = eps_owc(T_max).
  !!
  !! The per-segment evolution, with c1 = BA_s and c2 = BA_d:
  !! with T_mean = T_curve(eps_slow) (inverse interpolation on the slow-spring
  !! static curve; the WC below the running-maximum frontier and the OWC at
  !! that frontier) and K1 = alpha + beta*T_mean,
  !!
  !!   d(eps_slow)/dt = (K1*(eps - eps_curve(T_mean)) + c2*deps/dt)/(c1 + c2)
  !!   tension        =  T_mean + c1*d(eps_slow)/dt
  !!
  !! This module is the STATELESS kernel: curve generation, the strain split,
  !! and the rate/tension evaluation. The two per-element states (eps_slow and
  !! the running T_max with its regeneration event) belong to the model layer
  !! that composes it.
  !!
  !! Interpolation is piecewise linear; production-domain checks prevent a
  !! running maximum outside the supplied OWC range.
  USE CableDyn_Precision, ONLY: wp, CD_All_Finite, CD_Is_Finite
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_SyropeType
  PUBLIC :: CD_Syrope_Init
  PUBLIC :: CD_Syrope_End
  PUBLIC :: CD_Syrope_Is_Ready
  PUBLIC :: CD_Syrope_Fast_Strain
  PUBLIC :: CD_Syrope_Working_Curve
  PUBLIC :: CD_Syrope_Find_Strains
  PUBLIC :: CD_Syrope_Rate_And_Tension
  PUBLIC :: CD_Syrope_State_Advance
  PUBLIC :: CD_Syrope_Slow_At_Tmax
  PUBLIC :: CD_Syrope_Element_Load
  PUBLIC :: CD_Syrope_Slow_At_Mean
  PUBLIC :: CD_Syrope_Check_Range
  PUBLIC :: CD_Syrope_Branch_Divider
  PUBLIC :: CD_Syrope_Static_Tension
  PUBLIC :: CD_Syrope_Slow_For_Tension
  INTEGER, PARAMETER, PUBLIC :: CD_SYROPE_OK = 0, CD_SYROPE_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_SYROPE_WC_LINEAR = 1, CD_SYROPE_WC_QUADRATIC = 2, &
                                CD_SYROPE_WC_EXP = 3
  !> Working-curve sample count (MoorDyn-C production convention)
  INTEGER, PARAMETER, PUBLIC :: CD_SYROPE_NWC = 30
  !> Running-maximum samples of the init-time working-curve admissibility scan
  INTEGER, PARAMETER, PUBLIC :: CD_SYROPE_NSCAN = 200

  REAL(wp), PARAMETER :: CD_ZERO = 0.0_wp, CD_ONE = 1.0_wp
  REAL(wp), PARAMETER :: TINY_LEN = 1.0e-12_wp

  TYPE :: CD_SyropeType
    !! One line type's Syrope data: the OWC table with its precomputed
    !! slow-spring static strains, the working-curve shape, and the spring/
    !! dashpot constants. Shared by every element of the type (immutable
    !! after init).
    REAL(wp), ALLOCATABLE :: owc_strain(:)
    REAL(wp), ALLOCATABLE :: owc_tension(:)
    REAL(wp), ALLOCATABLE :: owc_slow(:)
    INTEGER :: wc_mod = 0
    REAL(wp) :: p1 = CD_ZERO, p2 = CD_ZERO
    REAL(wp) :: alpha = CD_ZERO, beta = CD_ZERO
    REAL(wp) :: c1 = CD_ZERO, c2 = CD_ZERO
    ! Working-curve admissibility map filled by CD_Syrope_Init: adm(k) tells whether the
    ! curve regenerates at T_max = scan_lo + (scan_hi - scan_lo)*k/CD_SYROPE_NSCAN.
    LOGICAL :: adm(CD_SYROPE_NSCAN) = .FALSE.
    REAL(wp) :: scan_lo = CD_ZERO, scan_hi = CD_ZERO
    LOGICAL :: initialized = .FALSE.
  END TYPE CD_SyropeType

CONTAINS

  SUBROUTINE CD_Syrope_Init(td, owc_strain, owc_tension, wc_mod, p1, p2, alpha, beta, c1, c2, &
                            ErrStat, ErrMsg)
    !! Validate and freeze one type's Syrope data. Fails closed on the
    !! production well-posedness demands: strictly increasing OWC strain AND
    !! tension columns, a strictly increasing OWC slow-spring static strain
    !! (the inverse interpolation's guard), positive alpha/beta, and nonnegative
    !! BA_s/BA_d with a positive sum.
    TYPE(CD_SyropeType), INTENT(INOUT) :: td
    REAL(wp), INTENT(IN) :: owc_strain(:), owc_tension(:)
    INTEGER, INTENT(IN) :: wc_mod
    REAL(wp), INTENT(IN) :: p1, p2, alpha, beta, c1, c2
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: n, i, istat

    ErrStat = CD_SYROPE_OK
    ErrMsg = ''
    CALL CD_Syrope_End(td)
    n = SIZE(owc_strain)
    IF (n < 2 .OR. SIZE(owc_tension) /= n) THEN
      CALL fail(ErrStat, ErrMsg, 'the OWC table needs matching strain/tension columns with >= 2 rows')
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(owc_strain) .AND. CD_All_Finite(owc_tension))) THEN
      CALL fail(ErrStat, ErrMsg, 'the OWC table must be finite')
      RETURN
    END IF
    DO i = 2, n
      IF (owc_strain(i) <= owc_strain(i - 1) .OR. owc_tension(i) <= owc_tension(i - 1)) THEN
        CALL fail(ErrStat, ErrMsg, 'the OWC strain and tension columns must be strictly increasing')
        RETURN
      END IF
    END DO
    IF (wc_mod /= CD_SYROPE_WC_LINEAR .AND. wc_mod /= CD_SYROPE_WC_QUADRATIC .AND. &
        wc_mod /= CD_SYROPE_WC_EXP) THEN
      CALL fail(ErrStat, ErrMsg, 'the working-curve formula must be LINEAR, QUADRATIC, or EXP')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(p1) .AND. CD_Is_Finite(p2) .AND. &
               CD_Is_Finite(alpha) .AND. alpha > CD_ZERO .AND. &
               CD_Is_Finite(beta) .AND. beta > CD_ZERO .AND. &
               CD_Is_Finite(c1) .AND. c1 >= CD_ZERO .AND. &
               CD_Is_Finite(c2) .AND. c2 >= CD_ZERO .AND. c1 + c2 > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope constants must be finite with alpha > 0, beta > 0, '// &
                'BA_s >= 0, BA_d >= 0, and BA_s + BA_d > 0')
      RETURN
    END IF
    ! The EXP shape T_max*(1 - exp(p2*x))/(1 - exp(p2)) is 0/0 at p2 = 0. Only the
    ! convex p2 > 0 branch is accepted (MoorDyn's documented k2 range); p2 < 0 is
    ! rejected here with the same rule the per-shape check below states.
    IF (wc_mod == CD_SYROPE_WC_EXP .AND. .NOT. (p2 > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'the EXP working curve needs a positive shape parameter p2 (k2 > 0)')
      RETURN
    END IF
    SELECT CASE (wc_mod)
    CASE (CD_SYROPE_WC_LINEAR)
      IF (p1 < CD_ZERO) THEN
        CALL fail(ErrStat, ErrMsg, 'the LINEAR working curve requires k1 >= 0')
        RETURN
      END IF
    CASE (CD_SYROPE_WC_QUADRATIC)
      IF (p1 < CD_ZERO .OR. p1 >= CD_ONE .OR. p2 <= CD_ZERO .OR. p2 > CD_ONE) THEN
        CALL fail(ErrStat, ErrMsg, 'the QUADRATIC working curve requires 0 <= k1 < 1 and 0 < k2 <= 1')
        RETURN
      END IF
    CASE (CD_SYROPE_WC_EXP)
      ! k2 in [1e-6, 700]: EXP(k2) overflows beyond 709, and below 1e-6 the ratio
      ! (1 - EXP(k2 x))/(1 - EXP(k2)) loses every digit to cancellation (0/0 as k2 -> 0)
      IF (p1 < CD_ZERO .OR. p1 >= CD_ONE .OR. p2 < 1.0e-6_wp .OR. p2 > 700.0_wp) THEN
        CALL fail(ErrStat, ErrMsg, 'the EXP working curve requires 0 <= k1 < 1 and 1e-6 <= k2 <= 700')
        RETURN
      END IF
    END SELECT
    ALLOCATE (td%owc_strain(n), td%owc_tension(n), td%owc_slow(n), STAT=istat)
    IF (istat /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'OWC storage allocation failed')
      RETURN
    END IF
    td%owc_strain = owc_strain
    td%owc_tension = owc_tension
    td%wc_mod = wc_mod
    td%p1 = p1
    td%p2 = p2
    td%alpha = alpha
    td%beta = beta
    td%c1 = c1
    td%c2 = c2
    ! A row with owc_tension <= -alpha/beta lies outside the fast-spring log domain;
    ! reject it before the logarithm is evaluated.
    IF (ANY(CD_ONE + beta/alpha*owc_tension <= CD_ZERO)) THEN
      CALL CD_Syrope_End(td)
      CALL fail(ErrStat, ErrMsg, 'the OWC slow-spring static strain is non-finite (a table tension is '// &
                'at or below -alpha/beta, outside the fast-spring log domain)')
      RETURN
    END IF
    DO i = 1, n
      td%owc_slow(i) = owc_strain(i) - CD_Syrope_Fast_Strain(td, owc_tension(i))
    END DO
    ! NaN slips past the monotonicity comparison below (every comparison with NaN is
    ! false), so reject non-finite slow strains rather than marking a corrupted table
    ! initialized.
    IF (.NOT. CD_All_Finite(td%owc_slow)) THEN
      CALL CD_Syrope_End(td)
      CALL fail(ErrStat, ErrMsg, 'the OWC slow-spring static strain is non-finite (a table tension is '// &
                'at or below -alpha/beta, outside the fast-spring log domain)')
      RETURN
    END IF
    DO i = 2, n
      IF (td%owc_slow(i) <= td%owc_slow(i - 1)) THEN
        CALL CD_Syrope_End(td)
        CALL fail(ErrStat, ErrMsg, 'the OWC slow-spring static strain must be strictly increasing '// &
                  '(the alpha/beta fast spring is too soft for this table)')
        RETURN
      END IF
    END DO
    td%initialized = .TRUE.
    ! Working-curve admissibility over the whole OWC tension range: the running maximum
    ! only ratchets up to the last table row, so record which T_max regenerate a
    ! well-posed curve (slope below alpha + beta*T along it). A table with no admissible
    ! running maximum at all cannot run and fails here; otherwise the map lets later
    ! failures name the nearest admissible T_max.
    td%scan_lo = MAX(owc_tension(1), CD_ZERO)
    td%scan_hi = owc_tension(n)
    BLOCK
      INTEGER :: k, es
      CHARACTER(1024) :: em, first_em
      REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
      first_em = ''
      DO k = 1, CD_SYROPE_NSCAN
        CALL CD_Syrope_Working_Curve(td, scan_tmax(td, k), ws, wt, wsl, es, em)
        td%adm(k) = es == CD_SYROPE_OK
        IF (.NOT. td%adm(k) .AND. LEN_TRIM(first_em) == 0) first_em = em
      END DO
      IF (.NOT. ANY(td%adm)) THEN
        CALL CD_Syrope_End(td)
        CALL fail(ErrStat, ErrMsg, 'no running maximum in the OWC table range admits a working curve: '// &
                  TRIM(first_em(LEN('CableDyn_Syrope: ') + 1:)))
        RETURN
      END IF
    END BLOCK
  END SUBROUTINE CD_Syrope_Init

  PURE REAL(wp) FUNCTION scan_tmax(td, k) RESULT(t_max)
    !! The k-th running-maximum sample of the admissibility scan.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    INTEGER, INTENT(IN) :: k
    t_max = td%scan_lo + (td%scan_hi - td%scan_lo)*REAL(k, wp)/REAL(CD_SYROPE_NSCAN, wp)
  END FUNCTION scan_tmax

  PURE REAL(wp) FUNCTION next_admissible_tmax(td, t_max) RESULT(t_ok)
    !! The smallest scanned admissible running maximum at or above t_max, or -1 when
    !! no scanned T_max at or above it is admissible.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: t_max
    INTEGER :: k
    t_ok = -CD_ONE
    DO k = 1, CD_SYROPE_NSCAN
      IF (td%adm(k) .AND. scan_tmax(td, k) >= t_max) THEN
        t_ok = scan_tmax(td, k)
        RETURN
      END IF
    END DO
  END FUNCTION next_admissible_tmax

  SUBROUTINE CD_Syrope_End(td)
    TYPE(CD_SyropeType), INTENT(INOUT) :: td
    IF (ALLOCATED(td%owc_strain)) DEALLOCATE (td%owc_strain)
    IF (ALLOCATED(td%owc_tension)) DEALLOCATE (td%owc_tension)
    IF (ALLOCATED(td%owc_slow)) DEALLOCATE (td%owc_slow)
    td%wc_mod = 0
    td%p1 = CD_ZERO
    td%p2 = CD_ZERO
    td%alpha = CD_ZERO
    td%beta = CD_ZERO
    td%c1 = CD_ZERO
    td%c2 = CD_ZERO
    td%adm = .FALSE.
    td%scan_lo = CD_ZERO
    td%scan_hi = CD_ZERO
    td%initialized = .FALSE.
  END SUBROUTINE CD_Syrope_End

  PURE LOGICAL FUNCTION CD_Syrope_Is_Ready(td) RESULT(ready)
    !! Whether the constitutive data has been validated and populated.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    ready = td%initialized
  END FUNCTION CD_Syrope_Is_Ready

  PURE REAL(wp) FUNCTION CD_Syrope_Fast_Strain(td, tension) RESULT(eps_fast)
    !! The exponential fast spring: eps_fast(T) = (1/beta)*ln(1 + (beta/alpha)*T).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: tension
    eps_fast = LOG(CD_ONE + td%beta/td%alpha*tension)/td%beta
  END FUNCTION CD_Syrope_Fast_Strain

  SUBROUTINE CD_Syrope_Working_Curve(td, t_max, wc_strain, wc_tension, wc_slow, ErrStat, ErrMsg)
    !! Regenerate the working curve at the running maximum tension t_max
    !! CD_SYROPE_NWC samples between eps_min and
    !! eps_max = eps_owc(t_max), with the shape selected by wc_mod, plus the
    !! slow-spring static strains. Fails closed if the slow strains are not
    !! strictly increasing (the inverse interpolation would be ill-posed).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: t_max
    REAL(wp), INTENT(OUT) :: wc_strain(CD_SYROPE_NWC), wc_tension(CD_SYROPE_NWC), &
                             wc_slow(CD_SYROPE_NWC)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: eps_max, eps_min, xi
    INTEGER :: i

    ErrStat = CD_SYROPE_OK
    ErrMsg = ''
    wc_strain = CD_ZERO
    wc_tension = CD_ZERO
    wc_slow = CD_ZERO
    IF (.NOT. td%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope type data is not initialized')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(t_max) .AND. t_max > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'the running maximum tension must be finite and positive')
      RETURN
    END IF
    IF (t_max < td%owc_tension(1) .OR. t_max > td%owc_tension(SIZE(td%owc_tension))) THEN
      CALL fail(ErrStat, ErrMsg, 'the running maximum tension is outside the OWC table range')
      RETURN
    END IF
    eps_max = interp(t_max, td%owc_tension, td%owc_strain)
    eps_min = td%owc_strain(1) + td%p1*(eps_max - td%owc_strain(1))
    IF (td%wc_mod == CD_SYROPE_WC_LINEAR .AND. td%p1 >= CD_ONE) THEN
      ! MoorDyn's linear STIFFNESS form: p1 is the working-curve slope
      eps_min = eps_max - t_max/td%p1
    END IF
    ! a degenerate (zero-width) working curve makes xi = 0/0 -> NaN samples that
    ! the monotonicity check below cannot catch (NaN comparisons are false), so
    ! guard the span here (p1 = 1 on the eps0-anchored forms collapses it)
    IF (.NOT. (eps_min >= CD_ZERO .AND. eps_max - eps_min > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'the working curve is degenerate at this T_max (eps_min >= eps_max); '// &
                'check the shape parameters p1/p2')
      RETURN
    END IF
    DO i = 1, CD_SYROPE_NWC
      wc_strain(i) = eps_min + (eps_max - eps_min)*REAL(i - 1, wp)/REAL(CD_SYROPE_NWC - 1, wp)
      xi = (wc_strain(i) - eps_min)/(eps_max - eps_min)
      SELECT CASE (td%wc_mod)
      CASE (CD_SYROPE_WC_LINEAR)
        wc_tension(i) = t_max*xi
      CASE (CD_SYROPE_WC_QUADRATIC)
        wc_tension(i) = t_max*xi*(td%p2*xi + (CD_ONE - td%p2))
      CASE (CD_SYROPE_WC_EXP)
        wc_tension(i) = t_max*(CD_ONE - EXP(td%p2*xi))/(CD_ONE - EXP(td%p2))
      END SELECT
      wc_slow(i) = wc_strain(i) - CD_Syrope_Fast_Strain(td, wc_tension(i))
    END DO
    IF (.NOT. (CD_All_Finite(wc_tension) .AND. CD_All_Finite(wc_slow))) THEN
      CALL fail(ErrStat, ErrMsg, 'the working curve has non-finite samples at this T_max (degenerate '// &
                'shape parameters)')
      RETURN
    END IF
    DO i = 2, CD_SYROPE_NWC
      ! the on-working-curve path interpolates static strain as interp(t_mean,
      ! wc_tension, wc_strain), whose contract needs a strictly increasing abscissa.
      ! A QUADRATIC/EXP shape parameter just outside the monotone range dips
      ! wc_tension while wc_slow can still rise, so check the tension column too.
      IF (wc_tension(i) <= wc_tension(i - 1)) THEN
        CALL fail(ErrStat, ErrMsg, 'the working-curve tension is not strictly increasing at this '// &
                  'T_max (the quadratic/exp shape parameter p2 is outside the monotone range)')
        RETURN
      END IF
      IF (wc_slow(i) <= wc_slow(i - 1)) THEN
        ! the slow strain wc_strain - eps_fast(wc_tension) decreases exactly where the
        ! working-curve slope dT/deps reaches the fast-spring stiffness alpha + beta*T
        BLOCK
          REAL(wp) :: t_ok
          CHARACTER(24) :: s_tmax, s_t
          CHARACTER(48) :: s_ok
          WRITE (s_tmax, '(ES10.3)') t_max
          WRITE (s_t, '(ES10.3)') wc_tension(i)
          t_ok = next_admissible_tmax(td, t_max)
          IF (t_ok > CD_ZERO) THEN
            WRITE (s_ok, '(ES10.3)') t_ok
            s_ok = '; next admissible T_max '//TRIM(ADJUSTL(s_ok))//' N'
          ELSE
            s_ok = ''
          END IF
          CALL fail(ErrStat, ErrMsg, 'working curve inadmissible at T_max '//TRIM(ADJUSTL(s_tmax))// &
                    ' N: slope reaches alpha + beta*T at T = '//TRIM(ADJUSTL(s_t))//' N'//TRIM(s_ok))
        END BLOCK
        RETURN
      END IF
    END DO
  END SUBROUTINE CD_Syrope_Working_Curve

  SUBROUTINE CD_Syrope_Find_Strains(td, on_wc, wc_strain, wc_tension, t_mean, &
                                    strain_static, fast_strain, slow_strain)
    !! The static strain split at a mean tension:
    !! total curve strain, the fast-spring share, and the slow-spring share.
    !! on_wc selects the working curve (t_mean below the running max) vs the
    !! OWC frontier. This is MoorDyn's exact-log partition; the kernel recovers
    !! T_mean by interpolating the node-sampled slow table, so seeding a state
    !! from slow_strain misses the rest point by the fast spring's interpolation
    !! error. CD_Syrope_Slow_At_Mean returns the exact rest-point slow strain.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    LOGICAL, INTENT(IN) :: on_wc
    REAL(wp), INTENT(IN) :: wc_strain(CD_SYROPE_NWC), wc_tension(CD_SYROPE_NWC), t_mean
    REAL(wp), INTENT(OUT) :: strain_static, fast_strain, slow_strain
    IF (on_wc) THEN
      strain_static = interp(t_mean, wc_tension, wc_strain)
    ELSE
      strain_static = interp(t_mean, td%owc_tension, td%owc_strain)
    END IF
    fast_strain = CD_Syrope_Fast_Strain(td, t_mean)
    slow_strain = strain_static - fast_strain
  END SUBROUTINE CD_Syrope_Find_Strains

  PURE REAL(wp) FUNCTION CD_Syrope_Slow_At_Mean(td, on_wc, wc_tension, wc_slow, t_mean) RESULT(slow)
    !! The slow-spring strain whose kernel recovery returns exactly t_mean: the
    !! inverse of the piecewise-linear T_mean(eps_slow) interpolation on the
    !! selected branch table. With it, eps = eps_curve(t_mean) and zero strain
    !! rate is an exact rest point (tension t_mean, zero slow-strain rate).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    LOGICAL, INTENT(IN) :: on_wc
    REAL(wp), INTENT(IN) :: wc_tension(CD_SYROPE_NWC), wc_slow(CD_SYROPE_NWC), t_mean
    IF (on_wc) THEN
      slow = interp(t_mean, wc_tension, wc_slow)
    ELSE
      slow = interp(t_mean, td%owc_tension, td%owc_slow)
    END IF
  END FUNCTION CD_Syrope_Slow_At_Mean

  SUBROUTINE CD_Syrope_Check_Range(td, slow_eps, ErrStat, ErrMsg, eps)
    !! Fail closed when a state lies beyond the OWC table: a slow-spring strain
    !! above the last row's slow strain (the mean tension would silently clamp at
    !! the last row while the slow strain keeps creeping) or, when eps is given
    !! (the OWC-branch total strain), a strain above the last table strain.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: slow_eps
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: eps
    INTEGER :: n
    CHARACTER(24) :: s_val, s_lim, s_ten
    ErrStat = CD_SYROPE_OK
    ErrMsg = ''
    IF (.NOT. td%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope type data is not initialized')
      RETURN
    END IF
    n = SIZE(td%owc_strain)
    ! Format only on failure: this check runs per element per step, and formatted
    ! I/O is costly and toggles the process locale in some Fortran runtimes.
    IF (slow_eps > td%owc_slow(n)) THEN
      WRITE (s_ten, '(ES10.3)') td%owc_tension(n)
      WRITE (s_val, '(ES10.3)') slow_eps
      WRITE (s_lim, '(ES10.3)') td%owc_slow(n)
      CALL fail(ErrStat, ErrMsg, 'slow strain '//TRIM(ADJUSTL(s_val))//' left the OWC table (last row '// &
                TRIM(ADJUSTL(s_lim))//', T '//TRIM(ADJUSTL(s_ten))//' N); extend the table')
      RETURN
    END IF
    IF (PRESENT(eps)) THEN
      IF (eps > td%owc_strain(n)) THEN
        WRITE (s_ten, '(ES10.3)') td%owc_tension(n)
        WRITE (s_val, '(ES10.3)') eps
        WRITE (s_lim, '(ES10.3)') td%owc_strain(n)
        CALL fail(ErrStat, ErrMsg, 'strain '//TRIM(ADJUSTL(s_val))//' left the OWC table (last row '// &
                  TRIM(ADJUSTL(s_lim))//', T '//TRIM(ADJUSTL(s_ten))//' N); extend the table')
      END IF
    END IF
  END SUBROUTINE CD_Syrope_Check_Range

  SUBROUTINE CD_Syrope_Rate_And_Tension(td, on_wc, wc_strain, wc_tension, wc_slow, &
                                        slow_eps, eps, deps, dslow_eps, tension, t_mean, &
                                        ErrStat, ErrMsg)
    !! Recover
    !! the mean tension from the slow-spring state by inverse interpolation on
    !! the caller-selected history branch (on_wc), form the
    !! load-dependent fast stiffness K1 = alpha + beta*t_mean, and return the
    !! state rate, the instantaneous tension, and the recovered mean tension
    !! (the caller owns the running-max event: t_mean > its T_max regenerates
    !! the working curve).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    LOGICAL, INTENT(IN) :: on_wc
    REAL(wp), INTENT(IN) :: wc_strain(CD_SYROPE_NWC), wc_tension(CD_SYROPE_NWC), &
                            wc_slow(CD_SYROPE_NWC)
    REAL(wp), INTENT(IN) :: slow_eps, eps, deps
    REAL(wp), INTENT(OUT) :: dslow_eps, tension, t_mean
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: k1, eps_static

    ErrStat = CD_SYROPE_OK
    ErrMsg = ''
    dslow_eps = CD_ZERO
    tension = CD_ZERO
    t_mean = CD_ZERO
    IF (.NOT. td%initialized) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope type data is not initialized')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(slow_eps) .AND. slow_eps >= CD_ZERO .AND. &
               CD_Is_Finite(eps) .AND. CD_Is_Finite(deps))) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope rate evaluation needs finite strain inputs and slow_eps >= 0')
      RETURN
    END IF
    IF (on_wc) THEN
      t_mean = interp(slow_eps, wc_slow, wc_tension)
      eps_static = interp(t_mean, wc_tension, wc_strain)
    ELSE
      t_mean = interp(slow_eps, td%owc_slow, td%owc_tension)
      eps_static = interp(t_mean, td%owc_tension, td%owc_strain)
    END IF
    k1 = td%alpha + td%beta*t_mean
    ! Production MoorDyn convention: c1 = BA_s and c2 = BA_d. BA_d drives
    ! the internal-state rate; BA_s times that rate is the damping force.
    dslow_eps = (k1*(eps - eps_static) + td%c2*deps)/(td%c1 + td%c2)
    tension = t_mean + td%c1*dslow_eps
  END SUBROUTINE CD_Syrope_Rate_And_Tension

  SUBROUTINE CD_Syrope_State_Advance(td, on_wc, wc_strain, wc_tension, wc_slow, slow_old, &
                                     eps, deps, dt, slow_next, t_mean, ErrStat, ErrMsg, divider)
    !! Backward-Euler advance of MoorDyn's continuous slow-spring strain state.
    !! With divider (CD_Syrope_Branch_Divider of the committed running maximum)
    !! every rate evaluation takes the branch of its own slow strain (working
    !! curve below the divider, OWC at or above it), so the solve crosses the
    !! unloading/reloading switch within the step; without it the caller's on_wc
    !! holds for the whole solve.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    LOGICAL, INTENT(IN) :: on_wc
    REAL(wp), INTENT(IN) :: wc_strain(CD_SYROPE_NWC), wc_tension(CD_SYROPE_NWC), &
                            wc_slow(CD_SYROPE_NWC)
    REAL(wp), INTENT(IN) :: slow_old, eps, deps, dt
    REAL(wp), INTENT(OUT) :: slow_next, t_mean
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: divider
    INTEGER :: iter, expand
    REAL(wp) :: x, rate, tension, residual, derivative, h, rp, rm, tp, tm, mean_p, mean_m
    REAL(wp) :: lo, hi, rlo, rhi, xlo, xhi, trial, tol
    REAL(wp), PARAMETER :: RTOL = 5.0e-13_wp

    ErrStat = CD_SYROPE_OK
    ErrMsg = ''
    slow_next = slow_old
    t_mean = CD_ZERO
    IF (.NOT. (CD_Is_Finite(slow_old) .AND. slow_old >= CD_ZERO .AND. CD_Is_Finite(eps) .AND. &
               CD_Is_Finite(deps) .AND. CD_Is_Finite(dt) .AND. dt > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope state advance needs finite inputs, slow_old >= 0, and dt > 0')
      RETURN
    END IF

    ! Projected backward Euler on slow_next >= 0. R(0) >= 0 means the
    ! unconstrained root lies at or below the physical boundary, so zero is the
    ! complementarity solution rather than a failed Newton iteration.
    lo = CD_ZERO
    CALL eval_rate(lo, rate, tension, t_mean)
    IF (ErrStat /= CD_SYROPE_OK) RETURN
    rlo = -slow_old - dt*rate
    tol = RTOL*MAX(CD_ONE, ABS(slow_old), ABS(dt*rate))
    IF (rlo >= -tol) THEN
      slow_next = CD_ZERO
      RETURN
    END IF

    ! R(0) < 0: bracket the positive root. The interpolation clamps beyond its
    ! upper table end, so R(x) ultimately grows like x and a finite bracket must
    ! exist for valid finite inputs.
    hi = MAX(slow_old, -rlo, SQRT(EPSILON(CD_ONE)))
    DO expand = 1, 60
      CALL eval_rate(hi, rate, tension, t_mean)
      IF (ErrStat /= CD_SYROPE_OK) RETURN
      rhi = hi - slow_old - dt*rate
      IF (rhi >= CD_ZERO) EXIT
      hi = 2.0_wp*hi
      IF (.NOT. CD_Is_Finite(hi)) EXIT
    END DO
    IF (.NOT. CD_Is_Finite(hi) .OR. rhi < CD_ZERO) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope backward-Euler state solve could not bracket a finite root')
      RETURN
    END IF

    x = MIN(MAX(slow_old, lo), hi)
    IF (x <= lo .OR. x >= hi) x = 0.5_wp*(lo + hi)
    DO iter = 1, 80
      CALL eval_rate(x, rate, tension, t_mean)
      IF (ErrStat /= CD_SYROPE_OK) RETURN
      residual = x - slow_old - dt*rate
      tol = RTOL*MAX(CD_ONE, ABS(x), ABS(slow_old), ABS(dt*rate))
      IF (ABS(residual) <= tol) THEN
        slow_next = x
        RETURN
      END IF
      IF (residual < CD_ZERO) THEN
        lo = x
        rlo = residual
      ELSE
        hi = x
        rhi = residual
      END IF

      ! Safeguarded numerical Newton step. Near a kink or a flat derivative,
      ! bisection preserves the bracket and guarantees progress.
      h = SQRT(EPSILON(CD_ONE))*MAX(CD_ONE, ABS(x))
      xlo = MAX(lo, x - h)
      xhi = MIN(hi, x + h)
      CALL eval_rate(xhi, rp, tp, mean_p)
      IF (ErrStat /= CD_SYROPE_OK) RETURN
      CALL eval_rate(xlo, rm, tm, mean_m)
      IF (ErrStat /= CD_SYROPE_OK) RETURN
      derivative = CD_ZERO
      IF (xhi > xlo) derivative = CD_ONE - dt*(rp - rm)/(xhi - xlo)
      trial = 0.5_wp*(lo + hi)
      IF (CD_Is_Finite(derivative) .AND. ABS(derivative) > SQRT(EPSILON(CD_ONE))) THEN
        xhi = x - residual/derivative
        IF (CD_Is_Finite(xhi) .AND. xhi > lo .AND. xhi < hi) trial = xhi
      END IF
      x = trial
    END DO
    ! The safeguarded Newton step can creep along one side of the bracket when the root lies
    ! closer to a kink of the rate than its difference interval h, where the slope of
    ! T_mean(eps_slow) changes (the top sample of the working curve, beyond which its
    ! interpolation clamps at T_max, as when a rope rests on its OWC at its running maximum):
    ! the difference quotient straddles the kink, and every step lands inside the bracket and
    ! moves only that end. Finish then by bisection, which halves the bracket every iteration
    ! (R is continuous on it, so the bracket closes on its root) until the residual test is met.
    ! A steep R (a light BA_s + BA_d, R' = 1 - dt d(rate)/d(eps_slow) of order 1e6) can change
    ! sign between two adjacent reals with |R| above the test on both: the root is then located
    ! to machine precision, and the end with the smaller |R| is taken (R(lo) < 0 <= R(hi)).
    ! A solve that converged above never gets here, so its result is unchanged. The switch comes
    ! only after the 80 Newton iterations: many solves that converge creep for a while first,
    ! and switching on creeping iterations (two to eight in a row) changed 6e3 to 4e4 of 4.4e5
    ! fuzzed solves that converge without it.
    DO iter = 1, 200
      x = 0.5_wp*(lo + hi)
      IF (.NOT. (x > lo .AND. x < hi)) THEN
        x = hi
        IF (ABS(rlo) < ABS(rhi)) x = lo
        CALL eval_rate(x, rate, tension, t_mean)
        IF (ErrStat /= CD_SYROPE_OK) RETURN
        slow_next = x
        RETURN
      END IF
      CALL eval_rate(x, rate, tension, t_mean)
      IF (ErrStat /= CD_SYROPE_OK) RETURN
      residual = x - slow_old - dt*rate
      tol = RTOL*MAX(CD_ONE, ABS(x), ABS(slow_old), ABS(dt*rate))
      IF (ABS(residual) <= tol) THEN
        slow_next = x
        RETURN
      END IF
      IF (residual < CD_ZERO) THEN
        lo = x
        rlo = residual
      ELSE
        hi = x
        rhi = residual
      END IF
    END DO
    CALL fail(ErrStat, ErrMsg, 'Syrope backward-Euler state solve did not converge')

  CONTAINS

    SUBROUTINE eval_rate(slow_eval, rate_out, tension_out, mean_out)
      !! The rate at a trial slow strain on its branch (see the divider above).
      REAL(wp), INTENT(IN) :: slow_eval
      REAL(wp), INTENT(OUT) :: rate_out, tension_out, mean_out
      LOGICAL :: branch
      branch = on_wc
      IF (PRESENT(divider)) branch = slow_eval < divider
      CALL CD_Syrope_Rate_And_Tension(td, branch, wc_strain, wc_tension, wc_slow, slow_eval, eps, deps, &
                                      rate_out, tension_out, mean_out, ErrStat, ErrMsg)
    END SUBROUTINE eval_rate
  END SUBROUTINE CD_Syrope_State_Advance

  PURE REAL(wp) FUNCTION CD_Syrope_Branch_Divider(td, t_max) RESULT(divider)
    !! The slow strain dividing the working-curve and OWC branches at the running
    !! maximum t_max: the OWC recovery's exact inverse at t_max, so the recovered
    !! mean tension is continuous across the switch (the working curve clamps at
    !! t_max up to the divider, the OWC returns t_max at it). It lies at or above
    !! CD_Syrope_Slow_At_Tmax (the exact-log value; equal at table rows).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: t_max
    divider = interp(t_max, td%owc_tension, td%owc_slow)
  END FUNCTION CD_Syrope_Branch_Divider

  SUBROUTINE CD_Syrope_Static_Tension(td, t_max, eps, tension, ErrStat, ErrMsg)
    !! The rest (static) tension at strain eps of a rope whose running maximum is t_max: the
    !! working curve of t_max up to its top strain eps_owc(t_max) (zero below its zero-tension
    !! strain), the OWC beyond it (where loading would raise the running maximum). This is
    !! the static curve the dynamic state relaxes to, so a static initial condition solved on
    !! it is the equilibrium of the same constitutive state the dynamics start from.
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: t_max, eps
    REAL(wp), INTENT(OUT) :: tension
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)

    tension = CD_ZERO
    CALL CD_Syrope_Working_Curve(td, t_max, ws, wt, wsl, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYROPE_OK) RETURN
    IF (eps >= ws(CD_SYROPE_NWC)) THEN
      tension = interp(eps, td%owc_strain, td%owc_tension)
    ELSE IF (eps > ws(1)) THEN
      tension = interp(eps, ws, wt)
    END IF
  END SUBROUTINE CD_Syrope_Static_Tension

  SUBROUTINE CD_Syrope_Slow_For_Tension(td, t_max, eps, tension, slow, ErrStat, ErrMsg)
    !! The slow-spring strain at which a segment held at strain eps (zero strain rate) with
    !! running maximum t_max carries exactly the kernel tension T_mean + c1*d(eps_slow)/dt =
    !! tension. It seeds a dynamic state whose t = 0 force equals a given static tension:
    !! when the static strain lies on the rest curve (CD_Syrope_Static_Tension) the root is
    !! the rest point itself (zero slow-strain rate); otherwise the slow strain creeps from it
    !! at the rate (tension - T_mean)/c1. The kernel tension decreases with the slow strain
    !! (a softer working curve than the fast spring), so the root is bracketed between zero
    !! and the last OWC slow strain and found by bisection. Fails closed when the tension is
    !! not bracketed (a strain the table cannot hold at this tension).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: t_max, eps, tension
    REAL(wp), INTENT(OUT) :: slow
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp) :: ws(CD_SYROPE_NWC), wt(CD_SYROPE_NWC), wsl(CD_SYROPE_NWC)
    REAL(wp) :: divider, lo, hi, mid, g_lo, g_hi, g_mid
    INTEGER :: iter

    slow = CD_ZERO
    CALL CD_Syrope_Working_Curve(td, t_max, ws, wt, wsl, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYROPE_OK) RETURN
    divider = CD_Syrope_Branch_Divider(td, t_max)
    lo = CD_ZERO
    hi = td%owc_slow(SIZE(td%owc_slow))
    g_lo = excess(lo)
    IF (ErrStat /= CD_SYROPE_OK) RETURN
    g_hi = excess(hi)
    IF (ErrStat /= CD_SYROPE_OK) RETURN
    IF (.NOT. (g_lo >= CD_ZERO .AND. g_hi <= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'no slow-spring state carries the static tension at this strain '// &
                '(the OWC table cannot hold it)')
      RETURN
    END IF
    DO iter = 1, 200
      mid = 0.5_wp*(lo + hi)
      g_mid = excess(mid)
      IF (ErrStat /= CD_SYROPE_OK) RETURN
      IF (g_mid >= CD_ZERO) THEN
        lo = mid
      ELSE
        hi = mid
      END IF
      IF (hi - lo <= 4.0_wp*EPSILON(CD_ONE)*MAX(hi, TINY_LEN)) EXIT
    END DO
    slow = 0.5_wp*(lo + hi)

  CONTAINS

    REAL(wp) FUNCTION excess(s) RESULT(g)
      !! Kernel tension at slow strain s (branch of s against the divider) minus the target.
      REAL(wp), INTENT(IN) :: s
      REAL(wp) :: rate, ten, mean
      CALL CD_Syrope_Rate_And_Tension(td, s < divider, ws, wt, wsl, s, eps, CD_ZERO, rate, ten, mean, &
                                      ErrStat, ErrMsg)
      g = ten - tension
    END FUNCTION excess
  END SUBROUTINE CD_Syrope_Slow_For_Tension

  PURE REAL(wp) FUNCTION CD_Syrope_Slow_At_Tmax(td, t_max) RESULT(slow_at)
    !! The exact-log slow-spring static strain at the running maximum tension:
    !! eps_owc(t_max) minus the fast-spring strain at t_max (the regenerated working
    !! curve and the OWC coincide at t_max). It is not the branch divider the model
    !! uses, which is CD_Syrope_Branch_Divider (the interpolated inverse, at or above
    !! this value).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    REAL(wp), INTENT(IN) :: t_max
    slow_at = interp(t_max, td%owc_tension, td%owc_strain) - CD_Syrope_Fast_Strain(td, t_max)
  END FUNCTION CD_Syrope_Slow_At_Tmax

  SUBROUTINE CD_Syrope_Element_Load(qa, qb, va, vb, l0, td, wc_strain, wc_tension, wc_slow, &
                                    on_wc, slow_eps, tension_only, force, jac_q, t_mean, dslow_eps, &
                                    ErrStat, ErrMsg, jac_v, dt, slow_next, divider)
    !! The Syrope element load at the CURRENT kinematics. Production MoorDyn
    !! applies T_mean + BA_s*d(eps_slow)/dt; a compressed segment (eps < 0) keeps
    !! only the damping part BA_s*d(eps_slow)/dt (MoorDyn-C drops the elastic
    !! mean tension there). tension_only then clamps a compressive force to zero.
    !!
    !! With dt > 0 (an in-step evaluation) the slow strain is eliminated
    !! implicitly: slow_next solves the same backward-Euler equation the step
    !! commit solves (CD_Syrope_State_Advance from the committed slow_eps at these
    !! kinematics), and the force is evaluated at slow_next, so the force the
    !! nodes feel equals the tension reported at the committed state. The
    !! tangents carry d(slow_next)/d(eps, deps) by the implicit-function theorem.
    !! Without dt (or dt = 0) slow_next = slow_eps (the committed-state limit).
    !! The working curve is that of the committed running maximum. With divider
    !! (CD_Syrope_Branch_Divider of that maximum) the branch follows the evaluated
    !! slow strain, so the in-step force and the committed-state report agree
    !! across an unloading/reloading switch; without it on_wc is used as given.
    !! t_mean and dslow_eps are those at slow_next.
    REAL(wp), INTENT(IN) :: qa(3), qb(3), va(3), vb(3), l0
    TYPE(CD_SyropeType), INTENT(IN) :: td
    LOGICAL, INTENT(IN) :: on_wc
    REAL(wp), INTENT(IN) :: wc_strain(CD_SYROPE_NWC), wc_tension(CD_SYROPE_NWC), wc_slow(CD_SYROPE_NWC)
    REAL(wp), INTENT(IN) :: slow_eps
    LOGICAL, INTENT(IN) :: tension_only
    REAL(wp), INTENT(OUT) :: force(6), jac_q(6, 6), t_mean, dslow_eps
    REAL(wp), INTENT(OUT), OPTIONAL :: jac_v(6, 6)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: dt
    REAL(wp), INTENT(OUT), OPTIONAL :: slow_next
    REAL(wp), INTENT(IN), OPTIONAL :: divider

    REAL(wp) :: chord(3), tang(3), rel(3), length, eps, deps, tension, k1, ceff, coefT, dcoef_dlen
    REAL(wp) :: slow_use, t_adv, r_s, dtm_ds, r_e, r_v, ds_e, ds_v, w_el, dt_step
    REAL(wp) :: eye(3, 3), tt(3, 3), pmat(3, 3), dq(3, 3), dv(3, 3), damp_q(3, 3)
    INTEGER :: i
    LOGICAL :: implicit, branch

    force = CD_ZERO
    jac_q = CD_ZERO
    IF (PRESENT(jac_v)) jac_v = CD_ZERO
    t_mean = CD_ZERO
    dslow_eps = CD_ZERO
    IF (PRESENT(slow_next)) slow_next = slow_eps
    dt_step = CD_ZERO
    IF (PRESENT(dt)) dt_step = dt
    implicit = dt_step > CD_ZERO
    ErrStat = CD_SYROPE_OK
    ErrMsg = ''
    IF (.NOT. (CD_All_Finite(qa) .AND. CD_All_Finite(qb) .AND. &
               CD_All_Finite(va) .AND. CD_All_Finite(vb) .AND. &
               CD_Is_Finite(l0) .AND. l0 > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope element inputs must be finite (l0 positive)')
      RETURN
    END IF
    chord = qb - qa
    length = NORM2(chord)
    IF (length <= TINY_LEN) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope element collapsed to zero length')
      RETURN
    END IF
    tang = chord/length
    rel = vb - va
    eps = (length - l0)/l0
    deps = DOT_PRODUCT(tang, rel)/l0
    IF (.NOT. (CD_Is_Finite(dt_step) .AND. dt_step >= CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'Syrope element step size must be finite and non-negative')
      RETURN
    END IF
    slow_use = slow_eps
    IF (implicit) THEN
      ! the identical call (same inputs) the step commit makes, so the committed
      ! slow strain is bit-identical to the one this force is evaluated at
      CALL CD_Syrope_State_Advance(td, on_wc, wc_strain, wc_tension, wc_slow, slow_eps, eps, deps, &
                                   dt_step, slow_use, t_adv, ErrStat, ErrMsg, divider=divider)
      IF (ErrStat /= CD_SYROPE_OK) RETURN
      IF (PRESENT(slow_next)) slow_next = slow_use
    END IF
    branch = on_wc
    IF (PRESENT(divider)) branch = slow_use < divider
    CALL CD_Syrope_Rate_And_Tension(td, branch, wc_strain, wc_tension, wc_slow, slow_use, eps, deps, &
                                    dslow_eps, tension, t_mean, ErrStat, ErrMsg)
    IF (ErrStat /= CD_SYROPE_OK) RETURN
    k1 = td%alpha + td%beta*t_mean
    ! partials of the rate r(slow, eps, deps) and of T_mean(slow)
    CALL rate_slow_partial(td, branch, wc_strain, wc_tension, wc_slow, slow_use, eps, t_mean, r_s, dtm_ds)
    r_e = k1/(td%c1 + td%c2)
    r_v = td%c2/(td%c1 + td%c2)
    ! implicit-function sensitivities of the eliminated slow strain: R = s - s_n - dt*r = 0
    ! gives ds/dx = dt*r_x/(1 - dt*r_s); the projected boundary (s = 0) is locally fixed
    ds_e = CD_ZERO
    ds_v = CD_ZERO
    IF (implicit .AND. slow_use > CD_ZERO) THEN
      ds_e = dt_step*r_e/(CD_ONE - dt_step*r_s)
      ds_v = dt_step*r_v/(CD_ONE - dt_step*r_s)
    END IF
    ! a compressed segment carries no elastic mean tension, only BA_s*d(eps_slow)/dt
    w_el = CD_ONE
    IF (eps < CD_ZERO) w_el = CD_ZERO
    coefT = w_el*t_mean + td%c1*dslow_eps
    ! d(coefT)/d(eps) and d(coefT)/d(deps) through both the explicit and the slow paths
    dcoef_dlen = (w_el*dtm_ds*ds_e + td%c1*(r_e + r_s*ds_e))/l0
    ceff = w_el*dtm_ds*ds_v + td%c1*(r_v + r_s*ds_v)
    IF (tension_only .AND. coefT < CD_ZERO) THEN
      ! compressive: the cable cannot push (force and its tangent vanish, but
      ! dslow_eps still evolves the state toward relaxation)
      coefT = CD_ZERO
      dcoef_dlen = CD_ZERO
      ceff = CD_ZERO
    END IF
    force(1:3) = coefT*tang
    force(4:6) = -coefT*tang

    eye = CD_ZERO
    DO i = 1, 3
      eye(i, i) = CD_ONE
    END DO
    tt = outer(tang, tang)
    pmat = (eye - tt)/length
    ! d(force_a)/d(qb) = tang*(dcoef/dlength)*tang^T + coefT*d(tang)/d(qb),
    ! with d(length)/d(qb) = tang and d(tang)/d(qb) = pmat.
    ! coefT*pmat already rotates the complete tension, including ceff*deps.
    ! Only the change of deps = tang.rel/l0 remains here:
    ! d(deps)/d(qb) = pmat*rel/l0. Adding (tang.rel)*pmat again would
    ! double-count damping curvature.
    damp_q = ceff/l0*MATMUL(outer(tang, rel), pmat)
    dq = dcoef_dlen*tt + coefT*pmat + damp_q
    dv = ceff/l0*tt
    ! residual-Jacobian convention: chord = qb - qa, so the a-columns carry the
    ! opposite sign and F_b = -F_a mirrors the rows.
    jac_q(1:3, 1:3) = dq
    jac_q(1:3, 4:6) = -dq
    jac_q(4:6, 1:3) = -dq
    jac_q(4:6, 4:6) = dq
    IF (PRESENT(jac_v)) THEN
      jac_v(1:3, 1:3) = dv
      jac_v(1:3, 4:6) = -dv
      jac_v(4:6, 1:3) = -dv
      jac_v(4:6, 4:6) = dv
    END IF
  END SUBROUTINE CD_Syrope_Element_Load

  PURE FUNCTION outer(a, b) RESULT(m)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: m(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        m(i, j) = a(i)*b(j)
      END DO
    END DO
  END FUNCTION outer

  PURE SUBROUTINE rate_slow_partial(td, on_wc, wc_strain, wc_tension, wc_slow, slow_eps, eps, t_mean, &
                                    r_s, dtm_ds)
    !! Partial derivatives, at fixed (eps, deps), of the slow-strain rate
    !! r = (K1*(eps - eps_static(T_mean)) + c2*deps)/(c1 + c2) and of T_mean with
    !! respect to the slow strain, on the same piecewise-linear segments the
    !! kernel interpolates (zero slope where the interpolation clamps).
    TYPE(CD_SyropeType), INTENT(IN) :: td
    LOGICAL, INTENT(IN) :: on_wc
    REAL(wp), INTENT(IN) :: wc_strain(CD_SYROPE_NWC), wc_tension(CD_SYROPE_NWC), wc_slow(CD_SYROPE_NWC)
    REAL(wp), INTENT(IN) :: slow_eps, eps, t_mean
    REAL(wp), INTENT(OUT) :: r_s, dtm_ds
    REAL(wp) :: de_dtm, eps_static
    IF (on_wc) THEN
      dtm_ds = interp_slope(slow_eps, wc_slow, wc_tension)
      de_dtm = interp_slope(t_mean, wc_tension, wc_strain)
      eps_static = interp(t_mean, wc_tension, wc_strain)
    ELSE
      dtm_ds = interp_slope(slow_eps, td%owc_slow, td%owc_tension)
      de_dtm = interp_slope(t_mean, td%owc_tension, td%owc_strain)
      eps_static = interp(t_mean, td%owc_tension, td%owc_strain)
    END IF
    r_s = (td%beta*dtm_ds*(eps - eps_static) - (td%alpha + td%beta*t_mean)*de_dtm*dtm_ds)/(td%c1 + td%c2)
  END SUBROUTINE rate_slow_partial

  PURE REAL(wp) FUNCTION interp_slope(x, xp, fp) RESULT(dydx)
    !! The slope of the segment interp uses at x (zero on the clamped ends).
    REAL(wp), INTENT(IN) :: x, xp(:), fp(:)
    INTEGER :: i, n
    n = SIZE(xp)
    dydx = CD_ZERO
    IF (x <= xp(1) .OR. x >= xp(n)) RETURN
    DO i = 2, n
      IF (x <= xp(i)) THEN
        dydx = (fp(i) - fp(i - 1))/(xp(i) - xp(i - 1))
        RETURN
      END IF
    END DO
  END FUNCTION interp_slope

  PURE REAL(wp) FUNCTION interp(x, xp, fp) RESULT(y)
    !! Piecewise-linear interpolation with CONSTANT extrapolation at both
    !! ends. xp must
    !! be increasing (init validates every table this kernel consumes).
    REAL(wp), INTENT(IN) :: x, xp(:), fp(:)
    INTEGER :: i, n
    n = SIZE(xp)
    IF (x <= xp(1)) THEN
      y = fp(1)
      RETURN
    END IF
    IF (x >= xp(n)) THEN
      y = fp(n)
      RETURN
    END IF
    DO i = 2, n
      IF (x <= xp(i)) THEN
        y = fp(i - 1) + (fp(i) - fp(i - 1))*(x - xp(i - 1))/(xp(i) - xp(i - 1))
        RETURN
      END IF
    END DO
    y = fp(n)
  END FUNCTION interp

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN) :: msg
    ErrStat = CD_SYROPE_BADINPUT
    ErrMsg = 'CableDyn_Syrope: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Syrope
