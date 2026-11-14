! File: src/CableDyn_HermiteTorsion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_HermiteTorsion
  !! Parallel-transport twist of a cubic-Hermite cable line, for condensed isotropic torsion.
  !!
  !! The Hermite cable (CableDyn_HermiteCable) carries [r(3), m(3)] per node, m = dr/ds, and has
  !! no twist coordinate. For an isotropic section without distributed torque the torque is
  !! uniform along a line, and the twist field condenses to one scalar per line:
  !!   E_t = (Phi - Theta(q))**2 / (2 C),   C = sum_e L_e / GJ_e,   M_t = (Phi - Theta) / C,
  !! where Phi is the imposed relative roll of the end frames and Theta(q) is the parallel-
  !! transport (smallest-rotation) holonomy of the centreline: the angle about d_B, right-hand
  !! rule, from the End-B reference normal n_B to the End-A normal n_A carried along the line.
  !! Because the Hermite curve is C1, Theta is the sum of
  !!   * one element holonomy per element (12 element DOFs),
  !!       h_e = + integral_e t1 . (a x b) / (|a|**2 (1 + t1 . a/|a|)) ds,
  !!     a = r', b = r'', t1 = m1/|m1| (Gauss-Legendre quadrature, four points by default);
  !!   * the smallest-rotation chain d_A -> t_0 -> ... -> t_N -> d_B through the unit node
  !!     tangents t_k = m_k/|m_k|.
  !! The value of the chain is evaluated by sequential composition. Its first and second
  !! derivatives are formed as a sum of local terms: every link j (u_j -> u_j+1) is given a gauge
  !! with a pole p_j = unit(u_j + u_j+1) frozen at the current configuration, so that the chain
  !! equals, up to a locally constant multiple of 2 pi,
  !!   sum_links Omega(p_j, u_j, u_j+1) - sum_vertices Omega(p_j-1, p_j, u_j) + end terms,
  !! with Omega(x, y, z) = 2 atan2(x . (y x z), 1 + x.y + y.z + z.x) the signed solid angle of a
  !! geodesic triangle. Every term depends on at most two neighbouring tangents, so the Hessian
  !! has the half-bandwidth 11 of the cable tangent. Gradient and Hessian are closed form.
  !!
  !! The end frames (d, n) enter through incremental rotations exp(w) about the current frame,
  !! w = 0: the routine also returns dTheta/dw and the w-w and w-m second derivatives.
  !!
  !! Theta is known modulo 2 pi. CD_HermiteTorsion_Accept selects the branch nearest to the
  !! previous accepted value and rejects changes larger than pi/2, so a 2 pi slip cannot pass
  !! unnoticed. All routines fail closed with named status codes: folds (1 + t1 . t < 0.5 at a
  !! Gauss point or across a chain link), non-finite values, and malformed input.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Gauss_Rule
  USE CableDyn_Linalg, ONLY: CD_Solve_Dense_As_Banded, CD_LINALG_OK
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_HermiteTorsion_Element
  PUBLIC :: CD_HermiteTorsion_Element_Stretch
  PUBLIC :: CD_HermiteTorsion_Coupling_Twist
  PUBLIC :: CD_HermiteTorsion_Line
  PUBLIC :: CD_HermiteTorsion_Fold_Check
  PUBLIC :: CD_HermiteTorsion_Unwrap
  PUBLIC :: CD_HermiteTorsion_Accept
  PUBLIC :: CD_HermiteTorsionType
  PUBLIC :: CD_HermiteTorsion_Compliance
  PUBLIC :: CD_HermiteTorsion_Validate
  PUBLIC :: CD_HermiteTorsion_Zeta_Damping
  PUBLIC :: CD_HermiteTorsion_Bordered_Solve
  PUBLIC :: CD_HermiteTorsion_Inertia
  PUBLIC :: CD_HermiteTorsion_Lowest_Mode
  PUBLIC :: CD_HermiteTorsionWorkType
  PUBLIC :: CD_HermiteTorsion_Work_Init
  PUBLIC :: CD_HermiteTorsion_Work_End
  PUBLIC :: CD_HermiteTorsion_Work_Add_Hessian
  PUBLIC :: CD_HermiteTwist_Reference
  PUBLIC :: CD_HermiteTwist_Carry
  PUBLIC :: CD_HermiteTwist_Angle
  PUBLIC :: CD_HermiteTwist_Omega
  PUBLIC :: CD_HermiteTwist_Omega_Gradient
  PUBLIC :: CD_HermiteTorsion_Stretch_Derivatives

  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_FOLD = 2
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_NONFINITE = 3
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_STEP = 4
  !! The bordered step stayed above its backward-error bound on every path (all values finite).
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_ILLCOND = 5
  !! The inertia count is unreliable (vanishing pivot or pivot growth); compute the lowest mode.
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_UNRELIABLE = 6
  !! Largest system solved densely when the banded bordered step fails.
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_DENSE_MAX = 600
  !! Half-bandwidth of d2Theta/dq2 (equal to that of the cable tangent).
  INTEGER, PARAMETER, PUBLIC :: CD_HTORS_KBAND = 11
  !! Fold guard: 1 + t1 . t at every Gauss point and 1 + u_j . u_j+1 on every chain link.
  REAL(wp), PARAMETER, PUBLIC :: CD_HTORS_FOLD_MIN = 0.5_wp
  REAL(wp), PARAMETER, PUBLIC :: CD_HTORS_PI = 3.14159265358979323846264338327950288_wp
  !! Largest accepted change of Theta between two accepted states.
  REAL(wp), PARAMETER, PUBLIC :: CD_HTORS_MAX_STEP = 0.5_wp*CD_HTORS_PI
  !! Largest imposed static twist |Phi| [rad], 1000 turns: the static solve ramps Phi in stages
  !! of at most pi/4, so a larger value (typically a units slip) would take beyond 8000 stages.
  REAL(wp), PARAMETER, PUBLIC :: CD_HTORS_MAX_TWIST = 2000.0_wp*CD_HTORS_PI

  INTEGER, PARAMETER :: NG_DEFAULT = 4, NG_MAX = 6
  REAL(wp), PARAMETER :: TWO_PI = 2.0_wp*CD_HTORS_PI
  REAL(wp), PARAMETER :: GEOM_TOL = 1.0e-12_wp
  REAL(wp), PARAMETER :: FRAME_TOL = 1.0e-8_wp
  !! Normwise backward error accepted for a bordered (Sherman-Morrison) step.
  REAL(wp), PARAMETER, PUBLIC :: CD_HTORS_BACKWARD_TOL = 1.0e-10_wp
  !! Scaled eigenvalue magnitude below which one exact zero mode (rotation of a buckled shape
  !! about a common clamp axis) is accepted as neutral, when the caller allows it.
  REAL(wp), PARAMETER, PUBLIC :: CD_HTORS_ZERO_MODE_TOL = 1.0e-8_wp

  TYPE :: CD_HermiteTorsionType
    !! Condensed torsion of one line: inputs, the one persistent state value (the accepted,
    !! unwrapped Theta) and the static stability report. Ends follow the solver's node order:
    !! end 1 is node 1 and end 2 the last node (the kernel's A and B).
    LOGICAL :: active = .FALSE.
    !! Imposed relative roll of the end-2 frame with respect to the end-1 frame [rad]; real
    !! valued, never wrapped (multiple turns are allowed).
    REAL(wp) :: phi = CD_ZERO
    !! Columns d_1, n_1, d_2, n_2 in the solve frame: unit end directors and unit reference
    !! normals perpendicular to them.
    REAL(wp) :: ends(3, 4) = CD_ZERO
    !! Torsional end compliances 1/k_t [rad/(N m)] at ends 1 and 2 (0 for a rigid end).
    REAL(wp) :: end_compliance(2) = CD_ZERO
    !! A free end (no torsional restraint, at most one of the two): an infinite end compliance.
    !! The line then carries no condensed torque, C = +Inf, and its twist is carried by the nodal
    !! twist alone (irn required): torque-tension coupling and the torsional inertia twist it, and
    !! the free end turns by the element twists, sum (M_e l0/GJ - (K/GJ)(l_e - l0)). Its end
    !! frame is a gauge only (no spring, no held angle) and end_compliance there stays 0.
    LOGICAL :: end_free(2) = .FALSE.
    !! Torsional stiffness GJ of every element [N m^2/rad] (the line compliance is the sum of
    !! l0/GJ over the elements plus the end compliances).
    REAL(wp), ALLOCATABLE :: gj(:)
    !! Torque-tension coupling K/GJ of every element [1] (M = GJ tau + K eps, T = EA eps + K tau);
    !! unallocated: no coupling. The line's axial stiffness is then EA - K^2/GJ (the stretch
    !! twists the line) and its twist Theta less sum (K/GJ)(l - l0) (CD_HermiteTorsion_Line).
    REAL(wp), ALLOCATABLE :: couple(:)
    !! Nodal-twist dynamics (CableDyn_HermiteCableDynamic): the polar rotary inertia Irn
    !! [kg m^2/m] of every element and, optionally, its internal torsional damping Bt [N m^2 s]
    !! (torque Bt d tau/dt). With irn unallocated the dynamics keeps the condensed, quasi-static
    !! torsion; the statics never read them.
    REAL(wp), ALLOCATABLE :: irn(:), bt(:)
    !! The fraction zeta of an element's critical torsional damping l0 sqrt(GJ Irn) that a
    !! negative deck Bt (-zeta) asked for, 0 on an element with a direct Bt; unallocated: every
    !! Bt is direct. bt holds the resolved value zeta l0 sqrt(GJ Irn) (CD_HermiteTorsion_Zeta_Damping),
    !! which active line control re-resolves when it changes l0, so the element keeps its zeta.
    REAL(wp), ALLOCATABLE :: bt_zeta(:)
    INTEGER :: quadrature_order = 4
    !! State: the accepted Theta (unwrapped) once has_theta; before that theta_hint selects the
    !! 2 pi branch of the first evaluation (0 for an untwisted start).
    LOGICAL :: has_theta = .FALSE.
    REAL(wp) :: theta = CD_ZERO
    REAL(wp) :: theta_hint = CD_ZERO
    !! Torque M_t = (Phi - Theta)/C at the accepted state [N m]; positive is a right-handed twist.
    REAL(wp) :: torque = CD_ZERO
    !! Static controls: test the stability of every converged twist stage, leave an unstable
    !! state by negative-curvature descent, and accept one exact zero mode (coaxial clamped
    !! ends without gravity or current).
    LOGICAL :: check_stability = .TRUE.
    LOGICAL :: descend = .TRUE.
    LOGICAL :: zero_mode_allowed = .FALSE.
    !! keep_untwisted_instability: a twist stage that is unstable with no more negative
    !! eigenvalues than the untwisted equilibrium it starts from (the twist adds no instability:
    !! the untwisted state's own, which its caller accepted, a planar state unstable out of its
    !! plane for example) is kept as it is, not descended from or refused; the report then sets
    !! untwisted_instability.
    LOGICAL :: keep_untwisted_instability = .FALSE.
    !! Static report at the returned state: stability, negative-eigenvalue count of the tangent
    !! on the free DOFs, the lowest Jacobi-scaled eigenvalue when it was computed (0 otherwise),
    !! the total potential energy, the twist-continuation stage count and the descents taken.
    LOGICAL :: stable = .FALSE.
    INTEGER :: n_negative = 0
    !! The negative-eigenvalue count of the untwisted equilibrium the twist starts from (-1: not
    !! evaluated, which it is only once a twist stage is unstable), and whether the returned
    !! unstable state was kept under keep_untwisted_instability (its count at most that one).
    INTEGER :: n_negative_untwisted = -1
    LOGICAL :: untwisted_instability = .FALSE.
    REAL(wp) :: lambda_min = CD_ZERO
    REAL(wp) :: energy = CD_ZERO
    INTEGER :: ramp_steps = 0
    INTEGER :: descents = 0
  END TYPE CD_HermiteTorsionType

  TYPE :: CD_HermiteTorsionWorkType
    !! Scratch of CD_HermiteTorsion_Line for a line of nn nodes (CD_HermiteTorsion_Work_Init).
    !! Passed as `work`, it makes the evaluation free of heap allocation (the dynamic step).
    INTEGER :: nn = 0
    REAL(wp), ALLOCATABLE :: u(:, :), pole(:, :), gu(:, :), huu(:, :, :), huv(:, :, :), band(:, :)
    !! band holds the Hessian of the last successful CD_HermiteTorsion_Line call with keep_hessian
    LOGICAL :: hess_valid = .FALSE.
  END TYPE CD_HermiteTorsionWorkType

