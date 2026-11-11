! File: tests/test_static_current_balance.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_static_current_balance
  !! Global force balance of the static equilibrium of a finite-EI cable in a uniform current:
  !! the end reactions (the force the line exerts on each end point, CD_HermiteCable_Dyn_End_Force,
  !! the FairTen/AnchTen and Point<P>F quantities) balance the submerged weight and the Morison
  !! drag of the converged shape, -F_A - F_B + W + D = 0. D is integrated here independently:
  !! the documented law f = rho d Cdn |u_n| u_n / 2 + rho pi d Cdt |u_t| u_t / 2 per unit
  !! deformed length on the converged cubic-Hermite centreline (its nodal positions and
  !! tangents), by the solver's 3-point Gauss rule and by a 10-point one. The cables are pinned
  !! (bending-free) or clamped at End A, in currents of 0.5, 1 and 2 m/s at headings 0, 45, 90
  !! and 180 deg across the vertical plane of the ends, suspended (every component checked) and
  !! with a touchdown on a flat seabed (the horizontal components: the floor carries the vertical
  !! load), on 100 and 25 elements. With the 3-point rule the balance closes to 1e-7 of the end
  !! force on every case (the reactions are those of the equilibrium); with the 10-point rule to
  !! 2e-7 on 100 elements and 5e-6 on 25 (the drag quadrature). A current that leaves the line
  !! no tension-only equilibrium is refused by name, as the deck is.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_End, CD_AGG_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCable_Dyn_End_Force, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: TOL_SOLVER_RULE = 1.0e-7_wp
  INTEGER, PARAMETER :: MESHES(2) = [100, 25]
  REAL(wp), PARAMETER :: TOL_EXACT(2) = [2.0e-7_wp, 5.0e-6_wp]
  REAL(wp), PARAMETER :: SPEEDS(3) = [0.5_wp, 1.0_wp, 2.0_wp]
  REAL(wp), PARAMETER :: HEADINGS(4) = [0.0_wp, 45.0_wp, 90.0_wp, 180.0_wp]
  INTEGER :: nfail, n_run, iu, ih, iclamp, itd, n_elem, im
  REAL(wp) :: worst3, worst10, tol10

  nfail = 0
  n_run = 0
  DO im = 1, SIZE(MESHES)
    n_elem = MESHES(im)
    tol10 = TOL_EXACT(im)
    worst3 = 0.0_wp
    worst10 = 0.0_wp
    DO itd = 0, 1
      DO iclamp = 0, 1
        DO iu = 1, SIZE(SPEEDS)
          DO ih = 1, SIZE(HEADINGS)
            CALL run_case(iclamp == 1, itd == 1, SPEEDS(iu), HEADINGS(ih))
          END DO
        END DO
      END DO
    END DO
    WRITE (*, '(A,I0,A,ES10.3,A,ES10.3,A)') 'on ', n_elem, ' elements, largest relative imbalance ', worst3, &
      ' (3-point drag), ', worst10, ' (10-point drag)'
  END DO
  WRITE (*, '(A,I0)') 'cases solved: ', n_run
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' check(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS'

