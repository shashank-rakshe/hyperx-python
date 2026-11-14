! File: tests/test_hermite_static_current_gradient.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_static_current_gradient
  !! The finite-EI static tangent of a depth-profile current: the drag samples the profile at
  !! the node elevations, so it moves with the nodes, and the Newton tangent carries that
  !! dependence (the current's vertical gradient times the drag's velocity derivative). On a
  !! 260 m cable (60 elements, EA 4.69e8 N, EI 1.99e4 N m^2, 157.8 N/m) hung between
  !! (0, 0, -20) and (200, 0, -150) m, in three sheared currents at their static equilibrium:
  !!   1. the drag part of the solver's tangent (the tangent with the current less the tangent
  !!      without it, both from CD_HermiteCable_Static_Solve at the same state) against central
  !!      differences of the drag part of its residual, over the vertical position columns where
  !!      the profile enters: within 1e-5 (measured 4e-10 to 8e-10; without the gradient term it
  !!      was off by 5.4e-2, 6.7e-2 and 0.20 in the three currents);
  !!   2. the Newton iterations from the still-water equilibrium to the current's at tol 1e-8,
  !!      printed (7/5/6 before, 7/5/5 with the gradient), the equilibria within the solver
  !!      tolerance of the previous ones.
  !! A fourth current is a grid (MoorDyn-C Currents 2 and 5) varying along x, y and z, sampled in a
  !! solve frame turned by 30 deg about z and shifted from the global origin, where the gradient
  !! enters every position column as R^T (dU/dx) R / 2: gate 1 over all the free position
  !! columns (measured 1.7e-9; without the gradient term 3.9e-2).
  !! A fifth case restrains the cable in torsion at both ends (GJ 1e5 N m^2 with the torque-tension
  !! coupling K/GJ = 0.02, ends pinned in bending, a quarter turn) in the cross-flow shear of case 1.
  !! The twisted solve assembles the drag and its tangent in the same residual as the untwisted one
  !! (its condensed-torsion Newton system and stability test add the torque's terms to it), so the
  !! gate is the twisted solve's convergence, stable, with a torque, and gate 1 at its twisted, out
  !! of plane equilibrium (the solver returns no tangent with torsion: the drag part is evaluated
  !! there without it), over the vertical columns.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HermiteStaticCurrentType, CD_HCSTAT_OK
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_PINNED
  USE CableDyn_Hydro, ONLY: CD_CurrentGridType
  IMPLICIT NONE
  INTEGER, PARAMETER :: NE = 60, NN = NE + 1, NDOF = 6*NN, KL = 11, KU = 11, LDAB = 2*KL + KU + 1
  REAL(wp), PARAMETER :: LEN = 260.0_wp, PI = 3.14159265358979323846_wp
  REAL(wp) :: l0(NE), EA(NE), EI(NE), w(NE), seed(NDOF), q_sw(NDOF), q(NDOF), curv(NN), res, s
  REAL(wp) :: a(3), b(3)
  INTEGER :: it, es, i, k, icase, nfail
  INTEGER, ALLOCATABLE :: fixed(:)
  CHARACTER(1024) :: em
  TYPE(CD_HermiteStaticCurrentType) :: cur
  ! case 5: the torsion of the twisted solve and its end directions
  TYPE(CD_HermiteTorsionType) :: tors
  REAL(wp) :: tdir(3, 2)

  nfail = 0
  l0 = LEN/NE
  EA = 4.69e8_wp
  EI = 1.99e4_wp
  w = 157.8_wp
  a = [0.0_wp, 0.0_wp, -20.0_wp]
  b = [200.0_wp, 0.0_wp, -150.0_wp]
  DO i = 1, NN
    s = REAL(i - 1, wp)/NE
    seed(6*(i - 1) + 1:6*(i - 1) + 3) = a + s*(b - a) + [0.0_wp, 0.0_wp, -240.0_wp*s*(1.0_wp - s)]
  END DO
  DO i = 1, NN
    k = MIN(NE, i)
    seed(6*(i - 1) + 4:6*(i - 1) + 6) = (seed(6*k + 1:6*k + 3) - seed(6*(k - 1) + 1:6*(k - 1) + 3))/l0(1)
  END DO
  fixed = [1, 2, 3, 6*NE + 1, 6*NE + 2, 6*NE + 3]
  CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, seed, fixed, -1.0e4_wp, 0.0_wp, 10, 400, 1.0e-10_wp, 0.7_wp, &
                                    q_sw, curv, res, it, es, em)
  CALL check(es == CD_HCSTAT_OK, 'still-water equilibrium: '//TRIM(em))
  IF (es /= CD_HCSTAT_OK) ERROR STOP 1

  DO icase = 1, 4
    CALL set_current(icase)
    CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, q_sw, fixed, -1.0e4_wp, 0.0_wp, 1, 400, 1.0e-8_wp, 1.0_wp, &
                                      q, curv, res, it, es, em, current=cur)
    CALL check(es == CD_HCSTAT_OK, 'equilibrium in the current: '//TRIM(em))
    IF (es /= CD_HCSTAT_OK) CYCLE
    WRITE (*, '(A,I0,A,I0,A,ES10.2,A,3F12.6)') '  case ', icase, ': Newton iterations from still water ', it, &
      ', residual ', res, ', mid-span node ', q(6*(NE/2) + 1:6*(NE/2) + 3)
    CALL check_drag_tangent(icase, q)
  END DO

  ! 5. restrained in torsion (GJ|K), a quarter turn, in the cross-flow shear of case 1
  IF (ALLOCATED(cur%grid)) DEALLOCATE (cur%grid)
  cur%frame_cs = [1.0_wp, 0.0_wp]
  cur%origin = [0.0_wp, 0.0_wp]
  CALL set_current(1)
  tdir(:, 1) = q_sw(4:6)/NORM2(q_sw(4:6))
  tdir(:, 2) = q_sw(NDOF - 2:NDOF)/NORM2(q_sw(NDOF - 2:NDOF))
  tors%active = .TRUE.
  ALLOCATE (tors%gj(NE), tors%couple(NE))
  tors%gj = 1.0e5_wp
  tors%couple = 0.02_wp
  tors%phi = 0.5_wp*PI
  tors%ends(:, 1) = tdir(:, 1)
  tors%ends(:, 2) = [0.0_wp, 1.0_wp, 0.0_wp]
  tors%ends(:, 3) = tdir(:, 2)
  tors%ends(:, 4) = [0.0_wp, 1.0_wp, 0.0_wp]
  CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, q_sw, fixed, -1.0e4_wp, 0.0_wp, 1, 400, 1.0e-8_wp, 1.0_wp, &
                                    q, curv, res, it, es, em, current=cur, endconn_stiffness=[0.0_wp, 0.0_wp], &
                                    endconn_direction=tdir, endconn_mode=[CD_ENDCONN_PINNED, CD_ENDCONN_PINNED], &
                                    torsion=tors)
  CALL check(es == CD_HCSTAT_OK, 'twisted equilibrium in the current: '//TRIM(em))
  IF (es == CD_HCSTAT_OK) THEN
    WRITE (*, '(A,I0,A,ES10.2,A,ES12.5,A,L1)') '  case 5 (torsion): Newton iterations ', it, ', residual ', res, &
      ', torque ', tors%torque, ' N m, stable ', tors%stable
    CALL check(ABS(tors%torque) > 1.0e2_wp, 'the twisted line carries a torque')
    CALL check(tors%stable, 'the twisted equilibrium in the current is stable')
    CALL check_drag_tangent(5, q)
  END IF

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAILED: ', nfail, ' check(s)'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: finite-EI static tangent of a depth-profile current'

CONTAINS

  SUBROUTINE check(ok, what)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: what
    IF (ok) RETURN
    WRITE (*, '(2A)') '  FAIL: ', what
    nfail = nfail + 1
  END SUBROUTINE check

  SUBROUTINE set_current(icase)
    !! 1: cross-flow shear, 0 at -150 m to 1.2 m/s at the surface; 2: in-plane shear reversing
    !! with depth; 3: oblique, strongly sheared near the surface and held above -10 m; 4: a grid
    !! varying along x, y and z in a solve frame turned by 30 deg and shifted by (40, -25) m.
    INTEGER, INTENT(IN) :: icase
    INTEGER :: ix, iy, iz
    cur%rho = 1025.0_wp
    cur%waterline_z = 0.0_wp
    cur%arc_end = [LEN]
    cur%diam = [0.16_wp]
    cur%cdn = [1.2_wp]
    cur%cdt = [0.1_wp]
    SELECT CASE (icase)
    CASE (1)
      cur%profile_z = [-150.0_wp, 0.0_wp]
      cur%profile_velocity = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.2_wp, 0.0_wp], [3, 2])
    CASE (2)
      cur%profile_z = [-150.0_wp, -60.0_wp, 0.0_wp]
      cur%profile_velocity = RESHAPE([-0.6_wp, 0.0_wp, 0.0_wp, 0.2_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                     [3, 3])
    CASE (3)
      cur%profile_z = [-150.0_wp, -40.0_wp, -10.0_wp]
      cur%profile_velocity = RESHAPE([0.0_wp, 0.0_wp, 0.0_wp, 0.3_wp, 0.3_wp, 0.0_wp, 1.0_wp, 1.5_wp, 0.0_wp], &
                                     [3, 3])
    CASE (4)
      IF (ALLOCATED(cur%profile_z)) DEALLOCATE (cur%profile_z, cur%profile_velocity)
      ALLOCATE (cur%grid)
      cur%grid%x = [-100.0_wp, 50.0_wp, 150.0_wp, 300.0_wp]
      cur%grid%y = [-200.0_wp, 0.0_wp, 200.0_wp]
      cur%grid%z = [-200.0_wp, -100.0_wp, -50.0_wp, 0.0_wp]
      cur%grid%nt = 1
      ALLOCATE (cur%grid%velocity(3, 4, 3, 4, 1))
      DO iz = 1, 4
        DO iy = 1, 3
          DO ix = 1, 4
            cur%grid%velocity(:, ix, iy, iz, 1) = [0.3_wp + 0.002_wp*cur%grid%x(ix) + 0.004_wp*cur%grid%z(iz), &
                                                   0.5_wp + 0.004_wp*cur%grid%z(iz) - 0.001_wp*cur%grid%y(iy), &
                                                   0.0002_wp*cur%grid%x(ix)]
          END DO
        END DO
      END DO
      cur%frame_cs = [COS(PI/6.0_wp), SIN(PI/6.0_wp)]
      cur%origin = [40.0_wp, -25.0_wp]
    END SELECT
  END SUBROUTINE set_current

  SUBROUTINE evaluate(qx, with_current, r, ab)
    !! The solver's residual and banded tangent at qx (no Newton update: tol = HUGE).
    REAL(wp), INTENT(IN) :: qx(NDOF)
    LOGICAL, INTENT(IN) :: with_current
    REAL(wp), INTENT(OUT) :: r(NDOF), ab(LDAB, NDOF)
    REAL(wp) :: qd(NDOF), cd(NN), rr
    INTEGER :: itx, esx
    CHARACTER(512) :: emx
    IF (with_current) THEN
      CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qx, fixed, -1.0e4_wp, 0.0_wp, 1, 1, HUGE(1.0_wp), 1.0_wp, &
                                        qd, cd, rr, itx, esx, emx, current=cur, residual_out=r, tangent_out=ab)
    ELSE
      CALL CD_HermiteCable_Static_Solve(l0, EA, EI, w, qx, fixed, -1.0e4_wp, 0.0_wp, 1, 1, HUGE(1.0_wp), 1.0_wp, &
                                        qd, cd, rr, itx, esx, emx, residual_out=r, tangent_out=ab)
    END IF
    CALL check(esx == CD_HCSTAT_OK, 'residual and tangent evaluation: '//TRIM(emx))
  END SUBROUTINE evaluate

  SUBROUTINE check_drag_tangent(icase, qs)
    !! 1: the drag part of the tangent against central differences of the drag part of the
    !! residual, over the free vertical position columns.
    INTEGER, INTENT(IN) :: icase
    REAL(wp), INTENT(IN) :: qs(NDOF)
    REAL(wp), PARAMETER :: H = 1.0e-5_wp
    REAL(wp) :: rc(NDOF), rs(NDOF), abc(LDAB, NDOF), abs_(LDAB, NDOF), dum(LDAB, NDOF), qp(NDOF)
    REAL(wp) :: rp(NDOF), rm(NDOF), col_fd(NDOF), col_an(NDOF), num, den
    INTEGER :: j, node, ii, jj
    CALL evaluate(qs, .TRUE., rc, abc)
    CALL evaluate(qs, .FALSE., rs, abs_)
    num = 0.0_wp
    den = 0.0_wp
    DO jj = 1, MERGE(3*(NE - 1), NE - 1, icase == 4)
      IF (icase == 4) THEN
        node = 2 + (jj - 1)/3
        j = 6*(node - 1) + 1 + MOD(jj - 1, 3)
      ELSE
        node = jj + 1
        j = 6*(node - 1) + 3
      END IF
      qp = qs
      qp(j) = qs(j) + H
      CALL evaluate(qp, .TRUE., rc, dum)
      CALL evaluate(qp, .FALSE., rs, dum)
      rp = rc - rs
      qp(j) = qs(j) - H
      CALL evaluate(qp, .TRUE., rc, dum)
      CALL evaluate(qp, .FALSE., rs, dum)
      rm = rc - rs
      col_fd = (rp - rm)/(2.0_wp*H)
      col_an = 0.0_wp
      DO ii = MAX(1, j - KU), MIN(NDOF, j + KL)
        col_an(ii) = abc(KL + KU + 1 + ii - j, j) - abs_(KL + KU + 1 + ii - j, j)
      END DO
      DO ii = 1, NDOF
        IF (ANY(fixed == ii)) CYCLE
        num = num + (col_an(ii) - col_fd(ii))**2
        den = den + col_fd(ii)**2
      END DO
    END DO
    WRITE (*, '(A,I0,A,A,ES10.3)') '  case ', icase, ': drag tangent vs central differences, ', &
      MERGE('position columns:', 'vertical columns:', icase == 4), SQRT(num/den)
    CALL check(SQRT(num/den) <= 1.0e-5_wp, 'the drag tangent carries the current''s vertical gradient')
  END SUBROUTINE check_drag_tangent
END PROGRAM test_hermite_static_current_gradient