CONTAINS

  ! ------------------------------------------------------------------------------------------
  ! line torsion data
  ! ------------------------------------------------------------------------------------------

  PURE REAL(wp) FUNCTION CD_HermiteTorsion_Compliance(tors, l0) RESULT(c)
    !! Line torsional compliance C = sum_e l0_e/GJ_e + 1/k_t1 + 1/k_t2 [rad/(N m)]; +Inf with a
    !! free end (end_free), so the condensed torque (Phi - Theta)/C and stiffness 1/C are zero.
    !! Meant for a description that passed CD_HermiteTorsion_Validate: without one GJ per
    !! element it returns NaN (so no caller can take the end compliances alone for the line's).
    USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN, IEEE_POSITIVE_INF
    TYPE(CD_HermiteTorsionType), INTENT(IN) :: tors
    REAL(wp), INTENT(IN) :: l0(:)
    c = IEEE_VALUE(c, IEEE_QUIET_NAN)
    IF (.NOT. ALLOCATED(tors%gj)) RETURN
    IF (SIZE(tors%gj) /= SIZE(l0)) RETURN
    IF (ANY(tors%end_free)) THEN
      c = IEEE_VALUE(c, IEEE_POSITIVE_INF)
      RETURN
    END IF
    c = tors%end_compliance(1) + tors%end_compliance(2) + SUM(l0/tors%gj)
  END FUNCTION CD_HermiteTorsion_Compliance

  ELEMENTAL REAL(wp) FUNCTION CD_HermiteTorsion_Zeta_Damping(zeta, l0, gj, irn) RESULT(bt)
    !! The torsional damping Bt [N m^2 s] of an element of length l0 that a deck Bt of -zeta asks
    !! for: zeta times the element's critical torsional damping l0 sqrt(GJ Irn) (the convention
    !! of the axial BA, with GJ for EA and the polar inertia Irn for the mass per length).
    REAL(wp), INTENT(IN) :: zeta, l0, gj, irn
    bt = zeta*l0*SQRT(gj*irn)
  END FUNCTION CD_HermiteTorsion_Zeta_Damping

  PURE SUBROUTINE CD_HermiteTorsion_Validate(tors, l0, ErrStat, ErrMsg)
    !! Fail-closed check of an active torsion description against a mesh of SIZE(l0) elements.
    TYPE(CD_HermiteTorsionType), INTENT(IN) :: tors
    REAL(wp), INTENT(IN) :: l0(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: k
    ErrStat = CD_HTORS_BADINPUT
    IF (.NOT. ALLOCATED(tors%gj)) THEN
      ErrMsg = 'torsion: GJ per element is missing'
      RETURN
    END IF
    IF (SIZE(tors%gj) /= SIZE(l0)) THEN
      ErrMsg = 'torsion: GJ must have one entry per element'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(tors%gj) .AND. CD_All_Finite(tors%ends) .AND. CD_Is_Finite(tors%phi) .AND. &
               CD_All_Finite(tors%end_compliance) .AND. CD_Is_Finite(tors%theta) .AND. &
               CD_Is_Finite(tors%theta_hint))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'torsion: non-finite GJ, end frame, imposed twist, compliance or state'
      RETURN
    END IF
    IF (ANY(.NOT. (tors%gj > CD_ZERO))) THEN
      ErrMsg = 'torsion: GJ must be positive on every element'
      RETURN
    END IF
    IF (ALLOCATED(tors%couple)) THEN
      IF (SIZE(tors%couple) /= SIZE(l0)) THEN
        ErrMsg = 'torsion: the torque-tension coupling must have one entry per element'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(tors%couple)) THEN
        ErrStat = CD_HTORS_NONFINITE
        ErrMsg = 'torsion: non-finite torque-tension coupling'
        RETURN
      END IF
    END IF
    IF (ALLOCATED(tors%irn)) THEN
      IF (SIZE(tors%irn) /= SIZE(l0)) THEN
        ErrMsg = 'torsion: the polar rotary inertia must have one entry per element'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(tors%irn)) THEN
        ErrStat = CD_HTORS_NONFINITE
        ErrMsg = 'torsion: non-finite polar rotary inertia'
        RETURN
      END IF
      IF (ANY(.NOT. (tors%irn > CD_ZERO))) THEN
        ErrMsg = 'torsion: the polar rotary inertia must be positive on every element'
        RETURN
      END IF
    END IF
    IF (ALLOCATED(tors%bt)) THEN
      IF (.NOT. ALLOCATED(tors%irn)) THEN
        ErrMsg = 'torsion: torsional damping needs the polar rotary inertia (nodal twist)'
        RETURN
      END IF
      IF (SIZE(tors%bt) /= SIZE(l0)) THEN
        ErrMsg = 'torsion: the torsional damping must have one entry per element'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(tors%bt)) THEN
        ErrStat = CD_HTORS_NONFINITE
        ErrMsg = 'torsion: non-finite torsional damping'
        RETURN
      END IF
      IF (ANY(tors%bt < CD_ZERO)) THEN
        ErrMsg = 'torsion: the torsional damping must be non-negative'
        RETURN
      END IF
    END IF
    IF (ALLOCATED(tors%bt_zeta)) THEN
      IF (.NOT. ALLOCATED(tors%bt)) THEN
        ErrMsg = 'torsion: a torsional damping ratio needs the torsional damping it resolves'
        RETURN
      END IF
      IF (SIZE(tors%bt_zeta) /= SIZE(l0)) THEN
        ErrMsg = 'torsion: the torsional damping ratio must have one entry per element'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(tors%bt_zeta)) THEN
        ErrStat = CD_HTORS_NONFINITE
        ErrMsg = 'torsion: non-finite torsional damping ratio'
        RETURN
      END IF
      IF (ANY(tors%bt_zeta < CD_ZERO)) THEN
        ErrMsg = 'torsion: the torsional damping ratio must be non-negative'
        RETURN
      END IF
    END IF
    IF (ANY(tors%end_compliance < CD_ZERO)) THEN
      ErrMsg = 'torsion: end compliances must be non-negative'
      RETURN
    END IF
    IF (ALL(tors%end_free)) THEN
      ErrMsg = 'torsion: both ends are free, so the line carries no torque (describe it without torsion)'
      RETURN
    END IF
    IF (ANY(tors%end_free .AND. tors%end_compliance > CD_ZERO)) THEN
      ErrMsg = 'torsion: a free end has no end compliance'
      RETURN
    END IF
    IF (ANY(tors%end_free) .AND. .NOT. ALLOCATED(tors%irn)) THEN
      ErrMsg = 'torsion: a line free at one end carries no condensed torque; its twist needs the nodal twist '// &
               '(the polar rotary inertia irn)'
      RETURN
    END IF
    IF (tors%quadrature_order < 1 .OR. tors%quadrature_order > NG_MAX) THEN
      ErrMsg = 'torsion: quadrature order must lie in [1,6]'
      RETURN
    END IF
    DO k = 1, 3, 2
      IF (ABS(NORM2(tors%ends(:, k)) - CD_ONE) > FRAME_TOL .OR. ABS(NORM2(tors%ends(:, k + 1)) - CD_ONE) > FRAME_TOL &
          .OR. ABS(DOT_PRODUCT(tors%ends(:, k), tors%ends(:, k + 1))) > FRAME_TOL) THEN
        ErrMsg = 'torsion: each end director and reference normal must be orthonormal'
        RETURN
      END IF
    END DO
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteTorsion_Validate

  ! ------------------------------------------------------------------------------------------
  ! bordered (Sherman-Morrison) solve and the inertia of B + g g^T / C
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE CD_HermiteTorsion_Bordered_Solve(ab, kl, ku, g, compliance, rhs, x, ErrStat, ErrMsg, &
                                              backward_error, shifted, dense)
    !! Solve (B + g g^T / C) x = rhs, B a general band matrix in LAPACK DGBSV storage (ab, with
    !! the 2 kl + ku + 1 rows of DGBTRF; not modified) and g a dense vector, through one band
    !! factorization of B and two right-hand sides (the bordered system [B g; g^T -C]):
    !!   B y = rhs, B z = g, mu = g.y/(C + g.z), x = y - mu z.
    !! The step is accepted only with a successful factorization, the pivot guard
    !! min|U_ii| > 1e3 eps max|U_ii|, a denominator |C + g.z| > 1e-12 (C + |g.z|) and a normwise
    !! backward error ||K x - rhs|| / (||K|| ||x|| + ||rhs||) <= CD_HTORS_BACKWARD_TOL (infinity
    !! norms, K applied as the band product plus the rank-one term). Otherwise B is shifted by
    !! sigma = 1e-10 max|diag B|, Sherman-Morrison is applied to the shifted matrix and two steps
    !! of iterative refinement against the true K follow; the same backward-error test decides.
    !! Sherman-Morrison loses accuracy when g^T B^-1 g / C is very large even if K is well
    !! conditioned, so a line of at most CD_HTORS_DENSE_MAX DOFs is then solved densely (K
    !! assembled, LU with partial pivoting, dense = .TRUE.) under the same test. A failure of
    !! every path leaves x = 0 with ErrStat CD_HTORS_ILLCOND (CD_HTORS_NONFINITE only for a
    !! non-finite result). B may be singular where K is not (the rank-one term is positive
    !! semidefinite); at a straight state g = 0 and K = B.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    REAL(wp), INTENT(IN) :: g(:), compliance, rhs(:)
    REAL(wp), INTENT(OUT) :: x(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: backward_error
    LOGICAL, INTENT(OUT), OPTIONAL :: shifted, dense
    REAL(wp), ALLOCATABLE :: lu(:, :), rr(:, :), res(:), dx(:)
    INTEGER, ALLOCATABLE :: ipiv(:)
    REAL(wp) :: sigma, eta, knorm
    INTEGER :: n, ldab, attempt, refine
    LOGICAL :: ok, finite_fail
    CHARACTER(1024) :: why

    x = CD_ZERO
    IF (PRESENT(backward_error)) backward_error = HUGE(CD_ONE)
    IF (PRESENT(shifted)) shifted = .FALSE.
    IF (PRESENT(dense)) dense = .FALSE.
    n = SIZE(ab, 2)
    ldab = SIZE(ab, 1)
    ErrStat = CD_HTORS_BADINPUT
    IF (kl < 0 .OR. ku < 0 .OR. ldab /= 2*kl + ku + 1 .OR. SIZE(g) /= n .OR. SIZE(rhs) /= n .OR. SIZE(x) /= n) THEN
      ErrMsg = 'CD_HermiteTorsion_Bordered_Solve: inconsistent band storage or vector sizes'
      RETURN
    END IF
    IF (.NOT. (compliance > CD_ZERO) .OR. .NOT. CD_Is_Finite(compliance)) THEN
      ErrMsg = 'CD_HermiteTorsion_Bordered_Solve: the line compliance must be finite and positive'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(g) .AND. CD_All_Finite(rhs))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Bordered_Solve: non-finite coupling vector or right-hand side'
      RETURN
    END IF
    ALLOCATE (lu(ldab, n), rr(n, 2), res(n), dx(n), ipiv(n))
    knorm = band_inf_norm(ab, kl, ku) + SUM(ABS(g))*MAXVAL(ABS(g))/compliance
    sigma = CD_ZERO
    why = ''
    DO attempt = 1, 2
      IF (attempt == 2) THEN
        sigma = 1.0e-10_wp*MAX(MAXVAL(ABS(ab(kl + ku + 1, :))), TINY(CD_ONE))
        IF (PRESENT(shifted)) shifted = .TRUE.
      END IF
      CALL sm_solve(sigma, rhs, x, ok, why)
      IF (.NOT. ok) CYCLE
      IF (attempt == 2) THEN
        DO refine = 1, 2
          CALL bordered_residual(x, res)
          CALL sm_solve(sigma, res, dx, ok, why)
          IF (.NOT. ok) EXIT
          x = x + dx
        END DO
        IF (.NOT. ok) CYCLE
      END IF
      CALL bordered_residual(x, res)
      eta = MAXVAL(ABS(res))/MAX(knorm*MAXVAL(ABS(x)) + MAXVAL(ABS(rhs)), TINY(CD_ONE))
      IF (PRESENT(backward_error)) backward_error = eta
      IF (CD_Is_Finite(eta) .AND. eta <= CD_HTORS_BACKWARD_TOL .AND. CD_All_Finite(x)) THEN
        ErrStat = CD_HTORS_OK
        ErrMsg = ''
        RETURN
      END IF
      WRITE (why, '(A,ES9.2)') 'backward error ', eta
    END DO
    ! dense fallback for a small line: K assembled and factored with partial pivoting
    IF (n <= CD_HTORS_DENSE_MAX) THEN
      CALL dense_solve(ok)
      IF (ok) THEN
        CALL bordered_residual(x, res)
        eta = MAXVAL(ABS(res))/MAX(knorm*MAXVAL(ABS(x)) + MAXVAL(ABS(rhs)), TINY(CD_ONE))
        IF (PRESENT(backward_error)) backward_error = eta
        IF (CD_Is_Finite(eta) .AND. eta <= CD_HTORS_BACKWARD_TOL .AND. CD_All_Finite(x)) THEN
          IF (PRESENT(dense)) dense = .TRUE.
          ErrStat = CD_HTORS_OK
          ErrMsg = ''
          RETURN
        END IF
        WRITE (why, '(A,ES9.2)') 'dense backward error ', eta
      END IF
    END IF
    finite_fail = CD_All_Finite(x)
    x = CD_ZERO
    IF (finite_fail) THEN
      ErrStat = CD_HTORS_ILLCOND
      IF (n <= CD_HTORS_DENSE_MAX) THEN
        ErrMsg = 'CD_HermiteTorsion_Bordered_Solve: ill-conditioned bordered torsion step ('//TRIM(why)// &
                 '), also with a shifted factorization, refinement and a dense solve'
      ELSE
        ErrMsg = 'CD_HermiteTorsion_Bordered_Solve: ill-conditioned bordered torsion step ('//TRIM(why)// &
                 '), also with a shifted factorization and refinement'
      END IF
    ELSE
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Bordered_Solve: non-finite bordered torsion step ('//TRIM(why)//')'
    END IF

  CONTAINS

    SUBROUTINE dense_solve(success)
      !! x from the dense K = B + g g^T / C (LU with partial pivoting through the band solver
      !! at full bandwidth); success on a regular factor and a finite x.
      LOGICAL, INTENT(OUT) :: success
      REAL(wp), ALLOCATABLE :: kd(:, :)
      INTEGER :: i, j, info
      CHARACTER(1024) :: lmsg
      ALLOCATE (kd(n, n))
      DO j = 1, n
        DO i = 1, n
          kd(i, j) = g(i)*g(j)/compliance
        END DO
        DO i = MAX(1, j - ku), MIN(n, j + kl)
          kd(i, j) = kd(i, j) + ab(kl + ku + 1 + i - j, j)
        END DO
      END DO
      x = rhs
      CALL CD_Solve_Dense_As_Banded(kd, x, info, lmsg)
      success = info == CD_LINALG_OK .AND. CD_All_Finite(x)
      IF (.NOT. success) THEN
        why = TRIM(why)//'; dense factor singular'
        x = CD_ZERO
      END IF
    END SUBROUTINE dense_solve

    SUBROUTINE sm_solve(shift, b, sol, success, reason)
      REAL(wp), INTENT(IN) :: shift, b(:)
      REAL(wp), INTENT(OUT) :: sol(:)
      LOGICAL, INTENT(OUT) :: success
      CHARACTER(*), INTENT(OUT) :: reason
      REAL(wp) :: umax, umin, den, mu
      INTEGER :: info, j
      EXTERNAL :: dgbtrf, dgbtrs
      success = .FALSE.
      reason = ''
      sol = CD_ZERO
      lu = ab
      IF (shift > CD_ZERO) lu(kl + ku + 1, :) = lu(kl + ku + 1, :) + shift
      CALL dgbtrf(n, n, kl, ku, lu, ldab, ipiv, info)
      IF (info /= 0) THEN
        reason = 'singular band factor'
        RETURN
      END IF
      umax = CD_ZERO
      umin = HUGE(CD_ONE)
      DO j = 1, n
        umax = MAX(umax, ABS(lu(kl + ku + 1, j)))
        umin = MIN(umin, ABS(lu(kl + ku + 1, j)))
      END DO
      IF (.NOT. (umin > 1.0e3_wp*EPSILON(CD_ONE)*umax)) THEN
        reason = 'pivot guard'
        RETURN
      END IF
      rr(:, 1) = b
      rr(:, 2) = g
      CALL dgbtrs('N', n, kl, ku, 2, lu, ldab, ipiv, rr, n, info)
      IF (info /= 0 .OR. .NOT. CD_All_Finite(RESHAPE(rr, [2*n]))) THEN
        reason = 'band back-substitution'
        RETURN
      END IF
      den = compliance + DOT_PRODUCT(g, rr(:, 2))
      IF (.NOT. (ABS(den) > 1.0e-12_wp*(compliance + ABS(DOT_PRODUCT(g, rr(:, 2)))))) THEN
        reason = 'vanishing Sherman-Morrison denominator'
        RETURN
      END IF
      mu = DOT_PRODUCT(g, rr(:, 1))/den
      sol = rr(:, 1) - mu*rr(:, 2)
      success = CD_All_Finite(sol)
      IF (.NOT. success) reason = 'non-finite step'
    END SUBROUTINE sm_solve

    SUBROUTINE bordered_residual(sol, r)
      !! r = rhs - (B + g g^T / C) sol, with the unshifted B.
      REAL(wp), INTENT(IN) :: sol(:)
      REAL(wp), INTENT(OUT) :: r(:)
      INTEGER :: i, j
      r = rhs - g*(DOT_PRODUCT(g, sol)/compliance)
      DO j = 1, n
        DO i = MAX(1, j - ku), MIN(n, j + kl)
          r(i) = r(i) - ab(kl + ku + 1 + i - j, j)*sol(j)
        END DO
      END DO
    END SUBROUTINE bordered_residual
  END SUBROUTINE CD_HermiteTorsion_Bordered_Solve

  PURE REAL(wp) FUNCTION band_inf_norm(ab, kl, ku) RESULT(v)
    !! Infinity norm of a general band matrix in DGBSV storage.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    REAL(wp), ALLOCATABLE :: rows(:)
    INTEGER :: n, i, j
    n = SIZE(ab, 2)
    ALLOCATE (rows(n))
    rows = CD_ZERO
    DO j = 1, n
      DO i = MAX(1, j - ku), MIN(n, j + kl)
        rows(i) = rows(i) + ABS(ab(kl + ku + 1 + i - j, j))
      END DO
    END DO
    v = CD_ZERO
    IF (n > 0) v = MAXVAL(rows)
  END FUNCTION band_inf_norm

  PURE SUBROUTINE scaled_symmetric_band(ab, kl, ku, mask, g, s, gs, dsc)
    !! Lower symmetric band s (kl + 1 rows, LAPACK DPBTRF 'L' layout) of D sym(B) D on the DOFs
    !! where mask is true (identity rows elsewhere), D = diag(|B_jj|^-1/2) (1 for a zero
    !! diagonal), and gs = D g with masked entries zeroed. A congruence: the inertia of
    !! sym(B) + g g^T / C equals that of s + gs gs^T / C.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    LOGICAL, INTENT(IN) :: mask(:)
    REAL(wp), INTENT(IN) :: g(:)
    REAL(wp), INTENT(OUT) :: s(:, :), gs(:), dsc(:)
    INTEGER :: n, i, j, kd
    n = SIZE(ab, 2)
    kd = MIN(kl, ku)
    dsc = CD_ONE
    DO j = 1, n
      IF (.NOT. mask(j)) CYCLE
      IF (ABS(ab(kl + ku + 1, j)) > CD_ZERO) dsc(j) = CD_ONE/SQRT(ABS(ab(kl + ku + 1, j)))
    END DO
    s = CD_ZERO
    DO j = 1, n
      IF (.NOT. mask(j)) THEN
        s(1, j) = CD_ONE
        CYCLE
      END IF
      DO i = j, MIN(n, j + kd)
        IF (.NOT. mask(i)) CYCLE
        s(1 + i - j, j) = 0.5_wp*(ab(kl + ku + 1 + i - j, j) + ab(kl + ku + 1 + j - i, i))*dsc(i)*dsc(j)
      END DO
    END DO
    gs = CD_ZERO
    WHERE (mask) gs = dsc*g
  END SUBROUTINE scaled_symmetric_band

  SUBROUTINE CD_HermiteTorsion_Inertia(ab, kl, ku, mask, g, compliance, n_negative_b, n_negative, ErrStat, ErrMsg)
    !! Number of negative eigenvalues of the symmetric part of K = B + g g^T / C on the DOFs
    !! where mask is true (B in DGBSV storage). With the determinant lemma and interlacing,
    !!   neg(K) = neg(B) - [1 + g^T B^-1 g / C < 0];
    !! neg(B) is counted by a banded L D L^T factorization without pivoting of the Jacobi-scaled
    !! symmetric band (Sylvester's law of inertia), which also gives B^-1 g. A banded Cholesky
    !! success short-cuts the count (B positive definite, hence K). A vanishing pivot or a
    !! multiplier growth above 1e8 makes the count unreliable: ErrStat = CD_HTORS_UNRELIABLE. The
    !! band must be square (kl = ku) and g finite.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    LOGICAL, INTENT(IN) :: mask(:)
    REAL(wp), INTENT(IN) :: g(:), compliance
    INTEGER, INTENT(OUT) :: n_negative_b, n_negative
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), ALLOCATABLE :: s(:, :), gs(:), dsc(:), lb(:, :), d(:), tmp(:), w(:)
    REAL(wp) :: acc, smax, gbg
    INTEGER :: n, kd, i, j, k, info
    EXTERNAL :: dpbtrf

    n_negative_b = 0
    n_negative = 0
    n = SIZE(ab, 2)
    kd = MIN(kl, ku)
    IF (SIZE(ab, 1) /= 2*kl + ku + 1 .OR. SIZE(mask) /= n .OR. SIZE(g) /= n .OR. &
        .NOT. (compliance > CD_ZERO) .OR. kl /= ku .OR. kl < 0) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'CD_HermiteTorsion_Inertia: inconsistent input (a square band, kl = ku, is required)'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(g) .AND. CD_Is_Finite(compliance))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Inertia: non-finite coupling vector or compliance'
      RETURN
    END IF
    ALLOCATE (s(kd + 1, n), gs(n), dsc(n), lb(kd + 1, n), d(n), tmp(n), w(n))
    CALL scaled_symmetric_band(ab, kl, ku, mask, g, s, gs, dsc)
    IF (.NOT. CD_All_Finite(RESHAPE(s, [SIZE(s)]))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Inertia: non-finite tangent'
      RETURN
    END IF
    lb = s
    CALL dpbtrf('L', n, kd, lb, kd + 1, info)
    IF (info == 0) THEN
      ErrStat = CD_HTORS_OK
      ErrMsg = ''
      RETURN
    END IF
    smax = MAXVAL(ABS(s))
    lb = CD_ZERO
    DO j = 1, n
      acc = s(1, j)
      DO k = MAX(1, j - kd), j - 1
        tmp(k) = lb(1 + j - k, k)*d(k)
        acc = acc - lb(1 + j - k, k)*tmp(k)
      END DO
      d(j) = acc
      IF (.NOT. (ABS(d(j)) > 1.0e-14_wp*smax)) THEN
        ErrStat = CD_HTORS_UNRELIABLE
        ErrMsg = 'CD_HermiteTorsion_Inertia: vanishing pivot (count unreliable)'
        RETURN
      END IF
      DO i = j + 1, MIN(n, j + kd)
        acc = s(1 + i - j, j)
        DO k = MAX(1, i - kd), j - 1
          acc = acc - lb(1 + i - k, k)*tmp(k)
        END DO
        lb(1 + i - j, j) = acc/d(j)
        IF (ABS(lb(1 + i - j, j)) > 1.0e8_wp) THEN
          ErrStat = CD_HTORS_UNRELIABLE
          ErrMsg = 'CD_HermiteTorsion_Inertia: pivot growth (count unreliable)'
          RETURN
        END IF
      END DO
    END DO
    n_negative_b = COUNT(d < CD_ZERO)
    ! w = S^-1 gs by the factors: L y = gs, D, L^T w = y/D
    w = gs
    DO j = 1, n
      DO i = j + 1, MIN(n, j + kd)
        w(i) = w(i) - lb(1 + i - j, j)*w(j)
      END DO
    END DO
    w = w/d
    DO j = n, 1, -1
      DO i = j + 1, MIN(n, j + kd)
        w(j) = w(j) - lb(1 + i - j, j)*w(i)
      END DO
    END DO
    gbg = DOT_PRODUCT(gs, w)
    n_negative = n_negative_b
    IF (CD_ONE + gbg/compliance < CD_ZERO) n_negative = n_negative - 1
    IF (.NOT. CD_Is_Finite(gbg)) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Inertia: non-finite coupling term'
      RETURN
    END IF
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteTorsion_Inertia

  SUBROUTINE CD_HermiteTorsion_Lowest_Mode(ab, kl, ku, mask, g, compliance, lambda, v, ErrStat, ErrMsg)
    !! Lowest eigenvalue lambda of the Jacobi-scaled symmetric part of K = B + g g^T / C on the
    !! DOFs where mask is true (the scaling of CD_HermiteTorsion_Inertia: diag(D sym(B) D) = +-1),
    !! and the corresponding direction v in the unscaled DOFs (v^T K v has the sign of lambda;
    !! max|v| = 1; zero where mask is false). Shift-invert power iteration on (S + sigma I +
    !! gs gs^T / C)^-1, sigma just above the smallest shift that makes S + sigma I positive
    !! definite (banded Cholesky, bisected), with Sherman-Morrison for the rank-one term.
    REAL(wp), INTENT(IN) :: ab(:, :)
    INTEGER, INTENT(IN) :: kl, ku
    LOGICAL, INTENT(IN) :: mask(:)
    REAL(wp), INTENT(IN) :: g(:), compliance
    REAL(wp), INTENT(OUT) :: lambda, v(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, PARAMETER :: MAX_POWER = 400
    REAL(wp), ALLOCATABLE :: s(:, :), gs(:), dsc(:), ch(:, :), u(:), y(:), z(:)
    REAL(wp) :: sig_lo, sig_hi, sig, lam_old, den
    INTEGER :: n, kd, k, it, info
    LOGICAL :: pd
    EXTERNAL :: dpbtrf, dpbtrs

    lambda = CD_ZERO
    v = CD_ZERO
    n = SIZE(ab, 2)
    kd = MIN(kl, ku)
    IF (SIZE(ab, 1) /= 2*kl + ku + 1 .OR. SIZE(mask) /= n .OR. SIZE(g) /= n .OR. SIZE(v) /= n .OR. &
        .NOT. (compliance > CD_ZERO) .OR. .NOT. ANY(mask) .OR. kl /= ku .OR. kl < 0) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'CD_HermiteTorsion_Lowest_Mode: inconsistent input (a square band, kl = ku, is required)'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(g) .AND. CD_Is_Finite(compliance))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Lowest_Mode: non-finite coupling vector or compliance'
      RETURN
    END IF
    ALLOCATE (s(kd + 1, n), gs(n), dsc(n), ch(kd + 1, n), u(n), y(n), z(n))
    CALL scaled_symmetric_band(ab, kl, ku, mask, g, s, gs, dsc)
    ! bracket the positive-definiteness shift of S
    sig_lo = CD_ZERO
    sig_hi = 1.0e-6_wp
    DO k = 1, 60
      CALL shifted_cholesky(sig_hi, pd)
      IF (pd) EXIT
      sig_lo = sig_hi
      sig_hi = 4.0_wp*sig_hi
    END DO
    IF (.NOT. pd) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Lowest_Mode: no positive definite shift found'
      RETURN
    END IF
    DO k = 1, 40
      IF (sig_hi - sig_lo <= 1.0e-3_wp*sig_hi) EXIT
      sig = 0.5_wp*(sig_lo + sig_hi)
      CALL shifted_cholesky(sig, pd)
      IF (pd) THEN
        sig_hi = sig
      ELSE
        sig_lo = sig
      END IF
    END DO
    sig = sig_hi
    CALL shifted_cholesky(sig, pd)
    ! z = (S + sigma I)^-1 gs for the Sherman-Morrison update
    z = gs
    CALL dpbtrs('L', n, kd, 1, ch, kd + 1, z, n, info)
    den = compliance + DOT_PRODUCT(gs, z)
    DO k = 1, n
      u(k) = MERGE(CD_ONE + 0.5_wp*SIN(0.7_wp*k), CD_ZERO, mask(k))
    END DO
    u = u/NORM2(u)
    lam_old = HUGE(CD_ONE)
    DO it = 1, MAX_POWER
      y = u
      CALL dpbtrs('L', n, kd, 1, ch, kd + 1, y, n, info)
      y = y - z*(DOT_PRODUCT(gs, y)/den)
      WHERE (.NOT. mask) y = CD_ZERO
      IF (.NOT. CD_All_Finite(y) .OR. NORM2(y) <= TINY(CD_ONE)) EXIT
      u = y/NORM2(y)
      lambda = rayleigh(u)
      IF (ABS(lambda - lam_old) <= 1.0e-13_wp*MAX(CD_ONE, ABS(lambda))) EXIT
      lam_old = lambda
    END DO
    IF (.NOT. (CD_All_Finite(u) .AND. CD_Is_Finite(lambda))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Lowest_Mode: non-finite iterate'
      lambda = CD_ZERO
      RETURN
    END IF
    v = dsc*u
    WHERE (.NOT. mask) v = CD_ZERO
    IF (MAXVAL(ABS(v)) > CD_ZERO) v = v/MAXVAL(ABS(v))
    ErrStat = CD_HTORS_OK
    ErrMsg = ''

  CONTAINS

    SUBROUTINE shifted_cholesky(shift, ok)
      REAL(wp), INTENT(IN) :: shift
      LOGICAL, INTENT(OUT) :: ok
      INTEGER :: j, inf
      ch = s
      DO j = 1, n
        IF (mask(j)) ch(1, j) = ch(1, j) + shift
      END DO
      CALL dpbtrf('L', n, kd, ch, kd + 1, inf)
      ok = inf == 0
    END SUBROUTINE shifted_cholesky

    REAL(wp) FUNCTION rayleigh(x) RESULT(rq)
      !! x^T (S + gs gs^T / C) x / x^T x over the masked DOFs.
      REAL(wp), INTENT(IN) :: x(:)
      REAL(wp) :: acc
      INTEGER :: i, j
      acc = CD_ZERO
      DO j = 1, n
        IF (.NOT. mask(j)) CYCLE
        acc = acc + s(1, j)*x(j)*x(j)
        DO i = j + 1, MIN(n, j + kd)
          IF (mask(i)) acc = acc + 2.0_wp*s(1 + i - j, j)*x(i)*x(j)
        END DO
      END DO
      acc = acc + DOT_PRODUCT(gs, x)**2/compliance
      rq = acc/MAX(DOT_PRODUCT(x, x), TINY(CD_ONE))
    END FUNCTION rayleigh
  END SUBROUTINE CD_HermiteTorsion_Lowest_Mode

  ! ------------------------------------------------------------------------------------------
  ! public routines
  ! ------------------------------------------------------------------------------------------

  PURE SUBROUTINE CD_HermiteTorsion_Element(qe, L, h, grad, ErrStat, ErrMsg, hess, fold_margin, quadrature_order)
    !! Element holonomy h_e of one 12-DOF element [r1, m1, r2, m2] of reference length L, with
    !! its closed-form gradient and (optionally) Hessian. fold_margin returns min(1 + t1 . t)
    !! over the Gauss points; below CD_HTORS_FOLD_MIN the routine fails with CD_HTORS_FOLD.
    REAL(wp), INTENT(IN) :: qe(12), L
    REAL(wp), INTENT(OUT) :: h, grad(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: hess(12, 12)
    REAL(wp), INTENT(OUT), OPTIONAL :: fold_margin
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order

    REAL(wp) :: hk(12, 12), margin
    INTEGER :: order
    CHARACTER(200) :: em

    order = NG_DEFAULT
    IF (PRESENT(quadrature_order)) order = quadrature_order
    h = CD_ZERO
    grad = CD_ZERO
    IF (PRESENT(hess)) hess = CD_ZERO
    IF (PRESENT(fold_margin)) fold_margin = CD_ZERO
    IF (order < 1 .OR. order > NG_MAX) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'CD_HermiteTorsion_Element: quadrature order must lie in [1,6]'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(qe) .AND. CD_Is_Finite(L))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Element: non-finite element DOFs or length'
      RETURN
    END IF
    IF (L <= GEOM_TOL) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'CD_HermiteTorsion_Element: element length must be positive'
      RETURN
    END IF
    CALL element_holonomy(qe, L, order, PRESENT(hess), h, grad, hk, margin, ErrStat, em)
    IF (PRESENT(fold_margin)) fold_margin = margin
    IF (ErrStat /= CD_HTORS_OK) THEN
      ErrMsg = 'CD_HermiteTorsion_Element: '//em
      h = CD_ZERO
      grad = CD_ZERO
      RETURN
    END IF
    IF (PRESENT(hess)) hess = hk
  END SUBROUTINE CD_HermiteTorsion_Element

  PURE SUBROUTINE CD_HermiteTorsion_Fold_Check(q, Le, ends, margin, ErrStat, ErrMsg, quadrature_order)
    !! Fold guard for one line: margin = min(1 + t1 . t) over every Gauss point of every element
    !! and min(1 + u_j . u_j+1) over every chain link d_A -> t_0 -> ... -> t_N -> d_B. Fails with
    !! CD_HTORS_FOLD (naming the element or link) when margin < CD_HTORS_FOLD_MIN, i.e. when the
    !! tangent turns by more than 120 degrees inside one element, between two nodes, or across an
    !! articulated end. The holonomy and its derivatives grow without bound as the margin -> 0.
    REAL(wp), INTENT(IN) :: q(:), Le(:), ends(3, 4)
    REAL(wp), INTENT(OUT) :: margin
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    INTEGER :: order
    REAL(wp), ALLOCATABLE :: u(:, :)

    order = NG_DEFAULT
    IF (PRESENT(quadrature_order)) order = quadrature_order
    ALLOCATE (u(3, 0:MAX(SIZE(q)/6, 0) + 1))
    CALL line_fold_check(q, Le, ends, order, 'CD_HermiteTorsion_Fold_Check', margin, ErrStat, ErrMsg, u)
  END SUBROUTINE CD_HermiteTorsion_Fold_Check

  PURE SUBROUTINE line_fold_check(q, Le, ends, order, who, margin, ErrStat, ErrMsg, u)
    !! Validation and fold guard; u(3, 0:nn+1) receives the chain vertices (caller scratch).
    REAL(wp), INTENT(IN) :: q(:), Le(:), ends(3, 4)
    INTEGER, INTENT(IN) :: order
    CHARACTER(*), INTENT(IN) :: who
    REAL(wp), INTENT(OUT) :: margin
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT) :: u(:, 0:)

    INTEGER :: nn, e, j, ig
    REAL(wp) :: gp(NG_MAX), gw(NG_MAX), t1(3), a(3), b(3), rho, sp, val
    CHARACTER(16) :: tag

    margin = CD_ZERO
    u = CD_ZERO
    CALL validate_line(q, Le, ends, order, who, ErrStat, ErrMsg)
    IF (ErrStat /= CD_HTORS_OK) RETURN
    nn = SIZE(q)/6
    CALL chain_vertices(q, ends, u)
    CALL CD_HermiteCable_Gauss_Rule(order, gp, gw)
    margin = HUGE(CD_ONE)
    DO e = 1, nn - 1
      rho = NORM2(q(6*e - 2:6*e))
      t1 = q(6*e - 2:6*e)/rho
      DO ig = 1, order
        CALL element_ab(q(6*e - 5:6*e + 6), Le(e), gp(ig), a, b)
        sp = NORM2(a)
        IF (sp <= GEOM_TOL) THEN
          ErrStat = CD_HTORS_BADINPUT
          WRITE (tag, '(I0)') e
          ErrMsg = who//': zero centreline tangent in element '//TRIM(tag)
          RETURN
        END IF
        val = CD_ONE + DOT_PRODUCT(t1, a)/sp
        IF (val < margin) margin = val
        IF (val < CD_HTORS_FOLD_MIN) THEN
          ErrStat = CD_HTORS_FOLD
          WRITE (tag, '(I0)') e
          ErrMsg = who//': tangent turns by more than 120 degrees inside element ' &
                   //TRIM(tag)//' (1 + t1.t < 0.5); refine the mesh'
          RETURN
        END IF
      END DO
    END DO
    DO j = 0, nn
      val = CD_ONE + DOT_PRODUCT(u(:, j), u(:, j + 1))
      IF (val < margin) margin = val
      IF (val < CD_HTORS_FOLD_MIN) THEN
        ErrStat = CD_HTORS_FOLD
        IF (j == 0) THEN
          ErrMsg = who//': End-A director and first node tangent differ by more than ' &
                   //'120 degrees (1 + d.t < 0.5)'
        ELSE IF (j == nn) THEN
          ErrMsg = who//': last node tangent and End-B director differ by more than ' &
                   //'120 degrees (1 + t.d < 0.5)'
        ELSE
          WRITE (tag, '(I0)') j
          ErrMsg = who//': node tangents turn by more than 120 degrees across element ' &
                   //TRIM(tag)//' (1 + t1.t2 < 0.5); refine the mesh'
        END IF
        RETURN
      END IF
    END DO
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE line_fold_check

  PURE SUBROUTINE CD_HermiteTorsion_Work_Init(work, nn, ErrStat, ErrMsg)
    !! Size the scratch of CD_HermiteTorsion_Line for a line of nn >= 2 nodes.
    TYPE(CD_HermiteTorsionWorkType), INTENT(INOUT) :: work
    INTEGER, INTENT(IN) :: nn
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CALL CD_HermiteTorsion_Work_End(work)
    IF (nn < 2) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'CD_HermiteTorsion_Work_Init: a line needs at least two nodes'
      RETURN
    END IF
    ALLOCATE (work%u(3, 0:nn + 1), work%pole(3, 0:nn), work%gu(3, 0:nn + 1), work%huu(3, 3, 0:nn + 1), &
              work%huv(3, 3, 0:nn), work%band(2*CD_HTORS_KBAND + 1, 6*nn))
    work%nn = nn
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteTorsion_Work_Init

  PURE SUBROUTINE CD_HermiteTorsion_Work_End(work)
    !! Release the scratch of CD_HermiteTorsion_Work_Init.
    TYPE(CD_HermiteTorsionWorkType), INTENT(INOUT) :: work
    IF (ALLOCATED(work%u)) DEALLOCATE (work%u)
    IF (ALLOCATED(work%pole)) DEALLOCATE (work%pole)
    IF (ALLOCATED(work%gu)) DEALLOCATE (work%gu)
    IF (ALLOCATED(work%huu)) DEALLOCATE (work%huu)
    IF (ALLOCATED(work%huv)) DEALLOCATE (work%huv)
    IF (ALLOCATED(work%band)) DEALLOCATE (work%band)
    work%nn = 0
    work%hess_valid = .FALSE.
  END SUBROUTINE CD_HermiteTorsion_Work_End

  PURE SUBROUTINE CD_HermiteTorsion_Work_Add_Hessian(work, hband, scale, ErrStat, ErrMsg)
    !! Add scale * d2Theta/dq2, kept in `work` by the last CD_HermiteTorsion_Line call with
    !! keep_hessian, to the general band hband (layout as for CD_HermiteTorsion_Line's hband).
    !! This lets a caller scale the Hessian by a factor that depends on Theta (the torque).
    !! Fails (hband unchanged) when the last call kept no Hessian or failed, or on a size mismatch.
    TYPE(CD_HermiteTorsionWorkType), INTENT(IN) :: work
    REAL(wp), INTENT(INOUT) :: hband(:, :)
    REAL(wp), INTENT(IN) :: scale
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: n, i, jj, i0, row0
    n = 6*work%nn
    ErrStat = CD_HTORS_BADINPUT
    IF (.NOT. work%hess_valid) THEN
      ErrMsg = 'CD_HermiteTorsion_Work_Add_Hessian: the workspace holds no Hessian of a successful evaluation'
      RETURN
    END IF
    IF (n < 12 .OR. SIZE(hband, 2) /= n .OR. SIZE(hband, 1) < 2*CD_HTORS_KBAND + 1) THEN
      ErrMsg = 'CD_HermiteTorsion_Work_Add_Hessian: hband does not match the workspace'
      RETURN
    END IF
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
    row0 = CD_HTORS_KBAND + 1
    i0 = SIZE(hband, 1) - 2*CD_HTORS_KBAND - 1
    DO jj = 1, n
      DO i = MAX(1, jj - CD_HTORS_KBAND), MIN(n, jj + CD_HTORS_KBAND)
        hband(i0 + row0 + i - jj, jj) = hband(i0 + row0 + i - jj, jj) + scale*work%band(row0 + i - jj, jj)
      END DO
    END DO
  END SUBROUTINE CD_HermiteTorsion_Work_Add_Hessian

  PURE SUBROUTINE CD_HermiteTorsion_Line(q, Le, ends, theta_raw, grad, ErrStat, ErrMsg, hband, band_scale, &
                                         end_grad, end_hess, end_cross, fold_margin, quadrature_order, work, &
                                         keep_hessian, couple)
    !! Theta, dTheta/dq and d2Theta/dq2 of one line.
    !!
    !!   q(6 n)          nodal DOFs [r_k, m_k], k = 1..n (n >= 2), as in the cable solvers
    !!   Le(n - 1)       element reference lengths
    !!   ends(3, 4)      columns d_A, n_A, d_B, n_B: unit end directors and unit reference
    !!                   normals (n perpendicular to d). A clamped end has d = its end tangent.
    !!   theta_raw       sum of the element holonomies plus the chain angle; only the chain angle
    !!                   is wrapped to (-pi, pi], the holonomy sum is unbounded. Theta is defined
    !!                   modulo 2 pi -- pass it through CD_HermiteTorsion_Accept
    !!   grad(6 n)       dTheta/dq
    !!   hband           optional, INOUT: band_scale * d2Theta/dq2 is ADDED in general-band
    !!                   storage with half-bandwidth CD_HTORS_KBAND: entry (i, j) at
    !!                   hband(SIZE(hband, 1) - KBAND + i - j, j). This is the LAPACK DGBSV
    !!                   layout for SIZE(hband, 1) = 3 KBAND + 1 and the DGBMV layout for
    !!                   2 KBAND + 1. band_scale defaults to 1.
    !!   end_grad(6)     dTheta/d[w_A, w_B], w the rotation vector of an incremental rotation
    !!                   exp(w) of the end frame (d and n rotate together), at w = 0
    !!   end_hess(3,3,2) d2Theta/dw_A2 and d2Theta/dw_B2 (same parametrisation)
    !!   end_cross(3,3,2) d2Theta/dw_A dm_1 and d2Theta/dw_B dm_n (rows w, columns m). Theta has
    !!                   no other w coupling (no w_A-w_B, no w-r).
    !!   fold_margin     min(1 + t1 . t) over Gauss points and chain links
    !!   work            optional scratch sized for SIZE(q)/6 nodes (CD_HermiteTorsion_Work_Init):
    !!                   the evaluation then allocates nothing
    !!   keep_hessian    with work: compute d2Theta/dq2 into work (unscaled) for a later
    !!                   CD_HermiteTorsion_Work_Add_Hessian, also without hband
    !!   couple(n - 1)   optional torque-tension coupling K/GJ per element: theta_raw is then the
    !!                   effective twist Theta - sum_e (K/GJ)_e (l_e - Le_e), l_e the stretched
    !!                   element length, with its derivatives. With M = GJ tau + K eps uniform along
    !!                   the line, the twist the ends see is Theta less the twist the stretch takes
    !!                   up, so the condensed torque is M = (Phi - Theta_eff)/C.
    !!
    !! On any failure every output is zero and hband is left unchanged.
    REAL(wp), INTENT(IN) :: q(:), Le(:), ends(3, 4)
    REAL(wp), INTENT(OUT) :: theta_raw, grad(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(INOUT), OPTIONAL :: hband(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: band_scale
    REAL(wp), INTENT(OUT), OPTIONAL :: end_grad(6), end_hess(3, 3, 2), end_cross(3, 3, 2)
    REAL(wp), INTENT(OUT), OPTIONAL :: fold_margin
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    TYPE(CD_HermiteTorsionWorkType), INTENT(INOUT), OPTIONAL :: work
    LOGICAL, INTENT(IN), OPTIONAL :: keep_hessian
    REAL(wp), INTENT(IN), OPTIONAL :: couple(:)
    TYPE(CD_HermiteTorsionWorkType) :: local
    INTEGER :: nn
    LOGICAL :: keep

    keep = .FALSE.
    IF (PRESENT(keep_hessian)) keep = keep_hessian
    IF (PRESENT(work)) THEN
      IF (work%nn /= SIZE(q)/6 .OR. work%nn < 2) THEN
        theta_raw = CD_ZERO
        grad = CD_ZERO
        IF (PRESENT(end_grad)) end_grad = CD_ZERO
        IF (PRESENT(end_hess)) end_hess = CD_ZERO
        IF (PRESENT(end_cross)) end_cross = CD_ZERO
        IF (PRESENT(fold_margin)) fold_margin = CD_ZERO
        ErrStat = CD_HTORS_BADINPUT
        ErrMsg = 'CD_HermiteTorsion_Line: the workspace is not sized for this line'
        work%hess_valid = .FALSE.
        RETURN
      END IF
      work%hess_valid = .FALSE.
      CALL line_core(q, Le, ends, theta_raw, grad, ErrStat, ErrMsg, work%nn, work%u, work%pole, work%gu, work%huu, &
                     work%huv, work%band, keep, hband, band_scale, end_grad, end_hess, end_cross, fold_margin, &
                     quadrature_order, couple)
      work%hess_valid = keep .AND. ErrStat == CD_HTORS_OK
    ELSE
      nn = MAX(SIZE(q)/6, 2)
      ALLOCATE (local%u(3, 0:nn + 1), local%pole(3, 0:nn), local%gu(3, 0:nn + 1), local%huu(3, 3, 0:nn + 1), &
                local%huv(3, 3, 0:nn), local%band(2*CD_HTORS_KBAND + 1, 6*nn))
      CALL line_core(q, Le, ends, theta_raw, grad, ErrStat, ErrMsg, nn, local%u, local%pole, local%gu, local%huu, &
                     local%huv, local%band, .FALSE., hband, band_scale, end_grad, end_hess, end_cross, &
                     fold_margin, quadrature_order, couple)
    END IF
  END SUBROUTINE CD_HermiteTorsion_Line

  PURE SUBROUTINE line_core(q, Le, ends, theta_raw, grad, ErrStat, ErrMsg, nw, u, pole, gu, huu, huv, band, keep, &
                            hband, band_scale, end_grad, end_hess, end_cross, fold_margin, quadrature_order, couple)
    !! CD_HermiteTorsion_Line on caller scratch for nw nodes (the scratch is explicit-shape so
    !! that no expression on it needs a heap temporary); keep: compute the Hessian into band
    !! even without hband. A q of another node count fails validation before any use.
    REAL(wp), INTENT(IN) :: q(:), Le(:), ends(3, 4)
    REAL(wp), INTENT(OUT) :: theta_raw, grad(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER, INTENT(IN) :: nw
    REAL(wp), INTENT(INOUT) :: u(3, 0:nw + 1), pole(3, 0:nw), gu(3, 0:nw + 1), huu(3, 3, 0:nw + 1), huv(3, 3, 0:nw)
    REAL(wp), INTENT(INOUT) :: band(2*CD_HTORS_KBAND + 1, 6*nw)
    LOGICAL, INTENT(IN) :: keep
    REAL(wp), INTENT(INOUT), OPTIONAL :: hband(:, :)
    REAL(wp), INTENT(IN), OPTIONAL :: band_scale
    REAL(wp), INTENT(OUT), OPTIONAL :: end_grad(6), end_hess(3, 3, 2), end_cross(3, 3, 2)
    REAL(wp), INTENT(OUT), OPTIONAL :: fold_margin
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    REAL(wp), INTENT(IN), OPTIONAL :: couple(:)

    INTEGER :: order, nn, n, e, j, k, i0, i, jj, row0
    LOGICAL :: want_hess, finite
    REAL(wp) :: scale, margin, he, ge(12), hk(12, 12), v(3), chi, sum_h, eg(6), eh(3, 3, 2), ec(3, 3, 2)
    REAL(wp) :: om, g9(9), h9(9, 9), pj(3, 3), pk(3, 3), sd(3, 3), dmy
    CHARACTER(200) :: em

    theta_raw = CD_ZERO
    grad = CD_ZERO
    IF (PRESENT(end_grad)) end_grad = CD_ZERO
    IF (PRESENT(end_hess)) end_hess = CD_ZERO
    IF (PRESENT(end_cross)) end_cross = CD_ZERO
    IF (PRESENT(fold_margin)) fold_margin = CD_ZERO
    order = NG_DEFAULT
    IF (PRESENT(quadrature_order)) order = quadrature_order
    scale = CD_ONE
    IF (PRESENT(band_scale)) scale = band_scale
    want_hess = PRESENT(hband) .OR. PRESENT(end_hess) .OR. PRESENT(end_cross) .OR. keep

    CALL line_fold_check(q, Le, ends, order, 'CD_HermiteTorsion_Line', margin, ErrStat, ErrMsg, u)
    IF (ErrStat /= CD_HTORS_OK) RETURN
    n = SIZE(q)
    nn = n/6
    IF (SIZE(grad) /= n) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'CD_HermiteTorsion_Line: grad must have SIZE(q) entries'
      RETURN
    END IF
    IF (PRESENT(hband)) THEN
      IF (SIZE(hband, 1) < 2*CD_HTORS_KBAND + 1 .OR. SIZE(hband, 2) /= n) THEN
        ErrStat = CD_HTORS_BADINPUT
        ErrMsg = 'CD_HermiteTorsion_Line: hband must be at least (2*KBAND+1, SIZE(q))'
        RETURN
      END IF
    END IF
    IF (.NOT. CD_Is_Finite(scale)) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Line: non-finite band_scale'
      RETURN
    END IF
    IF (PRESENT(couple)) THEN
      IF (SIZE(couple) /= nn - 1) THEN
        ErrStat = CD_HTORS_BADINPUT
        ErrMsg = 'CD_HermiteTorsion_Line: couple must have one entry per element'
        RETURN
      END IF
      IF (.NOT. CD_All_Finite(couple)) THEN
        ErrStat = CD_HTORS_NONFINITE
        ErrMsg = 'CD_HermiteTorsion_Line: non-finite torque-tension coupling'
        RETURN
      END IF
    END IF

    row0 = CD_HTORS_KBAND + 1          ! diagonal row of the local band
    IF (want_hess) band(:, 1:n) = CD_ZERO
    CALL chain_vertices(q, ends, u)

    ! element holonomies
    sum_h = CD_ZERO
    DO e = 1, nn - 1
      i0 = 6*(e - 1)
      CALL element_holonomy(q(i0 + 1:i0 + 12), Le(e), order, want_hess, he, ge, hk, dmy, ErrStat, em)
      IF (ErrStat /= CD_HTORS_OK) THEN
        ErrMsg = 'CD_HermiteTorsion_Line: '//em
        grad = CD_ZERO
        RETURN
      END IF
      sum_h = sum_h + he
      grad(i0 + 1:i0 + 12) = grad(i0 + 1:i0 + 12) + ge
      IF (want_hess) THEN
        DO jj = 1, 12
          DO i = 1, 12
            band(row0 + i - jj, i0 + jj) = band(row0 + i - jj, i0 + jj) + hk(i, jj)
          END DO
        END DO
      END IF
      ! torque-tension coupling: the twist the element's stretch takes up, -(K/GJ)(l_e - Le)
      IF (PRESENT(couple)) THEN
        IF (ABS(couple(e)) > CD_ZERO) THEN
          CALL element_stretch(q(i0 + 1:i0 + 12), Le(e), order, want_hess, he, ge, hk)
          sum_h = sum_h - couple(e)*(he - Le(e))
          grad(i0 + 1:i0 + 12) = grad(i0 + 1:i0 + 12) - couple(e)*ge
          IF (want_hess) THEN
            DO jj = 1, 12
              DO i = 1, 12
                band(row0 + i - jj, i0 + jj) = band(row0 + i - jj, i0 + jj) - couple(e)*hk(i, jj)
              END DO
            END DO
          END IF
        END IF
      END IF
    END DO

    ! smallest-rotation chain: value by sequential composition
    v = ends(:, 2)
    DO j = 0, nn
      v = smallest_rotation(u(:, j), u(:, j + 1), v)
    END DO
    chi = ATAN2(DOT_PRODUCT(ends(:, 3), cross(ends(:, 4), v)), DOT_PRODUCT(ends(:, 4), v))
    theta_raw = sum_h + chi

    ! chain derivatives: local solid-angle terms with frozen poles, w.r.t. the raw unit vertices
    gu = CD_ZERO
    huu = CD_ZERO
    huv = CD_ZERO
    DO j = 0, nn
      pole(:, j) = u(:, j) + u(:, j + 1)
      pole(:, j) = pole(:, j)/NORM2(pole(:, j))
    END DO
    DO j = 0, nn                                   ! links: + Omega(p_j, u_j, u_j+1)
      CALL solid_angle(pole(:, j), u(:, j), u(:, j + 1), want_hess, om, g9, h9)
      gu(:, j) = gu(:, j) + g9(4:6)
      gu(:, j + 1) = gu(:, j + 1) + g9(7:9)
      IF (want_hess) THEN
        huu(:, :, j) = huu(:, :, j) + h9(4:6, 4:6)
        huu(:, :, j + 1) = huu(:, :, j + 1) + h9(7:9, 7:9)
        huv(:, :, j) = huv(:, :, j) + h9(4:6, 7:9)
      END IF
    END DO
    DO j = 1, nn                                   ! interior vertices: - Omega(p_j-1, p_j, u_j)
      CALL solid_angle(pole(:, j - 1), pole(:, j), u(:, j), want_hess, om, g9, h9)
      gu(:, j) = gu(:, j) - g9(7:9)
      IF (want_hess) huu(:, :, j) = huu(:, :, j) - h9(7:9, 7:9)
    END DO
    ! end vertices: gauge change to a pole at the frozen end director, plus the end-frame twist
    CALL solid_angle(ends(:, 1), pole(:, 0), u(:, 0), want_hess, om, g9, h9)
    gu(:, 0) = gu(:, 0) - g9(7:9)
    IF (want_hess) huu(:, :, 0) = huu(:, :, 0) - h9(7:9, 7:9)
    CALL solid_angle(pole(:, nn), ends(:, 3), u(:, nn + 1), want_hess, om, g9, h9)
    gu(:, nn + 1) = gu(:, nn + 1) - g9(7:9)
    IF (want_hess) huu(:, :, nn + 1) = huu(:, :, nn + 1) - h9(7:9, 7:9)

    ! chain to the node tangent handles m_k (u = m/|m|)
    DO k = 1, nn
      i0 = 6*(k - 1) + 3
      CALL normalisation_jacobian(q(i0 + 1:i0 + 3), pj)
      grad(i0 + 1:i0 + 3) = grad(i0 + 1:i0 + 3) + MATMUL(pj, gu(:, k))
      IF (want_hess) THEN
        sd = normalised_hessian(q(i0 + 1:i0 + 3), gu(:, k), huu(:, :, k))
        CALL add_block(band, row0, i0, i0, sd)
        IF (k < nn) THEN
          CALL normalisation_jacobian(q(i0 + 7:i0 + 9), pk)
          sd = MATMUL(pj, MATMUL(huv(:, :, k), pk))
          CALL add_block(band, row0, i0, i0 + 6, sd)
          sd = TRANSPOSE(sd)
          CALL add_block(band, row0, i0 + 6, i0, sd)
        END IF
      END IF
    END DO

    ! chain to the end-frame rotations: d(w) = exp(w) d, dd/dw = -S(d), second order 1/2 w x (w x d)
    eg = CD_ZERO
    eh = CD_ZERO
    ec = CD_ZERO
    eg(1:3) = cross(ends(:, 1), gu(:, 0)) + ends(:, 1)
    eg(4:6) = cross(ends(:, 3), gu(:, nn + 1)) - ends(:, 3)
    IF (want_hess) THEN
      eh(:, :, 1) = rotation_hessian(ends(:, 1), gu(:, 0), huu(:, :, 0))
      eh(:, :, 2) = rotation_hessian(ends(:, 3), gu(:, nn + 1), huu(:, :, nn + 1))
      CALL normalisation_jacobian(q(4:6), pj)
      sd = skew(ends(:, 1))
      ec(:, :, 1) = MATMUL(sd, MATMUL(huv(:, :, 0), pj))
      CALL normalisation_jacobian(q(n - 2:n), pk)
      sd = skew(ends(:, 3))
      ec(:, :, 2) = MATMUL(sd, MATMUL(TRANSPOSE(huv(:, :, nn)), pk))
    END IF

    finite = CD_Is_Finite(theta_raw) .AND. CD_All_Finite(grad) .AND. CD_All_Finite(eg)
    IF (want_hess) finite = finite .AND. CD_All_Finite(band(:, 1:n)) .AND. CD_All_Finite(RESHAPE(eh, [18])) &
                            .AND. CD_All_Finite(RESHAPE(ec, [18]))
    IF (.NOT. finite) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Line: non-finite twist or derivative'
      theta_raw = CD_ZERO
      grad = CD_ZERO
      RETURN
    END IF

    IF (PRESENT(hband)) THEN
      i0 = SIZE(hband, 1) - 2*CD_HTORS_KBAND - 1
      DO jj = 1, n
        DO i = MAX(1, jj - CD_HTORS_KBAND), MIN(n, jj + CD_HTORS_KBAND)
          hband(i0 + row0 + i - jj, jj) = hband(i0 + row0 + i - jj, jj) + scale*band(row0 + i - jj, jj)
        END DO
      END DO
    END IF
    IF (PRESENT(end_grad)) end_grad = eg
    IF (PRESENT(end_hess)) end_hess = eh
    IF (PRESENT(end_cross)) end_cross = ec
    IF (PRESENT(fold_margin)) fold_margin = margin
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE line_core

  ELEMENTAL REAL(wp) FUNCTION CD_HermiteTorsion_Unwrap(theta_raw, theta_prev) RESULT(theta)
    !! The 2 pi branch of theta_raw nearest to theta_prev: theta_raw + 2 pi round((prev - raw)/2 pi).
    !! Non-finite input returns theta_raw unchanged (the caller's finiteness check rejects it).
    REAL(wp), INTENT(IN) :: theta_raw, theta_prev
    theta = theta_raw
    IF (CD_Is_Finite(theta_raw) .AND. CD_Is_Finite(theta_prev)) &
      theta = theta_raw + TWO_PI*ANINT((theta_prev - theta_raw)/TWO_PI)
  END FUNCTION CD_HermiteTorsion_Unwrap

  PURE SUBROUTINE CD_HermiteTorsion_Accept(theta_prev, theta_raw, theta_new, ErrStat, ErrMsg, max_step)
    !! Unwrap a trial value against the previous accepted Theta and enforce the step limit
    !! |theta_new - theta_prev| <= max_step (default pi/2, a margin below the hard limit pi at
    !! which the nearest branch becomes ambiguous). On rejection theta_new = theta_prev and
    !! ErrStat = CD_HTORS_STEP: the caller must cut the step. Call it after every accepted
    !! Newton iterate and every accepted time step or load stage. It sees only the wrapped trial
    !! value, so it cannot tell a change of 3 pi/2 from one of -pi/2: callers also bound the
    !! linearised change dTheta/dq . dq of every trial step before taking it (to pi/4 in the
    !! static and dynamic Newton steps and the static descent perturbation).
    REAL(wp), INTENT(IN) :: theta_prev, theta_raw
    REAL(wp), INTENT(OUT) :: theta_new
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(IN), OPTIONAL :: max_step
    REAL(wp) :: limit

    limit = CD_HTORS_MAX_STEP
    IF (PRESENT(max_step)) limit = max_step
    theta_new = theta_prev
    IF (.NOT. (CD_Is_Finite(theta_prev) .AND. CD_Is_Finite(theta_raw) .AND. CD_Is_Finite(limit))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTorsion_Accept: non-finite twist value or step limit'
      RETURN
    END IF
    IF (limit <= CD_ZERO .OR. limit >= CD_HTORS_PI) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'CD_HermiteTorsion_Accept: step limit must lie in (0, pi)'
      RETURN
    END IF
    IF (ABS(CD_HermiteTorsion_Unwrap(theta_raw, theta_prev) - theta_prev) > limit) THEN
      ErrStat = CD_HTORS_STEP
      ErrMsg = 'CD_HermiteTorsion_Accept: twist change exceeds the step limit; cut the step'
      RETURN
    END IF
    theta_new = CD_HermiteTorsion_Unwrap(theta_raw, theta_prev)
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteTorsion_Accept

  ! ------------------------------------------------------------------------------------------
  ! nodal twist: reference twist of the time-parallel-transported directors
  ! ------------------------------------------------------------------------------------------

  PURE SUBROUTINE CD_HermiteTwist_Reference(qe, L, tri, tslot, tsign, value, grad, ErrStat, ErrMsg, hess, &
                                            holonomy, fixed_grad, quadrature_order)
    !! The reference twist of the nodal-twist model on one element [r1, m1, r2, m2] of reference
    !! length L: value = sum_k tsign_k Omega(x_k, y_k, z_k) - h_e (h_e, the element holonomy, only
    !! when holonomy, the default), with its gradient and optionally its Hessian over the 12 DOFs.
    !! Each triangle k takes its vertices from tri(:, j, k) where tslot(j, k) = 0 (a vector fixed
    !! over the step: a committed node tangent or an end director), the unit node-1 tangent
    !! b = m1/|m1| where tslot(j, k) = 1 and the unit node-2 tangent c = m2/|m2| where it is 2.
    !! A caller adds the step constant (the committed reference twist). fixed_grad(:, j, k) is the
    !! gradient in the raw fixed vertex tri(:, j, k) (zero for a node-tangent vertex).
    !!
    !! An interior element with committed unit tangents a, d and committed reference twist beta^n
    !! has the reference twist beta^n - Omega(a, b, c) - Omega(a, c, d) - h_e: its directors are the
    !! committed ones carried by the smallest rotation from a to b and from d to c, and the
    !! transport around the quadrilateral a, b, c, d turns a vector by its solid angle. A routine
    !! of a single node passes no node-2 vertex and holonomy = .FALSE.; then only qe(4:6) is read.
    !! Every triangle edge must satisfy 1 + x . y >= CD_HTORS_FOLD_MIN (else CD_HTORS_FOLD).
    REAL(wp), INTENT(IN) :: qe(12), L, tri(:, :, :), tsign(:)
    INTEGER, INTENT(IN) :: tslot(:, :)
    REAL(wp), INTENT(OUT) :: value, grad(12)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    REAL(wp), INTENT(OUT), OPTIONAL :: hess(12, 12), fixed_grad(:, :, :)
    LOGICAL, INTENT(IN), OPTIONAL :: holonomy
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    INTEGER :: order, k, j, i, ntri, si, sj
    LOGICAL :: want_hess, with_h, need(2), finite
    REAL(wp) :: node_t(3, 2), proj(3, 3, 2), x(3, 3), om, g9(9), h9(9, 9), gt(3, 2), htt(3, 3, 2, 2)
    REAL(wp) :: he, ge(12), hk(12, 12), dmy, blk(3, 3), blk2(3, 3)
    CHARACTER(200) :: em

    value = CD_ZERO
    grad = CD_ZERO
    IF (PRESENT(hess)) hess = CD_ZERO
    IF (PRESENT(fixed_grad)) fixed_grad = CD_ZERO
    want_hess = PRESENT(hess)
    with_h = .TRUE.
    IF (PRESENT(holonomy)) with_h = holonomy
    order = NG_DEFAULT
    IF (PRESENT(quadrature_order)) order = quadrature_order
    ntri = SIZE(tsign)
    ErrStat = CD_HTORS_BADINPUT
    IF (SIZE(tri, 1) /= 3 .OR. SIZE(tri, 2) /= 3 .OR. SIZE(tri, 3) /= ntri .OR. SIZE(tslot, 1) /= 3 .OR. &
        SIZE(tslot, 2) /= ntri) THEN
      ErrMsg = 'CD_HermiteTwist_Reference: tri(3, 3, n), tslot(3, n) and tsign(n) must agree'
      RETURN
    END IF
    IF (PRESENT(fixed_grad)) THEN
      IF (SIZE(fixed_grad, 1) /= 3 .OR. SIZE(fixed_grad, 2) /= 3 .OR. SIZE(fixed_grad, 3) /= ntri) THEN
        ErrMsg = 'CD_HermiteTwist_Reference: fixed_grad must be shaped as tri'
        RETURN
      END IF
    END IF
    IF (ANY(tslot < 0) .OR. ANY(tslot > 2)) THEN
      ErrMsg = 'CD_HermiteTwist_Reference: a vertex slot must be 0, 1 or 2'
      RETURN
    END IF
    IF (order < 1 .OR. order > NG_MAX) THEN
      ErrMsg = 'CD_HermiteTwist_Reference: quadrature order must lie in [1,6]'
      RETURN
    END IF
    need(1) = ANY(tslot == 1) .OR. with_h
    need(2) = ANY(tslot == 2) .OR. with_h
    ! (column by column: a reshaped copy of the assumed-shape tri would be a heap temporary)
    finite = CD_All_Finite(qe) .AND. CD_Is_Finite(L) .AND. CD_All_Finite(tsign)
    DO k = 1, ntri
      DO j = 1, 3
        finite = finite .AND. CD_All_Finite(tri(:, j, k))
      END DO
    END DO
    IF (.NOT. finite) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTwist_Reference: non-finite input'
      RETURN
    END IF
    IF (with_h .AND. L <= GEOM_TOL) THEN
      ErrMsg = 'CD_HermiteTwist_Reference: element length must be positive'
      RETURN
    END IF
    node_t = CD_ZERO
    proj = CD_ZERO
    DO j = 1, 2
      IF (.NOT. need(j)) CYCLE
      IF (NORM2(qe(6*j - 2:6*j)) <= GEOM_TOL) THEN
        ErrMsg = 'CD_HermiteTwist_Reference: zero tangent handle at a node'
        RETURN
      END IF
      node_t(:, j) = qe(6*j - 2:6*j)/NORM2(qe(6*j - 2:6*j))
      CALL normalisation_jacobian(qe(6*j - 2:6*j), proj(:, :, j))
    END DO
    DO k = 1, ntri
      DO j = 1, 3
        IF (tslot(j, k) == 0) THEN
          IF (ABS(NORM2(tri(:, j, k)) - CD_ONE) > FRAME_TOL) THEN
            ErrMsg = 'CD_HermiteTwist_Reference: a fixed triangle vertex must be a unit vector'
            RETURN
          END IF
        END IF
      END DO
    END DO

    gt = CD_ZERO
    htt = CD_ZERO
    DO k = 1, ntri
      DO j = 1, 3
        IF (tslot(j, k) == 0) THEN
          x(:, j) = tri(:, j, k)
        ELSE
          x(:, j) = node_t(:, tslot(j, k))
        END IF
      END DO
      DO j = 1, 3
        IF (CD_ONE + DOT_PRODUCT(x(:, j), x(:, MOD(j, 3) + 1)) < CD_HTORS_FOLD_MIN) THEN
          ErrStat = CD_HTORS_FOLD
          ErrMsg = 'CD_HermiteTwist_Reference: a director turned by more than 120 degrees in one step or element'
          RETURN
        END IF
      END DO
      CALL solid_angle(x(:, 1), x(:, 2), x(:, 3), want_hess, om, g9, h9)
      value = value + tsign(k)*om
      DO j = 1, 3
        si = tslot(j, k)
        IF (si == 0) THEN
          IF (PRESENT(fixed_grad)) fixed_grad(:, j, k) = tsign(k)*g9(3*j - 2:3*j)
          CYCLE
        END IF
        gt(:, si) = gt(:, si) + tsign(k)*g9(3*j - 2:3*j)
        IF (.NOT. want_hess) CYCLE
        DO i = 1, 3
          sj = tslot(i, k)
          IF (sj == 0) CYCLE
          htt(:, :, si, sj) = htt(:, :, si, sj) + tsign(k)*h9(3*j - 2:3*j, 3*i - 2:3*i)
        END DO
      END DO
    END DO
    ! chain to the tangent handles m1 (DOFs 4:6) and m2 (DOFs 10:12)
    DO j = 1, 2
      IF (.NOT. need(j)) CYCLE
      grad(6*j - 2:6*j) = MATMUL(proj(:, :, j), gt(:, j))
      IF (.NOT. want_hess) CYCLE
      ! (staged in 3 x 3 locals: a result into a run-time section, or a nested product, would
      ! take a heap temporary)
      blk2 = htt(:, :, j, j)
      blk = normalised_hessian(qe(6*j - 2:6*j), gt(:, j), blk2)
      hess(6*j - 2:6*j, 6*j - 2:6*j) = blk
    END DO
    IF (want_hess .AND. need(1) .AND. need(2)) THEN
      blk2 = MATMUL(htt(:, :, 1, 2), proj(:, :, 2))
      blk = MATMUL(proj(:, :, 1), blk2)
      hess(4:6, 10:12) = blk
      hess(10:12, 4:6) = TRANSPOSE(blk)
    END IF
    IF (with_h) THEN
      CALL element_holonomy(qe, L, order, want_hess, he, ge, hk, dmy, ErrStat, em)
      IF (ErrStat /= CD_HTORS_OK) THEN
        ErrMsg = 'CD_HermiteTwist_Reference: '//em
        value = CD_ZERO
        grad = CD_ZERO
        IF (PRESENT(hess)) hess = CD_ZERO
        IF (PRESENT(fixed_grad)) fixed_grad = CD_ZERO
        RETURN
      END IF
      value = value - he
      grad = grad - ge
      IF (want_hess) hess = hess - hk
    END IF
    IF (.NOT. (CD_Is_Finite(value) .AND. CD_All_Finite(grad))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = 'CD_HermiteTwist_Reference: non-finite twist or derivative'
      value = CD_ZERO
      grad = CD_ZERO
      RETURN
    END IF
    IF (want_hess) THEN
      finite = .TRUE.
      DO j = 1, 12
        finite = finite .AND. CD_All_Finite(hess(:, j))
      END DO
      IF (.NOT. finite) THEN
        ErrStat = CD_HTORS_NONFINITE
        ErrMsg = 'CD_HermiteTwist_Reference: non-finite twist Hessian'
        value = CD_ZERO
        grad = CD_ZERO
        hess = CD_ZERO
        RETURN
      END IF
    END IF
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE CD_HermiteTwist_Reference

  PURE FUNCTION CD_HermiteTwist_Carry(from, to, v) RESULT(r)
    !! The smallest rotation taking the unit vector from to the unit vector to, applied to v (the
    !! parallel transport of the nodal-twist directors; requires 1 + from . to > 0).
    REAL(wp), INTENT(IN) :: from(3), to(3), v(3)
    REAL(wp) :: r(3)
    r = smallest_rotation(from, to, v)
  END FUNCTION CD_HermiteTwist_Carry

  PURE REAL(wp) FUNCTION CD_HermiteTwist_Angle(x, y, axis) RESULT(ang)
    !! The angle in (-pi, pi] about axis, right-hand rule, from x to y (both perpendicular to it).
    REAL(wp), INTENT(IN) :: x(3), y(3), axis(3)
    ang = ATAN2(DOT_PRODUCT(axis, cross(x, y)), DOT_PRODUCT(x, y))
  END FUNCTION CD_HermiteTwist_Angle

  PURE REAL(wp) FUNCTION CD_HermiteTwist_Omega(x, y, z) RESULT(om)
    !! The signed solid angle of the geodesic triangle x, y, z of CD_HermiteTwist_Reference, on
    !! the same arithmetic: the value a triangle of fixed vertices takes inside that routine.
    REAL(wp), INTENT(IN) :: x(3), y(3), z(3)
    REAL(wp) :: g(9), h(9, 9)
    CALL solid_angle(x, y, z, .FALSE., om, g, h)
  END FUNCTION CD_HermiteTwist_Omega

  PURE SUBROUTINE CD_HermiteTwist_Omega_Gradient(x, y, z, om, g)
    !! CD_HermiteTwist_Omega with its gradient g = [dOmega/dx, dOmega/dy, dOmega/dz] in the raw
    !! vertex vectors.
    REAL(wp), INTENT(IN) :: x(3), y(3), z(3)
    REAL(wp), INTENT(OUT) :: om, g(9)
    REAL(wp) :: h(9, 9)
    CALL solid_angle(x, y, z, .FALSE., om, g, h)
  END SUBROUTINE CD_HermiteTwist_Omega_Gradient

  ! ------------------------------------------------------------------------------------------
  ! element holonomy
  ! ------------------------------------------------------------------------------------------

  PURE SUBROUTINE element_ab(qe, L, xi, a, b)
    !! a = dr/ds and b = d2r/ds2 of the cubic-Hermite element at xi in [0, 1].
    REAL(wp), INTENT(IN) :: qe(12), L, xi
    REAL(wp), INTENT(OUT) :: a(3), b(3)
    REAL(wp) :: dh(4), ddh(4)
    INTEGER :: i
    CALL shape_derivatives(L, xi, dh, ddh)
    a = CD_ZERO
    b = CD_ZERO
    DO i = 1, 4
      a = a + dh(i)*qe(3*i - 2:3*i)
      b = b + ddh(i)*qe(3*i - 2:3*i)
    END DO
  END SUBROUTINE element_ab

  PURE SUBROUTINE shape_derivatives(L, x, dh, ddh)
    !! d/ds and d2/ds2 of the Hermite shape functions [H1, L H2, H3, L H4] at xi = x.
    REAL(wp), INTENT(IN) :: L, x
    REAL(wp), INTENT(OUT) :: dh(4), ddh(4)
    dh = [-6.0_wp*x + 6.0_wp*x*x, L*(CD_ONE - 4.0_wp*x + 3.0_wp*x*x), 6.0_wp*x - 6.0_wp*x*x, &
          L*(-2.0_wp*x + 3.0_wp*x*x)]/L
    ddh = [-6.0_wp + 12.0_wp*x, L*(-4.0_wp + 6.0_wp*x), 6.0_wp - 12.0_wp*x, L*(-2.0_wp + 6.0_wp*x)]/(L*L)
  END SUBROUTINE shape_derivatives

  PURE REAL(wp) FUNCTION CD_HermiteTorsion_Coupling_Twist(q, Le, couple, quadrature_order) RESULT(tw)
    !! The coupling part of the effective twist, -sum_e (K/GJ)_e (l_e - Le_e) [rad]: unlike the
    !! holonomy it has no 2 pi ambiguity, so a first evaluation unwraps the holonomy alone about
    !! its branch hint by passing the hint plus this to CD_HermiteTorsion_Unwrap.
    REAL(wp), INTENT(IN) :: q(:), Le(:), couple(:)
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    INTEGER :: e
    tw = CD_ZERO
    DO e = 1, MIN(SIZE(Le), SIZE(couple), SIZE(q)/6 - 1)
      IF (.NOT. ABS(couple(e)) > CD_ZERO) CYCLE
      tw = tw - couple(e)*(CD_HermiteTorsion_Element_Stretch(q(6*e - 5:6*e + 6), Le(e), quadrature_order) - Le(e))
    END DO
  END FUNCTION CD_HermiteTorsion_Coupling_Twist

  PURE REAL(wp) FUNCTION CD_HermiteTorsion_Element_Stretch(qe, L, quadrature_order) RESULT(ls)
    !! The stretched length of one cubic-Hermite element [r1, m1, r2, m2] of reference length L,
    !! on the quadrature of the torsion kernel (the l_e of the torque-tension coupling).
    REAL(wp), INTENT(IN) :: qe(12), L
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    REAL(wp) :: g(12), h(12, 12)
    INTEGER :: order
    order = NG_DEFAULT
    IF (PRESENT(quadrature_order)) order = quadrature_order
    CALL element_stretch(qe, L, order, .FALSE., ls, g, h)
  END FUNCTION CD_HermiteTorsion_Element_Stretch

  PURE SUBROUTINE CD_HermiteTorsion_Stretch_Derivatives(qe, L, ls, grad, hess, quadrature_order)
    !! CD_HermiteTorsion_Element_Stretch with its gradient and Hessian over the 12 DOFs.
    REAL(wp), INTENT(IN) :: qe(12), L
    REAL(wp), INTENT(OUT) :: ls, grad(12), hess(12, 12)
    INTEGER, INTENT(IN), OPTIONAL :: quadrature_order
    INTEGER :: order
    order = NG_DEFAULT
    IF (PRESENT(quadrature_order)) order = quadrature_order
    CALL element_stretch(qe, L, order, .TRUE., ls, grad, hess)
  END SUBROUTINE CD_HermiteTorsion_Stretch_Derivatives

  PURE SUBROUTINE element_stretch(qe, L, order, want_hess, ls, grad, hess)
    !! The stretched length l_e = L sum_g w_g |a_g| of one cubic-Hermite element (a = dr/ds), its
    !! gradient L sum_g w_g dh_i a/|a| and Hessian L sum_g w_g dh_i dh_j (I - t t^T)/|a| over the
    !! 12 DOFs [r1, m1, r2, m2].
    REAL(wp), INTENT(IN) :: qe(12), L
    INTEGER, INTENT(IN) :: order
    LOGICAL, INTENT(IN) :: want_hess
    REAL(wp), INTENT(OUT) :: ls, grad(12), hess(12, 12)
    REAL(wp) :: gp(NG_MAX), gw(NG_MAX), dh(4), ddh(4), a(3), b(3), sa, t(3), pmat(3, 3)
    INTEGER :: ig, i, j
    ls = CD_ZERO
    grad = CD_ZERO
    hess = CD_ZERO
    CALL CD_HermiteCable_Gauss_Rule(order, gp, gw)
    DO ig = 1, order
      CALL element_ab(qe, L, gp(ig), a, b)
      CALL shape_derivatives(L, gp(ig), dh, ddh)
      sa = NORM2(a)
      IF (.NOT. (sa > GEOM_TOL)) CYCLE
      t = a/sa
      ls = ls + L*gw(ig)*sa
      DO i = 1, 4
        grad(3*i - 2:3*i) = grad(3*i - 2:3*i) + L*gw(ig)*dh(i)*t
      END DO
      IF (want_hess) THEN
        pmat = (identity3() - outer(t, t))/sa
        DO j = 1, 4
          DO i = 1, 4
            hess(3*i - 2:3*i, 3*j - 2:3*j) = hess(3*i - 2:3*i, 3*j - 2:3*j) + L*gw(ig)*dh(i)*dh(j)*pmat
          END DO
        END DO
      END IF
    END DO
  END SUBROUTINE element_stretch

  PURE SUBROUTINE element_holonomy(qe, L, order, want_hess, h, grad, hess, margin, ErrStat, ErrMsg)
    !! h_e = L sum_g w_g f(a_g, b_g, t1), f = t1.(a x b) / (|a|**2 + |a| (t1.a)), t1 = m1/|m1|.
    !! f = N/D is differentiated in closed form in x = (a, b, t1) and chained to the 12 DOFs by
    !! the constant maps a, b = sum_i dh_i q_i, sum_i ddh_i q_i and by t1 = m1/|m1|.
    REAL(wp), INTENT(IN) :: qe(12), L
    INTEGER, INTENT(IN) :: order
    LOGICAL, INTENT(IN) :: want_hess
    REAL(wp), INTENT(OUT) :: h, grad(12), hess(12, 12), margin
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: gp(NG_MAX), gw(NG_MAX), dh(4), ddh(4), m1(3), rho, t(3), a(3), b(3), s2, sp, ta
    REAL(wp) :: num, den, f, gn(9), gd(9), hn(9, 9), hd(9, 9), gf(9), hf(9, 9), w, eye(3, 3)
    REAL(wp) :: gt(3), htt(3, 3), xat(3, 3, 4), pm(3, 3), blk(3, 3)
    INTEGER :: ig, i, j

    h = CD_ZERO
    grad = CD_ZERO
    hess = CD_ZERO
    margin = CD_ZERO
    m1 = qe(4:6)
    rho = NORM2(m1)
    IF (rho <= GEOM_TOL) THEN
      ErrStat = CD_HTORS_BADINPUT
      ErrMsg = 'element holonomy: zero tangent handle at the first node'
      RETURN
    END IF
    t = m1/rho
    eye = identity3()
    gt = CD_ZERO
    htt = CD_ZERO
    xat = CD_ZERO
    margin = HUGE(CD_ONE)
    CALL CD_HermiteCable_Gauss_Rule(order, gp, gw)
    DO ig = 1, order
      CALL shape_derivatives(L, gp(ig), dh, ddh)
      CALL element_ab(qe, L, gp(ig), a, b)
      s2 = DOT_PRODUCT(a, a)
      sp = SQRT(s2)
      IF (sp <= GEOM_TOL) THEN
        ErrStat = CD_HTORS_BADINPUT
        ErrMsg = 'element holonomy: zero centreline tangent at a Gauss point'
        RETURN
      END IF
      ta = DOT_PRODUCT(t, a)
      margin = MIN(margin, CD_ONE + ta/sp)
      IF (CD_ONE + ta/sp < CD_HTORS_FOLD_MIN) THEN
        ErrStat = CD_HTORS_FOLD
        ErrMsg = 'element holonomy: tangent turns by more than 120 degrees inside the element (1 + t1.t < 0.5)'
        RETURN
      END IF
      num = DOT_PRODUCT(t, cross(a, b))
      den = s2 + sp*ta
      f = num/den
      w = L*gw(ig)
      h = h + w*f
      gn(1:3) = cross(b, t)
      gn(4:6) = cross(t, a)
      gn(7:9) = cross(a, b)
      gd(1:3) = 2.0_wp*a + (ta/sp)*a + sp*t
      gd(4:6) = CD_ZERO
      gd(7:9) = sp*a
      gf = (gn - f*gd)/den
      DO i = 1, 4
        grad(3*i - 2:3*i) = grad(3*i - 2:3*i) + w*(dh(i)*gf(1:3) + ddh(i)*gf(4:6))
      END DO
      gt = gt + w*gf(7:9)
      IF (.NOT. want_hess) CYCLE
      hn = CD_ZERO
      hn(1:3, 4:6) = -skew(t)
      hn(4:6, 1:3) = skew(t)
      hn(4:6, 7:9) = -skew(a)
      hn(7:9, 4:6) = skew(a)
      hn(7:9, 1:3) = -skew(b)
      hn(1:3, 7:9) = skew(b)
      hd = CD_ZERO
      hd(1:3, 1:3) = 2.0_wp*eye + ta*(eye/sp - outer(a, a)/(sp*s2)) + (outer(a, t) + outer(t, a))/sp
      hd(1:3, 7:9) = outer(a, a)/sp + sp*eye
      hd(7:9, 1:3) = TRANSPOSE(hd(1:3, 7:9))
      hf = (hn - f*hd - outer9(gf, gd) - outer9(gd, gf))/den
      DO j = 1, 4
        DO i = 1, 4
          blk = dh(i)*dh(j)*hf(1:3, 1:3) + dh(i)*ddh(j)*hf(1:3, 4:6) + ddh(i)*dh(j)*hf(4:6, 1:3) &
                + ddh(i)*ddh(j)*hf(4:6, 4:6)
          hess(3*i - 2:3*i, 3*j - 2:3*j) = hess(3*i - 2:3*i, 3*j - 2:3*j) + w*blk
        END DO
        xat(:, :, j) = xat(:, :, j) + w*(dh(j)*hf(1:3, 7:9) + ddh(j)*hf(4:6, 7:9))
      END DO
      htt = htt + w*hf(7:9, 7:9)
    END DO
    ! chain through t1 = m1/|m1| (DOF block 2)
    CALL normalisation_jacobian(m1, pm)
    grad(4:6) = grad(4:6) + MATMUL(pm, gt)
    IF (want_hess) THEN
      DO i = 1, 4
        blk = MATMUL(xat(:, :, i), pm)
        hess(3*i - 2:3*i, 4:6) = hess(3*i - 2:3*i, 4:6) + blk
        hess(4:6, 3*i - 2:3*i) = hess(4:6, 3*i - 2:3*i) + TRANSPOSE(blk)
      END DO
      hess(4:6, 4:6) = hess(4:6, 4:6) + normalised_hessian(m1, gt, htt)
    END IF
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE element_holonomy

  ! ------------------------------------------------------------------------------------------
  ! chain helpers
  ! ------------------------------------------------------------------------------------------

  PURE SUBROUTINE validate_line(q, Le, ends, order, who, ErrStat, ErrMsg)
    REAL(wp), INTENT(IN) :: q(:), Le(:), ends(3, 4)
    INTEGER, INTENT(IN) :: order
    CHARACTER(*), INTENT(IN) :: who
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: nn, k

    ErrStat = CD_HTORS_BADINPUT
    IF (order < 1 .OR. order > NG_MAX) THEN
      ErrMsg = who//': quadrature order must lie in [1,6]'
      RETURN
    END IF
    nn = SIZE(q)/6
    IF (MOD(SIZE(q), 6) /= 0 .OR. nn < 2 .OR. SIZE(Le) /= nn - 1) THEN
      ErrMsg = who//': q must hold 6 DOFs for each of n >= 2 nodes and Le n - 1 lengths'
      RETURN
    END IF
    IF (.NOT. (CD_All_Finite(q) .AND. CD_All_Finite(Le) .AND. CD_All_Finite(ends))) THEN
      ErrStat = CD_HTORS_NONFINITE
      ErrMsg = who//': non-finite DOFs, lengths or end frames'
      RETURN
    END IF
    IF (ANY(Le <= GEOM_TOL)) THEN
      ErrMsg = who//': element lengths must be positive'
      RETURN
    END IF
    DO k = 1, nn
      IF (NORM2(q(6*k - 2:6*k)) <= GEOM_TOL) THEN
        ErrMsg = who//': zero tangent handle m at a node'
        RETURN
      END IF
    END DO
    DO k = 1, 3, 2
      IF (ABS(NORM2(ends(:, k)) - CD_ONE) > FRAME_TOL .OR. ABS(NORM2(ends(:, k + 1)) - CD_ONE) > FRAME_TOL &
          .OR. ABS(DOT_PRODUCT(ends(:, k), ends(:, k + 1))) > FRAME_TOL) THEN
        IF (k == 1) THEN
          ErrMsg = who//': End-A director and reference normal must be orthonormal'
        ELSE
          ErrMsg = who//': End-B director and reference normal must be orthonormal'
        END IF
        RETURN
      END IF
    END DO
    ErrStat = CD_HTORS_OK
    ErrMsg = ''
  END SUBROUTINE validate_line

  PURE SUBROUTINE chain_vertices(q, ends, u)
    !! u(:, 0) = d_A, u(:, k) = m_k/|m_k| (k = 1..n), u(:, n+1) = d_B.
    REAL(wp), INTENT(IN) :: q(:), ends(3, 4)
    REAL(wp), INTENT(OUT) :: u(:, 0:)
    INTEGER :: nn, k
    nn = SIZE(q)/6
    u(:, 0) = ends(:, 1)
    DO k = 1, nn
      u(:, k) = q(6*k - 2:6*k)/NORM2(q(6*k - 2:6*k))
    END DO
    u(:, nn + 1) = ends(:, 3)
  END SUBROUTINE chain_vertices

  PURE FUNCTION smallest_rotation(a, b, v) RESULT(r)
    !! Smallest rotation taking unit a to unit b, applied to v (requires 1 + a.b > 0).
    REAL(wp), INTENT(IN) :: a(3), b(3), v(3)
    REAL(wp) :: r(3), c, w(3)
    c = DOT_PRODUCT(a, b)
    w = cross(a, b)
    r = c*v + cross(w, v) + w*DOT_PRODUCT(w, v)/(CD_ONE + c)
  END FUNCTION smallest_rotation

  PURE SUBROUTINE solid_angle(x, y, z, want_hess, om, g, h)
    !! Omega = 2 atan2(N, D), N = x.(y x z), D = 1 + x.y + y.z + z.x (signed solid angle of the
    !! geodesic triangle x, y, z), with gradient g and Hessian h in the raw vectors (x, y, z).
    !! Under the fold guard every triangle used here has D >= 1.5.
    REAL(wp), INTENT(IN) :: x(3), y(3), z(3)
    LOGICAL, INTENT(IN) :: want_hess
    REAL(wp), INTENT(OUT) :: om, g(9), h(9, 9)
    REAL(wp) :: nv, dv, r2, gn(9), gd(9), eye(3, 3)

    nv = DOT_PRODUCT(x, cross(y, z))
    dv = CD_ONE + DOT_PRODUCT(x, y) + DOT_PRODUCT(y, z) + DOT_PRODUCT(z, x)
    om = 2.0_wp*ATAN2(nv, dv)
    gn(1:3) = cross(y, z)
    gn(4:6) = cross(z, x)
    gn(7:9) = cross(x, y)
    gd(1:3) = y + z
    gd(4:6) = x + z
    gd(7:9) = x + y
    r2 = nv*nv + dv*dv
    g = 2.0_wp*(dv*gn - nv*gd)/r2
    h = CD_ZERO
    IF (.NOT. want_hess) RETURN
    eye = identity3()
    ! d2N: (x,y) = -S(z), (y,z) = -S(x), (z,x) = -S(y); d2D: identity off-diagonal blocks
    h(1:3, 4:6) = -dv*skew(z) - nv*eye
    h(4:6, 1:3) = dv*skew(z) - nv*eye
    h(4:6, 7:9) = -dv*skew(x) - nv*eye
    h(7:9, 4:6) = dv*skew(x) - nv*eye
    h(7:9, 1:3) = -dv*skew(y) - nv*eye
    h(1:3, 7:9) = dv*skew(y) - nv*eye
    h = 2.0_wp*(h/r2 + ((nv*nv - dv*dv)*(outer9(gn, gd) + outer9(gd, gn)) &
                        - 2.0_wp*dv*nv*(outer9(gn, gn) - outer9(gd, gd)))/(r2*r2))
  END SUBROUTINE solid_angle

  PURE SUBROUTINE normalisation_jacobian(m, p)
    !! d(m/|m|)/dm = (I - t t^T)/|m|.
    REAL(wp), INTENT(IN) :: m(3)
    REAL(wp), INTENT(OUT) :: p(3, 3)
    REAL(wp) :: rho, t(3)
    rho = NORM2(m)
    t = m/rho
    p = (identity3() - outer(t, t))/rho
  END SUBROUTINE normalisation_jacobian

  PURE FUNCTION normalised_hessian(m, g, h) RESULT(hm)
    !! Hessian in m of F(t), t = m/|m|, from g = dF/dt and h = d2F/dt2:
    !! P h P - (g t^T + t g^T + (g.t)(I - 3 t t^T))/|m|**2,  P = (I - t t^T)/|m|.
    REAL(wp), INTENT(IN) :: m(3), g(3), h(3, 3)
    REAL(wp) :: hm(3, 3), p(3, 3), rho, t(3), gt
    rho = NORM2(m)
    t = m/rho
    CALL normalisation_jacobian(m, p)
    gt = DOT_PRODUCT(g, t)
    hm = MATMUL(p, MATMUL(h, p)) - (outer(g, t) + outer(t, g) + gt*(identity3() - 3.0_wp*outer(t, t)))/(rho*rho)
  END FUNCTION normalised_hessian

  PURE FUNCTION rotation_hessian(d, g, h) RESULT(hw)
    !! Hessian in w at w = 0 of F(exp(w) d), from g = dF/dd and h = d2F/dd2:
    !! -S(d) h S(d) + (g d^T + d g^T)/2 - (g.d) I.
    REAL(wp), INTENT(IN) :: d(3), g(3), h(3, 3)
    REAL(wp) :: hw(3, 3), sd(3, 3)
    sd = skew(d)
    hw = -MATMUL(sd, MATMUL(h, sd)) + 0.5_wp*(outer(g, d) + outer(d, g)) - DOT_PRODUCT(g, d)*identity3()
  END FUNCTION rotation_hessian

  PURE SUBROUTINE add_block(band, row0, i0, j0, blk)
    !! Add a 3x3 block at global rows i0+1..i0+3, columns j0+1..j0+3 (local band, diagonal row0).
    REAL(wp), INTENT(INOUT) :: band(:, :)
    INTEGER, INTENT(IN) :: row0, i0, j0
    REAL(wp), INTENT(IN) :: blk(3, 3)
    INTEGER :: i, j
    DO j = 1, 3
      DO i = 1, 3
        band(row0 + i0 + i - j0 - j, j0 + j) = band(row0 + i0 + i - j0 - j, j0 + j) + blk(i, j)
      END DO
    END DO
  END SUBROUTINE add_block

  ! ------------------------------------------------------------------------------------------
  ! small vector helpers
  ! ------------------------------------------------------------------------------------------

  PURE FUNCTION cross(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION cross

  PURE FUNCTION skew(v) RESULT(s)
    !! S(v) w = v x w.
    REAL(wp), INTENT(IN) :: v(3)
    REAL(wp) :: s(3, 3)
    s = RESHAPE([CD_ZERO, v(3), -v(2), -v(3), CD_ZERO, v(1), v(2), -v(1), CD_ZERO], [3, 3])
  END FUNCTION skew

  PURE FUNCTION outer(a, b) RESULT(m)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: m(3, 3)
    m = SPREAD(a, 2, 3)*SPREAD(b, 1, 3)
  END FUNCTION outer

  PURE FUNCTION outer9(a, b) RESULT(m)
    REAL(wp), INTENT(IN) :: a(9), b(9)
    REAL(wp) :: m(9, 9)
    m = SPREAD(a, 2, 9)*SPREAD(b, 1, 9)
  END FUNCTION outer9

  PURE FUNCTION identity3() RESULT(m)
    REAL(wp) :: m(3, 3)
    m = RESHAPE([CD_ONE, CD_ZERO, CD_ZERO, CD_ZERO, CD_ONE, CD_ZERO, CD_ZERO, CD_ZERO, CD_ONE], [3, 3])
  END FUNCTION identity3

END MODULE CableDyn_HermiteTorsion
