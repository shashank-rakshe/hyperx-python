! File: tests/test_hermite_viv.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_viv
  !! Cross-flow VIV on the cubic-Hermite cable (CD_HermiteCable_Dyn_Set_VIV): the setter's
  !! refusals, the state the step carries, and the lock-in itself.
  !!
  !! A 100 m taut, nearly neutrally buoyant line (20 elements, D 0.1 m, EA 5e7 N, EI 1 N m^2,
  !! about 50 kN), pinned at both ends in a 0.15 m/s cross current with Cl 0.8 and MoorDyn's band
  !! (dF 0.08, cF 0.18): the shedding frequency cF U/D = 0.27 Hz sits on the first mode, so the
  !! line locks in (the deck benchmark of tests/test_viv_lockin.py, coarser here).
  !!
  !! Gates:
  !! * the setter refuses a model without drag, mismatched sizes, a band with dF >= cF, a negative
  !!   averaging time, and an internal wave family afterwards; all-zero Cl installs nothing;
  !!   installing the lift in the cross current changes the committed acceleration and removing
  !!   it brings the no-lift acceleration back; a drag reconfigured afterwards carries the lift
  !!   scale and the shedding diameter with it;
  !! * at 60 s the mid-span cross-flow amplitude is above 0.3 D with the lift and below 0.01 D
  !!   without it;
  !! * a snapshot taken mid-run and restored replays the following steps bit for bit (state and
  !!   phase), and the recovering step equals the plain step when no step fails.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Set_VIV, CD_HermiteCable_Dyn_Set_Waves, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_Step_Recovering, &
                                          CD_HermiteCable_Dyn_Snapshot, CD_HermiteCable_Dyn_Restore, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp
  REAL(wp), PARAMETER :: D = 0.1_wp, MLIN = 8.10_wp, EA = 5.0e7_wp, EI = 1.0_wp, TENS = 5.0e4_wp
  REAL(wp), PARAMETER :: SPAN = 100.0_wp, U = 0.15_wp, DT = 0.02_wp
  INTEGER, PARAMETER :: NE = 20

  TYPE(CD_HermiteCableDynType) :: model
  REAL(wp), ALLOCATABLE :: cl(:), cf(:), df(:), q_ref(:, :), phi_ref(:, :), a_none(:)
  REAL(wp) :: amp_lift, amp_none
  INTEGER :: es, nfail, k, mid
  CHARACTER(1024) :: em

  nfail = 0
  mid = 6*(NE/2) + 3   ! r_z of the mid-span node
  ALLOCATE (cl(NE), cf(NE), df(NE))
  cl = 0.8_wp; cf = 0.18_wp; df = 0.08_wp

  ! ---- refusals ----
  CALL build(model, .FALSE.)
  CALL CD_HermiteCable_Dyn_Set_VIV(model, cl, cf, df, 0.25_wp, es, em)
  CALL require(es /= CD_HCDYN_OK, 'VIV without drag is refused')
  CALL CD_HermiteCable_Dyn_End(model)
  CALL build(model, .TRUE.)
  CALL CD_HermiteCable_Dyn_Set_VIV(model, cl(1:NE - 1), cf(1:NE - 1), df(1:NE - 1), 0.25_wp, es, em)
  CALL require(es /= CD_HCDYN_OK, 'mismatched VIV arrays are refused')
  CALL CD_HermiteCable_Dyn_Set_VIV(model, cl, cf, cf, 0.25_wp, es, em)
  CALL require(es /= CD_HCDYN_OK, 'a band with dF >= cF is refused')
  CALL CD_HermiteCable_Dyn_Set_VIV(model, cl, cf, df, -1.0_wp, es, em)
  CALL require(es /= CD_HCDYN_OK, 'a negative averaging time is refused')
  CALL CD_HermiteCable_Dyn_Set_VIV(model, 0.0_wp*cl, cf, df, 0.25_wp, es, em)
  CALL require(es == CD_HCDYN_OK .AND. .NOT. model%has_viv, 'all-zero Cl installs no VIV')
  a_none = model%a
  CALL CD_HermiteCable_Dyn_Set_VIV(model, cl, cf, df, 0.25_wp, es, em)
  CALL require(es == CD_HCDYN_OK .AND. model%has_viv, 'VIV installs: '//TRIM(em))
  ! at rest in the cross current the lift (about 0.9 N/m) moves the committed acceleration
  CALL require(MAXVAL(ABS(model%a - a_none)) > 1.0e-3_wp, 'installing the lift refreshes the acceleration')
  CALL CD_HermiteCable_Dyn_Set_VIV(model, 0.0_wp*cl, cf, df, 0.25_wp, es, em)
  CALL require(es == CD_HCDYN_OK .AND. .NOT. model%has_viv .AND. &
               MAXVAL(ABS(model%a - a_none)) <= 1.0e-12_wp*MAXVAL(ABS(a_none)), &
               'removing the lift brings the no-lift acceleration back')
  CALL CD_HermiteCable_Dyn_Set_VIV(model, cl, cf, df, 0.25_wp, es, em)
  CALL require(es == CD_HCDYN_OK .AND. model%has_viv, 'VIV installs again: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_Waves(model, 1.0_wp, 8.0_wp, 0.0_wp, 100.0_wp, GACC, es, em)
  CALL require(es /= CD_HCDYN_OK, 'an internal wave family is refused on a VIV cable')
  ! MoorDyn's 2 pi i/N from End A, half a turn on: the material tangent runs from End B to End A
  CALL require(ABS(model%viv_phi(NE + 1) - PI) < 1.0e-12_wp .AND. &
               ABS(model%viv_phi(NE) - (2.0_wp*PI/REAL(NE, wp) + PI)) < 1.0e-12_wp .AND. &
               ABS(model%viv_phi(1) - PI) < 1.0e-12_wp, 'the phases start at 2 pi i/N + pi from End A')
  ! a drag reconfigured after VIV carries the lift scale and shedding diameter with it
  BLOCK
    REAL(wp) :: k0(NE), dn0(NE + 1), hd(NE), hn(NE), ht(NE)
    k0 = model%viv_k
    dn0 = model%viv_dn
    hd = 2.0_wp*D; hn = 1.2_wp; ht = 0.0_wp
    CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hd, hn, ht, 0.0_wp, [0.0_wp, U, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. ALL(ABS(model%viv_k - 2.0_wp*k0) <= 1.0e-12_wp*k0) .AND. &
                 ALL(ABS(model%viv_dn - 2.0_wp*dn0) <= 1.0e-12_wp*dn0), &
                 'a drag reconfiguration updates the VIV lift scale and shedding diameter')
    hd = D
    CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hd, hn, ht, 0.0_wp, [0.0_wp, U, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK .AND. ALL(model%viv_k == k0) .AND. ALL(model%viv_dn == dn0), &
                 'the original drag restores them exactly')
  END BLOCK

  ! ---- lock-in, and the same line without lift ----
  amp_lift = run_amplitude(model)
  CALL CD_HermiteCable_Dyn_End(model)
  CALL build(model, .TRUE.)
  amp_none = run_amplitude(model)
  CALL CD_HermiteCable_Dyn_End(model)
  WRITE (*, '(A,F7.4,A,F8.5)') '  mid-span cross-flow amplitude / D: with lift ', amp_lift/D, ', without ', &
    amp_none/D
  CALL require(amp_lift > 0.3_wp*D, 'the line locks in with the lift')
  CALL require(amp_none < 0.01_wp*D, 'the line stays still without it')

  ! ---- snapshot replay and the recovering step ----
  CALL build(model, .TRUE.)
  CALL CD_HermiteCable_Dyn_Set_VIV(model, cl, cf, df, 0.25_wp, es, em)
  CALL advance(model, 500, .FALSE.)
  CALL CD_HermiteCable_Dyn_Snapshot(model, es, em)
  CALL require(es == CD_HCDYN_OK, 'snapshot: '//TRIM(em))
  ALLOCATE (q_ref(SIZE(model%q), 100), phi_ref(NE + 1, 100))
  DO k = 1, 100
    CALL advance(model, 1, .FALSE.)
    q_ref(:, k) = model%q
    phi_ref(:, k) = model%viv_phi
  END DO
  CALL CD_HermiteCable_Dyn_Restore(model, es, em)
  CALL require(es == CD_HCDYN_OK, 'restore: '//TRIM(em))
  DO k = 1, 100
    CALL advance(model, 1, .FALSE.)
    IF (ANY(model%q /= q_ref(:, k)) .OR. ANY(model%viv_phi /= phi_ref(:, k))) EXIT
  END DO
  CALL require(k > 100, 'the restored snapshot replays the state and phase bit for bit')
  ! the recovering step from the same snapshot follows the plain step exactly
  CALL CD_HermiteCable_Dyn_Restore(model, es, em)
  DO k = 1, 100
    CALL advance(model, 1, .TRUE.)
    IF (ANY(model%q /= q_ref(:, k)) .OR. ANY(model%viv_phi /= phi_ref(:, k))) EXIT
  END DO
  CALL require(k > 100, 'the recovering step equals the plain step')
  CALL CD_HermiteCable_Dyn_End(model)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: cross-flow VIV on the cubic-Hermite cable'

CONTAINS

  SUBROUTINE build(m, with_drag)
    !! The pinned taut line along x, pretensioned through its unstretched length, with the cross
    !! current along y (drag) and the normal added mass.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    LOGICAL, INTENT(IN) :: with_drag
    REAL(wp) :: seed(6*(NE + 1)), l0(NE), eav(NE), eiv(NE), wv(NE), rhoa(NE), hd(NE), hn(NE), ht(NE)
    INTEGER :: fixed(6), i
    seed = 0.0_wp
    DO i = 1, NE + 1
      seed(6*(i - 1) + 1) = SPAN*REAL(i - 1, wp)/REAL(NE, wp)
      seed(6*(i - 1) + 3) = -50.0_wp
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    l0 = SPAN/REAL(NE, wp)/(1.0_wp + TENS/EA)
    eav = EA; eiv = EI; rhoa = MLIN
    wv = (MLIN - RHOW*0.25_wp*PI*D**2)*GACC
    fixed = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
    CALL CD_HermiteCable_Dyn_Init(m, l0, eav, eiv, rhoa, wv, seed, fixed, -200.0_wp, 0.0_wp, 0.5_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'init: '//TRIM(em))
    IF (.NOT. with_drag) RETURN
    hd = D; hn = 1.2_wp; ht = 0.0_wp
    CALL CD_HermiteCable_Dyn_Set_Drag(m, RHOW, hd, hn, ht, 0.0_wp, [0.0_wp, U, 0.0_wp], es, em)
    CALL require(es == CD_HCDYN_OK, 'drag: '//TRIM(em))
    hn = 1.0_wp
    CALL CD_HermiteCable_Dyn_Set_AddedMass(m, RHOW, hd, hn, ht, 0.0_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'added mass: '//TRIM(em))
  END SUBROUTINE build

  SUBROUTINE advance(m, n, recovering)
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    INTEGER, INTENT(IN) :: n
    LOGICAL, INTENT(IN) :: recovering
    INTEGER :: s
    DO s = 1, n
      IF (recovering) THEN
        CALL CD_HermiteCable_Dyn_Step_Recovering(m, DT, 50, 1.0e-8_wp, es, em)
      ELSE
        CALL CD_HermiteCable_Dyn_Step(m, DT, 50, 1.0e-8_wp, es, em)
      END IF
      IF (es /= CD_HCDYN_OK) THEN
        CALL require(.FALSE., 'step: '//TRIM(em)); RETURN
      END IF
    END DO
  END SUBROUTINE advance

  REAL(wp) FUNCTION run_amplitude(m) RESULT(amp)
    !! Half the peak-to-peak mid-span cross-flow (z) excursion over 40-60 s.
    TYPE(CD_HermiteCableDynType), INTENT(INOUT) :: m
    REAL(wp) :: zmin, zmax
    INTEGER :: s
    zmin = HUGE(1.0_wp); zmax = -HUGE(1.0_wp)
    DO s = 1, NINT(60.0_wp/DT)
      CALL advance(m, 1, .FALSE.)
      IF (es /= CD_HCDYN_OK) EXIT
      IF (REAL(s, wp)*DT < 40.0_wp) CYCLE
      zmin = MIN(zmin, m%q(mid)); zmax = MAX(zmax, m%q(mid))
    END DO
    amp = 0.5_wp*(zmax - zmin)
  END FUNCTION run_amplitude

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_viv
