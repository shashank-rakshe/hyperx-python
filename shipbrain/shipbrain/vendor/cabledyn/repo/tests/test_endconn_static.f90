! File: tests/test_endconn_static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_endconn_static
  !! System-level gates for the rotational end connection inside the finite-EI static
  !! solve. The unit gates (test_endconn_spring) prove the kernel in isolation; these
  !! prove it is wired into equilibrium correctly.
  !!
  !! CASE 1 -- ANALYTIC ROTATION AGAINST THE SPRING.
  !!   A cantilever whose root POSITION is fixed but whose root TANGENT is free is a
  !!   mechanism under a transverse tip load: it can rotate rigidly about the root, so
  !!   without an end connection the problem has no isolated equilibrium. The connection
  !!   is what makes it well posed, which is why this case cannot pass by accident. With
  !!   EI large enough that the beam's own bending is negligible beside the spring
  !!   rotation, moment balance about the root gives
  !!        k * theta = P * L      ->     theta = P L / k,   tip_z = L sin(theta)
  !!   checked against both the solved tip displacement and the solved root tangent.
  !!   Stiffness ratios are chosen so the neglected terms are bounded and stated:
  !!        beam bending / spring rotation = k/(3 EI) = 1/30000
  !!        axial stretch / spring rotation = k/(EA L^2) = 1/100000
  !!
  !! CASE 2 -- STRETCH FREEDOM AT SYSTEM LEVEL.
  !!   Under a purely AXIAL load with the preferred direction aligned to the axis, the
  !!   connection must contribute nothing: the converged state must match the
  !!   no-connection solve. This is the system-level statement of f.d == 0, the property
  !!   that stops the connection re-introducing the documented inextensibility
  !!   over-constraint. The tip z is pinned here so the rigid-rotation mode is removed
  !!   and BOTH solves are well posed.
  !!
  !! CASE 3 -- PINNED LIMIT THROUGH THE ACTIVE CODE PATH.
  !!   Zero stiffness passed THROUGH the end-connection arguments must reproduce the
  !!   no-connection solve. Passing k = 0 (rather than omitting the arguments) is the
  !!   point: it exercises the early return, which is what guarantees an explicitly
  !!   pinned deck stays bit-identical to an established result.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_PINNED, CD_ENDCONN_RIGID
  IMPLICIT NONE

  REAL(wp), PARAMETER :: L = 1.0_wp
  REAL(wp), PARAMETER :: EA = 1.0e8_wp
  REAL(wp), PARAMETER :: EI = 1.0e7_wp
  INTEGER, PARAMETER :: NE = 8
  REAL(wp), PARAMETER :: TOL = 1.0e-7_wp
  INTEGER :: nfail
  nfail = 0

  CALL case_rotation()
  CALL case_stretch_freedom()
  CALL case_pinned_limit()
  CALL case_rigid_exact()
  CALL case_invalid_contract()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: end-connection static rotation, stretch freedom and pinned limit'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE note(bad, what, got, want)
    LOGICAL, INTENT(IN) :: bad
    CHARACTER(*), INTENT(IN) :: what
    REAL(wp), INTENT(IN), OPTIONAL :: got, want
    IF (.NOT. bad) RETURN
    nfail = nfail + 1
    IF (PRESENT(got) .AND. PRESENT(want)) THEN
      WRITE (*, '(A,A,A,ES13.6,A,ES13.6)') 'FAIL: ', what, '  got=', got, ' want=', want
    ELSE
      WRITE (*, '(A,A)') 'FAIL: ', what
    END IF
  END SUBROUTINE note

  SUBROUTINE solve(use_conn, k_rot, tip_fz, tip_fx, pin_tip_z, q, ok, contract_case)
    !! Straight cantilever along +x in the x-z plane, root position fixed and root
    !! tangent free. use_conn selects whether the end-connection arguments are passed
    !! at all, so a k = 0 run still travels the active code path.
    LOGICAL, INTENT(IN) :: use_conn, pin_tip_z
    REAL(wp), INTENT(IN) :: k_rot, tip_fz, tip_fx
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q(:)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER, INTENT(IN), OPTIONAL :: contract_case
    INTEGER :: nn, i, kk, es, iters, nfix, ccase
    REAL(wp) :: le, res
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), wv(:), seed(:), curv(:), fnod(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp) :: kend(2), dend(3, 2)
    CHARACTER(300) :: em

    nn = NE + 1
    le = L/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), wv(NE), seed(6*nn), q(6*nn), curv(nn), fnod(6*nn))
    l0 = le; EAv = EA; EIv = EI; wv = 0.0_wp
    seed = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*le
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    fnod = 0.0_wp
    fnod(6*(nn - 1) + 3) = tip_fz
    fnod(6*(nn - 1) + 1) = tip_fx

    nfix = 3 + 2*nn
    IF (pin_tip_z) nfix = nfix + 1
    ALLOCATE (fixed(nfix))
    fixed(1:3) = [1, 2, 3]                        ! root position only; tangent free
    kk = 3
    DO i = 1, nn
      fixed(kk + 1) = 6*(i - 1) + 2               ! r_y  (planar)
      fixed(kk + 2) = 6*(i - 1) + 5               ! m_y  (planar)
      kk = kk + 2
    END DO
    ! Pinning the tip z removes the rigid-rotation mode, so a zero-stiffness solve is
    ! well posed and can legitimately be compared against a connected one.
    IF (pin_tip_z) fixed(nfix) = 6*(nn - 1) + 3

    kend = [k_rot, 0.0_wp]
    dend = 0.0_wp
    dend(1, 1) = 1.0_wp                            ! prefer +x at the root
    dend(1, 2) = 1.0_wp
    ccase = 0
    IF (PRESENT(contract_case)) ccase = contract_case
    IF (ccase == 1) THEN
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                        1, 80, TOL, 1.0_wp, q, curv, res, iters, es, em, &
                                        f_nodal=fnod, endconn_stiffness=kend)
    ELSE IF (ccase == 2) THEN
      dend = 0.0_wp
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                        1, 80, TOL, 1.0_wp, q, curv, res, iters, es, em, &
                                        f_nodal=fnod, endconn_stiffness=kend, endconn_direction=dend)
    ELSE IF (use_conn) THEN
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                        1, 80, TOL, 1.0_wp, q, curv, res, iters, es, em, &
                                        f_nodal=fnod, endconn_stiffness=kend, endconn_direction=dend)
    ELSE
      CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                        1, 80, TOL, 1.0_wp, q, curv, res, iters, es, em, &
                                        f_nodal=fnod)
    END IF
    ok = (es == CD_HCSTAT_OK)
    IF (.NOT. ok) WRITE (*, '(A,A)') '  solver: ', TRIM(em)
  END SUBROUTINE solve

  SUBROUTINE case_rotation()
    REAL(wp), PARAMETER :: KROT = 1.0e3_wp, P = 1.0_wp
    REAL(wp), ALLOCATABLE :: q(:)
    LOGICAL :: ok
    INTEGER :: nn
    REAL(wp) :: theta_exact, tip_z, theta_solved, m(3)
    nn = NE + 1
    CALL solve(.TRUE., KROT, P, 0.0_wp, .FALSE., q, ok)
    CALL note(.NOT. ok, 'rotation: solve must converge (the connection makes it well posed)')
    IF (.NOT. ok) RETURN
    theta_exact = P*L/KROT
    tip_z = q(6*(nn - 1) + 3)
    CALL note(ABS(tip_z - L*SIN(theta_exact)) > 1.0e-3_wp*L*theta_exact, &
              'rotation: tip_z = L sin(P L / k)', tip_z, L*SIN(theta_exact))
    m = q(4:6)
    theta_solved = ATAN2(m(3), m(1))
    CALL note(ABS(theta_solved - theta_exact) > 1.0e-3_wp*theta_exact, &
              'rotation: root tangent angle = P L / k', theta_solved, theta_exact)
  END SUBROUTINE case_rotation

  SUBROUTINE case_stretch_freedom()
    REAL(wp), PARAMETER :: KROT = 5.0e4_wp, FX = 1.0e4_wp
    REAL(wp), ALLOCATABLE :: q_on(:), q_off(:)
    LOGICAL :: ok1, ok2
    REAL(wp) :: dmax
    CALL solve(.TRUE., KROT, 0.0_wp, FX, .TRUE., q_on, ok1)
    CALL solve(.FALSE., 0.0_wp, 0.0_wp, FX, .TRUE., q_off, ok2)
    CALL note(.NOT. (ok1 .AND. ok2), 'stretch: both solves must converge')
    IF (.NOT. (ok1 .AND. ok2)) RETURN
    dmax = nan_max_abs(q_on - q_off)
    CALL note(dmax > 1.0e-9_wp*L, &
              'stretch: aligned connection must not change an axial solution', dmax, 1.0e-9_wp*L)
  END SUBROUTINE case_stretch_freedom

  SUBROUTINE case_pinned_limit()
    REAL(wp), PARAMETER :: FX = 1.0e4_wp
    REAL(wp), ALLOCATABLE :: q_zero(:), q_none(:)
    LOGICAL :: ok1, ok2
    REAL(wp) :: dmax
    CALL solve(.TRUE., 0.0_wp, 0.0_wp, FX, .TRUE., q_zero, ok1)   ! k = 0 THROUGH the path
    CALL solve(.FALSE., 0.0_wp, 0.0_wp, FX, .TRUE., q_none, ok2)
    CALL note(.NOT. (ok1 .AND. ok2), 'pinned: both solves must converge')
    IF (.NOT. (ok1 .AND. ok2)) RETURN
    dmax = nan_max_abs(q_zero - q_none)
    CALL note(ABS(dmax) > 0.0_wp, 'pinned: k = 0 must be bit-identical to no connection', dmax, 0.0_wp)
  END SUBROUTINE case_pinned_limit

  SUBROUTINE case_rigid_exact()
    !! The exact branch constrains only the root tangent direction.  A transverse
    !! tip load therefore bends the beam while the root direction remains +x;
    !! no arbitrarily large stiffness or penalty tolerance enters the result.
    INTEGER :: nn, i, kk, es, iters
    REAL(wp) :: le, res, root_norm, transverse_error, tip_linear
    REAL(wp), ALLOCATABLE :: l0(:), EAv(:), EIv(:), wv(:), seed(:), q(:), curv(:), fnod(:)
    INTEGER, ALLOCATABLE :: fixed(:)
    REAL(wp) :: kend(2), dend(3, 2)
    INTEGER :: mode(2)
    CHARACTER(300) :: em

    nn = NE + 1
    le = L/REAL(NE, wp)
    ALLOCATE (l0(NE), EAv(NE), EIv(NE), wv(NE), seed(6*nn), q(6*nn), curv(nn), fnod(6*nn))
    l0 = le; EAv = EA; EIv = EI; wv = 0.0_wp; seed = 0.0_wp; fnod = 0.0_wp
    DO i = 1, nn
      seed(6*(i - 1) + 1) = REAL(i - 1, wp)*le
      seed(6*(i - 1) + 4) = 1.0_wp
    END DO
    fnod(6*(nn - 1) + 3) = 100.0_wp
    fnod(6*(nn - 1) + 1) = 1.0e4_wp

    ! Root position and planar y coordinates are fixed.  Root m_y is omitted:
    ! its two transverse tangent coordinates belong to the rigid constraint.
    ALLOCATE (fixed(3 + nn + nn - 1))
    fixed(1:3) = [1, 2, 3]
    kk = 3
    DO i = 1, nn
      kk = kk + 1; fixed(kk) = 6*(i - 1) + 2
      IF (i == 1) CYCLE
      kk = kk + 1; fixed(kk) = 6*(i - 1) + 5
    END DO
    kend = 0.0_wp
    dend = 0.0_wp; dend(1, :) = 1.0_wp
    mode = [CD_ENDCONN_RIGID, CD_ENDCONN_PINNED]
    CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, wv, seed, fixed, -1.0e3_wp, 0.0_wp, &
                                      1, 80, TOL, 1.0_wp, q, curv, res, iters, es, em, &
                                      f_nodal=fnod, endconn_stiffness=kend, endconn_direction=dend, &
                                      endconn_mode=mode)
    CALL note(es /= CD_HCSTAT_OK, 'rigid: exact constrained solve must converge')
    IF (es /= CD_HCSTAT_OK) THEN
      WRITE (*, '(A,A)') '  solver: ', TRIM(em)
      RETURN
    END IF
    root_norm = SQRT(DOT_PRODUCT(q(4:6), q(4:6)))
    transverse_error = SQRT(q(5)*q(5) + q(6)*q(6))/root_norm
    CALL note(transverse_error > 64.0_wp*EPSILON(1.0_wp), &
              'rigid: root tangent direction is enforced to round-off', transverse_error, 0.0_wp)
    tip_linear = 100.0_wp*L**3/(3.0_wp*EI)
    CALL note(ABS(q(6*(nn - 1) + 3) - tip_linear) > 2.0e-4_wp*tip_linear, &
              'rigid: constrained root still admits beam bending', q(6*(nn - 1) + 3), tip_linear)
    CALL note(ABS(root_norm - 1.0_wp) <= 1.0e-6_wp, &
              'rigid: tangent magnitude remains a solved degree of freedom')
  END SUBROUTINE case_rigid_exact

  SUBROUTINE case_invalid_contract()
    REAL(wp), ALLOCATABLE :: q(:)
    LOGICAL :: ok
    CALL solve(.TRUE., 1.0e3_wp, 0.0_wp, 0.0_wp, .TRUE., q, ok, contract_case=1)
    CALL note(ok, 'input contract: stiffness without direction must be rejected')
    CALL solve(.TRUE., 1.0e3_wp, 0.0_wp, 0.0_wp, .TRUE., q, ok, contract_case=2)
    CALL note(ok, 'input contract: zero direction with positive stiffness must be rejected')
    CALL solve(.TRUE., -1.0_wp, 0.0_wp, 0.0_wp, .TRUE., q, ok)
    CALL note(ok, 'input contract: negative stiffness must be rejected')
  END SUBROUTINE case_invalid_contract

END PROGRAM test_endconn_static
