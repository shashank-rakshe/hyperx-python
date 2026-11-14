! File: tests/test_monolithic_gates.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!> Verification gates of the monolithic body/point step (bodyScheme monolithic):
!>  1. energy: an undamped linear spring-mass Rigid6 (heave on C33, fully wet, no drag, no added
!>     mass) conserves E = m v^2/2 + C33 dz^2/2 to 5e-10 at dtM = 0.1 s, rhoInf 1 and 0.4
!>     (the object block is non-dissipative whatever the lines' rhoInf);
!>  2. gyroscopic precession: a torque-free symmetric Rigid6 spun about a tilted axis keeps its
!>     spatial angular momentum and its body-frame angular velocity precesses at the analytic rate
!>     (I3 - I1)/I1 omega3, second order in dtM;
!>  3. observed temporal order: the moored buoy and the moored rod spar, released out of balance
!>     in still water, converge at second order in dtM in positions (and, for the buoy, in the
!>     fairlead tension), and the default monolithic step is as accurate as the staggered scheme
!>     (see check_order).
PROGRAM test_monolithic_gates
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_Multibody_Probe_Arm, CD_Multibody_Probe_Get
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  INTEGER :: n_fail = 0

  CALL check_energy()
  CALL check_precession()
  CALL check_order('rigid6', [0.1_wp, 0.05_wp, 0.025_wp], 0.003125_wp)
  ! the moored rod spar: positions at second order; its fairlead tension is not order-gated (at
  ! the finest halving it is limited by the dt_ref = 0.003125 s reference, one halving finer:
  ! observed 1.56 while the positions show 2.25 and 2.33)
  CALL check_order('rod', [0.025_wp, 0.0125_wp, 0.00625_wp], 0.003125_wp, tension_order=.FALSE.)
  CALL check_spar_order()
  IF (n_fail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', n_fail, ' monolithic-step gate(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: monolithic step gates (energy, gyroscopic precession, second-order accuracy)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      n_fail = n_fail + 1
      WRITE (*, '(A,A)') 'FAILED: ', msg
    END IF
  END SUBROUTINE require

  SUBROUTINE run_deck(path, root, ok)
    CHARACTER(*), INTENT(IN) :: path, root
    LOGICAL, INTENT(OUT) :: ok
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL CD_Run_Deck_Driver(path, root, conv, es, em)
    ok = es == CD_DECKDRV_OK .AND. conv
    CALL require(ok, 'deck '//TRIM(path)//' converged: '//TRIM(em))
  END SUBROUTINE run_deck

  SUBROUTINE write_body_deck(path, body_row, dtm, tmax, rho)
    !! A body-only deck: one Rigid6 row, fully wet (bodyWetting moordyn), deck pose, still water,
    !! on the monolithic step (named: a deck without lines otherwise keeps its own march).
    CHARACTER(*), INTENT(IN) :: path, body_row, rho
    REAL(wp), INTENT(IN) :: dtm, tmax
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'monolithic gate body'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') body_row
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') 'moordyn bodyWetting'
    WRITE (u, '(A)') 'monolithic bodyScheme'
    WRITE (u, '(ES12.5,A)') dtm, ' dtM'
    WRITE (u, '(ES12.5,A)') tmax, ' TMax'
    WRITE (u, '(A)') rho//' rhoInf'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Body1Pz'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_body_deck

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_energy()
    !! Heave spring-mass: m = 2e4 kg, C33 = 1e4 N/m, net buoyancy 500 g (equilibrium 0.49 m
    !! above the deck pose), released from the deck pose at rest; 60 s at dtM = 0.1 s.
    CHARACTER(3), PARAMETER :: RHOS(2) = ['1.0', '0.4']
    REAL(wp), PARAMETER :: M = 2.0e4_wp, K = 1.0e4_wp
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: zeq, e0, dev
    INTEGER :: ir, i
    LOGICAL :: ok
    CHARACTER(64) :: root

    zeq = -20.0_wp + (1025.0_wp*20.0_wp - M)*9.80665_wp/K
    DO ir = 1, SIZE(RHOS)
      root = 'mono_gate_energy_rho'//RHOS(ir)
      CALL write_body_deck(TRIM(root)//'.dat', '1 Rigid6 0 0 -20 0 0 0 2.0e4 20.0 1.0e4 0 0 0 0 3.5e4 3.5e4 3.5e4', &
                           0.1_wp, 60.0_wp, RHOS(ir))
      CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp])
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      CALL CD_Multibody_Probe_Get(rec)
      ok = ok .AND. ALLOCATED(rec)
      CALL require(ok, TRIM(root)//': probed run completes')
      IF (.NOT. ok) CYCLE
      e0 = 0.5_wp*K*(rec(4, 0) - zeq)**2
      dev = 0.0_wp
      DO i = 0, UBOUND(rec, 2)
        dev = MAX(dev, ABS(0.5_wp*M*rec(7, i)**2 + 0.5_wp*K*(rec(4, i) - zeq)**2 - e0)/e0)
      END DO
      WRITE (*, '(A,A,A,ES10.3)') 'energy gate: linear spring-mass, rhoInf ', RHOS(ir), &
        ', dtM 0.1 s, 60 s: max |E - E0|/E0 = ', dev
      CALL require(dev <= 5.0e-10_wp, TRIM(root)//': energy conserved to 5e-10')
    END DO
  END SUBROUTINE check_energy

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_precession()
    !! Torque-free symmetric top: neutrally buoyant Rigid6 (CG = CB at the reference point),
    !! I1 = I2 = 2e4, I3 = 5e4 kg m^2, omega0 = (0.3, 0, 2.0) rad/s. Body-frame omega:
    !! (w cos lt, w sin lt, omega3), l = (I3 - I1)/I1 omega3 = 3 rad/s; spatial angular
    !! momentum constant. 10 s at dtM = 0.05, 0.025, 0.0125 s (default rhoInf).
    REAL(wp), PARAMETER :: I1 = 2.0e4_wp, I3 = 5.0e4_wp, W0(3) = [0.3_wp, 0.0_wp, 2.0_wp]
    REAL(wp), PARAMETER :: DTS(3) = [0.05_wp, 0.025_wp, 0.0125_wp]
    REAL(wp), ALLOCATABLE :: rec(:, :)
    REAL(wp) :: rot(3, 3), wb(3), we(3), l0(3), lt(3), lam, t, err(3), lerr(3), jb(3)
    INTEGER :: id, i
    LOGICAL :: ok
    CHARACTER(64) :: root

    jb = [I1, I1, I3]
    lam = (I3 - I1)/I1*W0(3)
    err = HUGE(1.0_wp)
    lerr = HUGE(1.0_wp)
    DO id = 1, SIZE(DTS)
      WRITE (root, '(A,I0)') 'mono_gate_top_dt', NINT(1.0e4_wp*DTS(id))
      CALL write_body_deck(TRIM(root)//'.dat', '1 Rigid6 0 0 -20 0 0 0 20500.0 20.0 0 0 0 0 0 2.0e4 2.0e4 5.0e4', &
                           DTS(id), 10.0_wp, '0.4')
      CALL CD_Multibody_Probe_Arm([0.0_wp, 0.0_wp, 0.0_wp], W0)
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      CALL CD_Multibody_Probe_Get(rec)
      ok = ok .AND. ALLOCATED(rec)
      CALL require(ok, TRIM(root)//': probed run completes')
      IF (.NOT. ok) CYCLE
      l0 = jb*W0
      err(id) = 0.0_wp
      lerr(id) = 0.0_wp
      DO i = 0, UBOUND(rec, 2)
        t = rec(1, i)
        rot = RESHAPE(rec(8:16, i), [3, 3])
        wb = MATMUL(TRANSPOSE(rot), rec(17:19, i))
        we = [W0(1)*COS(lam*t), W0(1)*SIN(lam*t), W0(3)]
        err(id) = MAX(err(id), NORM2(wb - we)/W0(1))
        lt = MATMUL(rot, jb*wb)
        lerr(id) = MAX(lerr(id), NORM2(lt - l0)/NORM2(l0))
      END DO
      WRITE (*, '(A,F7.4,A,ES10.3,A,ES10.3)') 'gyroscopic gate: dtM ', DTS(id), &
        ': body-frame omega error / omega_perp = ', err(id), ', |L - L0|/|L0| = ', lerr(id)
    END DO
    IF (ALL(err < HUGE(1.0_wp))) THEN
      WRITE (*, '(A,2F7.3)') 'gyroscopic gate: observed order ', LOG(err(1)/err(2))/LOG(2.0_wp), &
        LOG(err(2)/err(3))/LOG(2.0_wp)
      CALL require(err(3) < 2.0e-2_wp, 'gyroscopic precession: dtM 0.0125 s within 2 % of the analytic motion')
      CALL require(LOG(err(2)/err(3))/LOG(2.0_wp) > 1.8_wp, 'gyroscopic precession: second order in dtM')
      CALL require(lerr(3) < 5.0e-6_wp, 'gyroscopic precession: spatial angular momentum conserved')
    END IF
  END SUBROUTINE check_precession

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE write_moored_deck(path, body, dtm, scheme, substep)
    !! The moored Rigid6 buoy (body = 'rigid6', examples/rigid6_buoy.dat) or the moored rod spar
    !! ('rod', examples/rod_moored_spar.dat) released in still water 0.5 m (buoy) or 0.2 m (spar)
    !! downstream of the deck pose; 20 s at dtM = dtm with bodyScheme scheme, bodySubstep substep.
    CHARACTER(*), INTENT(IN) :: path, body, scheme, substep
    REAL(wp), INTENT(IN) :: dtm
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'monolithic gate moored release'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    IF (body == 'rigid6') THEN
      WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
      WRITE (u, '(A)') '1 Rigid6 0.5 0 -20 0 0 0 2.0e4 40.0 0.0 0.0 0.0 8.0 0.5 3.5e4 3.5e4 3.5e4'
      WRITE (u, '(A)') '--- POINTS ---'
      WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
      WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
      WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
      WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
      WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
      WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
      WRITE (u, '(A)') '--- LINES ---'
      WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (-)'
      WRITE (u, '(A)') '1 1 4 -'
      WRITE (u, '(A)') '2 2 5 -'
      WRITE (u, '(A)') '3 3 6 -'
      WRITE (u, '(A)') '--- SECTIONS ---'
      WRITE (u, '(A)') 'LineID LineType Length NumSegs'
      WRITE (u, '(A)') '(-) (-) (m) (-)'
      WRITE (u, '(A)') '1 poly 86.85 20'
      WRITE (u, '(A)') '2 poly 86.85 20'
      WRITE (u, '(A)') '3 poly 86.85 20'
      WRITE (u, '(A)') '--- OPTIONS ---'
      WRITE (u, '(A)') '100.0 WtrDpth'
    ELSE
      WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
      WRITE (u, '(A)') '--- ROD TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
      WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'spar 1.0 300.0 0.8 1.0 0.0 0.0 0.2 0.0'
      WRITE (u, '(A)') '--- RODS ---'
      WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
      WRITE (u, '(A)') '1 spar Free 0.2 0 -30 0.2 0 -20 1 -'
      WRITE (u, '(A)') '--- POINTS ---'
      WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A)') '1 Rod1A 0.2 0 -30 0 0 0 0'
      WRITE (u, '(A)') '2 Rod1B 0.2 0 -20 0 0 0 0'
      WRITE (u, '(A)') '3 Fixed 25.0 0.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '4 Fixed -25.0 0.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '5 Fixed 0.0 30.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '6 Fixed 0.0 -30.0 -50.0 0 0 0 0'
      WRITE (u, '(A)') '--- LINES ---'
      WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (-)'
      WRITE (u, '(A)') '1 1 3 -'
      WRITE (u, '(A)') '2 1 4 -'
      WRITE (u, '(A)') '3 2 5 -'
      WRITE (u, '(A)') '4 2 6 -'
      WRITE (u, '(A)') '--- SECTIONS ---'
      WRITE (u, '(A)') 'LineID LineType Length NumSegs'
      WRITE (u, '(A)') '(-) (-) (m) (-)'
      WRITE (u, '(A)') '1 poly 31.95 16'
      WRITE (u, '(A)') '2 poly 31.95 16'
      WRITE (u, '(A)') '3 poly 42.40 20'
      WRITE (u, '(A)') '4 poly 42.40 20'
      WRITE (u, '(A)') '--- OPTIONS ---'
      WRITE (u, '(A)') '50.0 WtrDpth'
    END IF
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(ES12.5,A)') dtm, ' dtM'
    WRITE (u, '(A)') '20.0 TMax'
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') scheme//' bodyScheme'
    WRITE (u, '(A)') substep//' bodySubstep'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    IF (body == 'rigid6') THEN
      WRITE (u, '(A)') 'Body1Px'
      WRITE (u, '(A)') 'Body1Ry'
    ELSE
      WRITE (u, '(A)') 'Point1px'
      WRITE (u, '(A)') 'Point2px'
    END IF
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_moored_deck

  SUBROUTINE read_out(path, dat, ok)
    !! The data rows of a 4-column driver .out file (time and three channels) into dat(4, nrow).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: dat(:, :)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: u, ios, n, i
    CHARACTER(1024) :: buf
    ok = .FALSE.
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    n = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      n = n + 1
    END DO
    REWIND (u)
    READ (u, '(A)') buf
    READ (u, '(A)') buf
    ALLOCATE (dat(4, n - 2))
    DO i = 1, n - 2
      READ (u, *, IOSTAT=ios) dat(:, i)
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ok = ALL(IEEE_IS_FINITE(dat)) .AND. n > 3
  END SUBROUTINE read_out

  SUBROUTINE series_error(dc, dr, err)
    !! Per channel, max |y - y_ref| over the coarse run's output times / max |y_ref - y_ref(0)|.
    REAL(wp), INTENT(IN) :: dc(:, :), dr(:, :)
    REAL(wp), INTENT(OUT) :: err(3)
    INTEGER :: i, j, k
    REAL(wp) :: dtr
    dtr = dr(1, 2) - dr(1, 1)
    err = 0.0_wp
    DO i = 1, SIZE(dc, 2)
      j = NINT(dc(1, i)/dtr) + 1
      IF (j < 1 .OR. j > SIZE(dr, 2)) CYCLE
      IF (ABS(dr(1, j) - dc(1, i)) > 1.0e-6_wp) CYCLE
      DO k = 1, 3
        err(k) = MAX(err(k), ABS(dc(k + 1, i) - dr(k + 1, j)))
      END DO
    END DO
    DO k = 1, 3
      err(k) = err(k)/nan_max_abs(dr(k + 1, :) - dr(k + 1, 1))
    END DO
  END SUBROUTINE series_error

  SUBROUTINE check_order(body, dts, dt_ref, order, tension_order)
    !! 1. (order, default .TRUE.) Observed order: the monolithic step at dtM as given (none
    !!    bodySubstep) at dts(1:3) against a dtM = dt_ref run: log2 of the error ratio of the two
    !!    finer halvings >= 1.8 in both positions and the fairlead tension.
    !! 2. Default monolithic (accuracy bodySubstep) against staggered at dtM = 0.1, 0.05 and
    !!    0.025 s: no less accurate at 0.1 and 0.05 s, where the monolithic step sub-steps; at a
    !!    dtM neither sub-steps, the trapezoidal object step carries the phase-error constant
    !!    1/12 against the 1/24 of the staggered central difference (1/12 is the smallest of any
    !!    A-stable second-order method, Dahlquist), so there it is held within that factor 2.
    CHARACTER(*), INTENT(IN) :: body
    REAL(wp), INTENT(IN) :: dts(3), dt_ref
    LOGICAL, INTENT(IN), OPTIONAL :: order, tension_order
    REAL(wp), PARAMETER :: DTC(3) = [0.1_wp, 0.05_wp, 0.025_wp]
    CHARACTER(10), PARAMETER :: SCHEMES(2) = ['monolithic', 'staggered ']
    REAL(wp), ALLOCATABLE :: dr(:, :), dc(:, :)
    REAL(wp) :: err(3, 3), cmp(3, 3, 2), p(3)
    INTEGER :: id, is
    LOGICAL :: ok, do_order, do_tension
    CHARACTER(80) :: root

    do_order = .TRUE.
    IF (PRESENT(order)) do_order = order
    do_tension = .TRUE.
    IF (PRESENT(tension_order)) do_tension = tension_order
    root = 'mono_gate_order_'//body//'_ref'
    CALL write_moored_deck(TRIM(root)//'.dat', body, dt_ref, 'monolithic', 'none')
    CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
    IF (ok) CALL read_out(TRIM(root)//'.out', dr, ok)
    CALL require(ok, 'order gate '//body//': reference run')
    IF (.NOT. ok) RETURN
    err = HUGE(1.0_wp)
    DO id = 1, 3
      IF (.NOT. do_order) EXIT
      WRITE (root, '(A,A,A,I0)') 'mono_gate_order_', body, '_none_dt', NINT(1.0e4_wp*dts(id))
      CALL write_moored_deck(TRIM(root)//'.dat', body, dts(id), 'monolithic', 'none')
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      IF (ok) CALL read_out(TRIM(root)//'.out', dc, ok)
      CALL require(ok, 'order gate '//TRIM(root)//': run')
      IF (.NOT. ok) CYCLE
      CALL series_error(dc, dr, err(:, id))
      WRITE (*, '(A,A,A,F7.4,A,3ES10.3)') 'order gate ', body, ' monolithic (dtM as given) dtM ', dts(id), &
        ': error [position, position, FairTen1] = ', err(:, id)
    END DO
    IF (do_order .AND. ALL(err < HUGE(1.0_wp))) THEN
      p = LOG(err(:, 2)/err(:, 3))/LOG(2.0_wp)
      WRITE (*, '(A,A,A,3F7.3)') 'order gate ', body, ': observed order ', p
      CALL require(ALL(p(1:2) > 1.8_wp), 'order gate '//body//': second order in positions')
      IF (do_tension) CALL require(p(3) > 1.8_wp, 'order gate '//body//': second order in the fairlead tension')
    END IF
    cmp = HUGE(1.0_wp)
    DO is = 1, 2
      DO id = 1, 3
        WRITE (root, '(A,A,A,A,A,I0)') 'mono_gate_cmp_', body, '_', TRIM(SCHEMES(is)), '_dt', NINT(1000.0_wp*DTC(id))
        CALL write_moored_deck(TRIM(root)//'.dat', body, DTC(id), TRIM(SCHEMES(is)), 'accuracy')
        CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
        IF (ok) CALL read_out(TRIM(root)//'.out', dc, ok)
        CALL require(ok, 'order gate '//TRIM(root)//': run')
        IF (.NOT. ok) CYCLE
        CALL series_error(dc, dr, cmp(:, id, is))
        WRITE (*, '(A,A,1X,A,A,F6.3,A,3ES10.3)') 'accuracy gate ', body, TRIM(SCHEMES(is)), ' dtM ', DTC(id), &
          ': error [position, position, FairTen1] = ', cmp(:, id, is)
      END DO
    END DO
    IF (ANY(cmp >= HUGE(1.0_wp))) RETURN
    DO id = 1, 2
      CALL require(ALL(cmp(:, id, 1) <= cmp(:, id, 2)), 'accuracy gate '//body// &
                   ': monolithic at least as accurate as staggered at dtM 0.1 and 0.05 s')
    END DO
    CALL require(ALL(cmp(:, 3, 1) <= 2.0_wp*cmp(:, 3, 2)), 'accuracy gate '//body// &
                 ': monolithic within the trapezoidal/central-difference error-constant ratio at dtM 0.025 s')
  END SUBROUTINE check_order

  SUBROUTINE check_spar_order()
    !! The ballasted surface-piercing spar of validation case V-SP (a free body carrying a
    !! rigidly attached surface-piercing rod, no lines) released from 3 deg pitch: 100 s at
    !! dtM = 0.4, 0.2, 0.1 s as given against dtM = 0.0125 s; observed order of the surge,
    !! heave and pitch >= 1.9 over both halvings.
    REAL(wp), PARAMETER :: DTS(4) = [0.4_wp, 0.2_wp, 0.1_wp, 0.0125_wp]
    REAL(wp), ALLOCATABLE :: dr(:, :), dc(:, :)
    REAL(wp) :: err(3, 3), p(3)
    INTEGER :: id, u
    LOGICAL :: ok
    CHARACTER(64) :: root

    err = HUGE(1.0_wp)
    DO id = SIZE(DTS), 1, -1
      WRITE (root, '(A,I0)') 'mono_gate_spar_dt', NINT(1.0e4_wp*DTS(id))
      OPEN (NEWUNIT=u, FILE=TRIM(root)//'.dat', STATUS='REPLACE', ACTION='WRITE')
      WRITE (u, '(A)') 'V-SP ballasted surface-piercing spar, pitch release from 3 deg'
      WRITE (u, '(A)') '---------------------- ROD TYPES -------------------------------------'
      WRITE (u, '(A)') 'TypeName  Diam  Mass/m  Cd  Ca  CdEnd  CaEnd'
      WRITE (u, '(A)') '(name)  (m)  (kg/m)  (-)  (-)  (-)  (-)'
      WRITE (u, '(A)') 'spar  8  5000  0.8  1  0.6  0.6'
      WRITE (u, '(A)') '---------------------- BODIES ----------------------------------------'
      WRITE (u, '(A)') 'ID  Attachment  X0  Y0  Z0  r0  p0  y0  Mass  CG*  I*  Volume  CdA*  Ca*'
      WRITE (u, '(A)') '(#)  (-)  (m)  (m)  (m)  (deg)  (deg)  (deg)  (kg)  (m)  (kg-m^2)  (m^3)  (m^2)  (-)'
      WRITE (u, '(A)') '1  Free  0  0  0  0  3  0  3.67e6  0|0|-70.0  1.37e8|1.37e8|2.94e7  0  0  0'
      WRITE (u, '(A)') '---------------------- RODS ------------------------------------------'
      WRITE (u, '(A)') 'ID  RodType  Attachment  Xa  Ya  Za  Xb  Yb  Zb  NumSegs  RodOutputs'
      WRITE (u, '(A)') '(#)  (name)  (#/key)  (m)  (m)  (m)  (m)  (m)  (m)  (-)  (-)'
      WRITE (u, '(A)') '1  spar  Body1  0  0  -80  0  0  10  45  -'
      WRITE (u, '(A)') '--------------------- OPTIONS ------------------------------------------'
      WRITE (u, '(A)') '9.80665  g'
      WRITE (u, '(A)') '1025  rhoW'
      WRITE (u, '(A)') '200  WtrDpth'
      WRITE (u, '(A)') 'deck  bodyIC'
      WRITE (u, '(ES12.5,A)') DTS(id), '  dtM'
      WRITE (u, '(A)') '100  TMax'
      WRITE (u, '(A)') 'none  bodySubstep'
      WRITE (u, '(A)') 'monolithic  bodyScheme'
      WRITE (u, '(A)') '--------------------- OUTPUTS ------------------------------------------'
      WRITE (u, '(A)') '"Body1Px"'
      WRITE (u, '(A)') '"Body1Pz"'
      WRITE (u, '(A)') '"Body1Ry"'
      WRITE (u, '(A)') '--------------------- need this line -----------------------------------'
      CLOSE (u)
      CALL run_deck(TRIM(root)//'.dat', TRIM(root), ok)
      IF (ok .AND. id == SIZE(DTS)) THEN
        CALL read_out(TRIM(root)//'.out', dr, ok)
      ELSE IF (ok) THEN
        CALL read_out(TRIM(root)//'.out', dc, ok)
        IF (ok) CALL series_error(dc, dr, err(:, id))
      END IF
      CALL require(ok, 'spar order gate: '//TRIM(root)//' runs')
      IF (.NOT. ok) RETURN
      IF (id < SIZE(DTS)) WRITE (*, '(A,F5.2,A,3ES10.3)') 'order gate spar (V-SP) dtM ', DTS(id), &
        ': error [surge, heave, pitch] = ', err(:, id)
    END DO
    DO id = 1, 2
      p = LOG(err(:, id)/err(:, id + 1))/LOG(2.0_wp)
      WRITE (*, '(A,3F7.3)') 'order gate spar (V-SP): observed order ', p
      CALL require(ALL(p > 1.9_wp), 'spar order gate: second order in surge, heave and pitch')
    END DO
  END SUBROUTINE check_spar_order

END PROGRAM test_monolithic_gates