CONTAINS

  SUBROUTINE run_case(clamp, touchdown, speed, heading)
    LOGICAL, INTENT(IN) :: clamp, touchdown
    REAL(wp), INTENT(IN) :: speed, heading
    TYPE(CD_AGG_ModuleType) :: agg
    CHARACTER(512) :: em
    CHARACTER(64) :: path
    CHARACTER(160) :: label
    REAL(wp) :: fa(3), fb(3), weight(3), drag3(3), drag10(3), imb3(3), imb10(3), scale, rel3, rel10
    REAL(wp), ALLOCATABLE :: u_elem(:, :)
    INTEGER :: es, e

    path = 'static_current_balance.dat'
    CALL write_deck(path, clamp, touchdown, speed, heading)
    WRITE (label, '(A,I0,A,L1,A,L1,A,F4.1,A,F6.1)') 'N=', n_elem, ' clamped=', clamp, ' touchdown=', touchdown, &
      ' U=', speed, ' heading=', heading
    CALL CD_AGG_Init_From_Deck(agg, TRIM(path), 0.05_wp, es, em, deck_current=.TRUE.)
    IF (es /= CD_AGG_OK) THEN
      IF (INDEX(em, 'no tension-only static equilibrium') > 0 .OR. INDEX(em, 'no physical equilibrium') > 0) THEN
        WRITE (*, '(2A)') '  skip ', TRIM(label)//': no tension-only equilibrium in this current'
        CALL CD_AGG_End(agg, es, em)
        RETURN
      END IF
      CALL check(.FALSE., TRIM(label)//': init: '//TRIM(em))
      CALL CD_AGG_End(agg, es, em)
      RETURN
    END IF
    ASSOCIATE (ln => agg%cables(1)%line)
      CALL CD_HermiteCable_Dyn_End_Force(ln, 1, fa, es, em)
      CALL check(es == CD_HCDYN_OK, TRIM(label)//': end force 1: '//TRIM(em))
      CALL CD_HermiteCable_Dyn_End_Force(ln, ln%nn, fb, es, em)
      CALL check(es == CD_HCDYN_OK, TRIM(label)//': end force 2: '//TRIM(em))
      weight = [0.0_wp, 0.0_wp, -SUM(ln%w*ln%l0)]
      ! the element fluid velocity: the model's uniform current and, with a held field, the mean
      ! of the held field at the element's nodes (the deck current of the aggregate)
      ALLOCATE (u_elem(3, ln%ne))
      DO e = 1, ln%ne
        u_elem(:, e) = ln%current
        IF (ln%has_held_field) u_elem(:, e) = u_elem(:, e) + 0.5_wp*(ln%hf_u(:, e) + ln%hf_u(:, e + 1))
      END DO
      ! the deck's uniform current, in the cable's frame (turned about z)
      CALL check(MAXVAL(ABS(NORM2(u_elem(1:2, :), DIM=1) - speed)) <= 1.0e-12_wp*speed .AND. &
                 MAXVAL(ABS(u_elem(3, :))) <= 1.0e-12_wp*speed, TRIM(label)//': the cable sees the deck current')
      CALL line_drag(ln%q, ln%l0, ln%diam, ln%cdn, ln%cdt, ln%rho_w, u_elem, 3, drag3)
      CALL line_drag(ln%q, ln%l0, ln%diam, ln%cdn, ln%cdt, ln%rho_w, u_elem, 10, drag10)
    END ASSOCIATE
    imb3 = -fa - fb + weight + drag3
    imb10 = -fa - fb + weight + drag10
    IF (touchdown) THEN
      imb3(3) = 0.0_wp
      imb10(3) = 0.0_wp
    END IF
    scale = MAX(NORM2(fa), NORM2(fb))
    rel3 = NORM2(imb3)/scale
    rel10 = NORM2(imb10)/scale
    worst3 = MAX(worst3, rel3)
    worst10 = MAX(worst10, rel10)
    n_run = n_run + 1
    WRITE (*, '(2A,ES10.3,A,ES10.3,A,ES10.3,A)') '  ', TRIM(label)//': end force ', scale, &
      ' N, relative imbalance ', rel3, ' (3-point drag), ', rel10, ' (10-point)'
    CALL check(rel3 <= TOL_SOLVER_RULE, TRIM(label)//': the end reactions balance the weight and the drag')
    CALL check(rel10 <= tol10, TRIM(label)//': the drag quadrature is converged')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE run_case

  SUBROUTINE line_drag(q, l0, diam, cdn, cdt, rho, u, order, drag)
    !! The documented Morison drag of the still line in the current u (per element), integrated
    !! on the cubic-Hermite centreline of q ([r, m] per node) per deformed length by the
    !! order-point Gauss rule (3 or 10).
    REAL(wp), INTENT(IN) :: q(:), l0(:), diam(:), cdn(:), cdt(:), rho, u(:, :)
    INTEGER, INTENT(IN) :: order
    REAL(wp), INTENT(OUT) :: drag(3)
    REAL(wp), PARAMETER :: X10(5) = [0.1488743389816312_wp, 0.4333953941292472_wp, 0.6794095682990244_wp, &
                                     0.8650633666889845_wp, 0.9739065285171717_wp]
    REAL(wp), PARAMETER :: W10(5) = [0.2955242247147529_wp, 0.2692667193099963_wp, 0.2190863625159820_wp, &
                                     0.1494513491505806_wp, 0.0666713443086881_wp]
    REAL(wp), PARAMETER :: X3 = 0.7745966692414834_wp
    REAL(wp) :: xg(10), wg(10), xi, rp(3), sp, t(3), ut(3), un(3), dh(4)
    INTEGER :: e, g, s, b, ng
    IF (order == 3) THEN
      ng = 3
      xg(1:3) = [0.5_wp*(1.0_wp - X3), 0.5_wp, 0.5_wp*(1.0_wp + X3)]
      wg(1:3) = [5.0_wp, 8.0_wp, 5.0_wp]/18.0_wp
    ELSE
      ng = 10
      xg = [0.5_wp*(1.0_wp - X10(5:1:-1)), 0.5_wp*(1.0_wp + X10)]
      wg = [0.5_wp*W10(5:1:-1), 0.5_wp*W10]
    END IF
    drag = 0.0_wp
    DO e = 1, SIZE(l0)
      b = 6*(e - 1)
      DO g = 1, ng
        xi = xg(g)
        dh = [6.0_wp*xi*xi - 6.0_wp*xi, l0(e)*(3.0_wp*xi*xi - 4.0_wp*xi + 1.0_wp), -6.0_wp*xi*xi + 6.0_wp*xi, &
              l0(e)*(3.0_wp*xi*xi - 2.0_wp*xi)]
        rp = 0.0_wp
        DO s = 1, 2
          rp = rp + dh(2*s - 1)*q(b + 6*(s - 1) + 1:b + 6*(s - 1) + 3) + dh(2*s)*q(b + 6*(s - 1) + 4:b + 6*(s - 1) + 6)
        END DO
        sp = NORM2(rp)
        t = rp/sp
        ut = DOT_PRODUCT(u(:, e), t)*t
        un = u(:, e) - ut
        drag = drag + wg(g)*sp*(0.5_wp*rho*diam(e)*cdn(e)*NORM2(un)*un + 0.5_wp*rho*PI*diam(e)*cdt(e)*NORM2(ut)*ut)
      END DO
    END DO
  END SUBROUTINE line_drag

  SUBROUTINE write_deck(path, clamp, touchdown, speed, heading)
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: clamp, touchdown
    REAL(wp), INTENT(IN) :: speed, heading
    INTEGER :: u
    REAL(wp) :: ux, uy
    ux = speed*COS(heading*PI/180.0_wp)
    uy = speed*SIN(heading*PI/180.0_wp)
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'static force balance of a cable in a current'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    WRITE (u, '(A)') 'TypeName Diam MassDenInAir EA BA/-zeta EI Cd_n Cd_t Ca_n Ca_t'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cable 0.2 60.0 1.0e8 -1.0 1.0e4 1.2 0.008 1.0 0.0'
    WRITE (u, '(A)') '--------------------- POINTS -------------------------------------------------'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -10.0 0 0 0 0'
    IF (touchdown) THEN
      WRITE (u, '(A)') '2 Fixed 150.0 0.0 -100.0 0 0 0 0'
    ELSE
      WRITE (u, '(A)') '2 Fixed 80.0 0.0 -80.0 0 0 0 0'
    END IF
    WRITE (u, '(A)') '--------------------- LINES --------------------------------------------------'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--------------------- SECTIONS -----------------------------------------------'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    IF (touchdown) THEN
      WRITE (u, '(A,I0)') '1 cable 190.0 ', n_elem
    ELSE
      WRITE (u, '(A,I0)') '1 cable 125.0 ', n_elem
    END IF
    IF (clamp) THEN
      WRITE (u, '(A)') '--------------------- END CONNECTIONS ----------------------------------------'
      WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
      WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
      WRITE (u, '(A)') '1 A Rigid 0.0 0.0 -1.0'
    END IF
    WRITE (u, '(A)') '--------------------- OPTIONS ------------------------------------------------'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    IF (touchdown) WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A,2(1X,ES23.16),A)') 'uniform', ux, uy, ' 0.0 current'
    WRITE (u, '(A)') '--------------------- OUTPUTS ------------------------------------------------'
    WRITE (u, '(A)') 'END'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE check(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (ok) RETURN
    nfail = nfail + 1
    WRITE (*, '(2A)') '  FAIL ', TRIM(label)
  END SUBROUTINE check

END PROGRAM test_static_current_balance
