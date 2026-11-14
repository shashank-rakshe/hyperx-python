! File: tests/test_hermite_torsion_static.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_torsion_static
  !! Gates of the condensed-torsion static solve (CD_HermiteCable_Static_Solve with torsion):
  !!   T  pure torsion of a straight multi-section rod (with and without torsional end springs):
  !!      torque = Phi / C to round-off, centreline unchanged;
  !!   G  clamped-clamped Greenhill onset (sliding end, dead tension T) from the stability
  !!      report, bisected on the imposed twist: N = 32 within 1e-4 of van der Heijden et al.
  !!      (2003) eq. (33) for T L^2/EI in {-20, 0, 10, 50, 200}, observed order of the N = 8,
  !!      16, 32 sequence;
  !!   P  bending-pinned, torsion-restrained ends (semi-tangential, constant-velocity joint):
  !!      4.9112877 and 7.2692742 EI/L at T L^2/EI = 0 and 10;
  !!   B  above the onset the straight saddle is reported unstable, and the descent reaches a
  !!      stable buckled state of lower energy with a relaxed torque; below it the straight
  !!      state is stable;
  !!   M  more than two turns of imposed twist through the continuation: the torque law, the
  !!      Theta continuity between successive solves and agreement with a single solve;
  !!   F  fail-closed inputs (missing GJ, a director off the rigid direction, a rejected
  !!      solver mode or tangent output);
  !!   R  a re-solve from a stored Theta: within pi/2 it continues, beyond it stops by name.
  !! Argument 1: tests/data/torsion_analytic_refs.txt.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK, CD_HCSTAT_BADINPUT
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HTORS_PI
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_PINNED, CD_ENDCONN_RIGID
  IMPLICIT NONE

  INTEGER :: nfail = 0
  CHARACTER(512) :: ref_path
  REAL(wp) :: ref_clamped(5, 2), ref_pinned(2, 2)

  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'usage: test_hermite_torsion_static <torsion_analytic_refs.txt>'
    ERROR STOP 2
  END IF
  CALL GET_COMMAND_ARGUMENT(1, ref_path)
  CALL read_refs()

  CALL check_pure_torsion()
  CALL check_greenhill_clamped()
  CALL check_greenhill_pinned()
  CALL check_post_buckling()
  CALL check_multi_turn()
  CALL check_fail_closed()
  CALL check_resolve()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' torsion statics assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: condensed-torsion statics (pure torsion, Greenhill onsets, post-buckling, multi-turn)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(ok, label)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. ok) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: '//label
    END IF
  END SUBROUTINE require

  SUBROUTINE read_refs()
    !! "clamped T M_cr" (five rows) and "pinned T M_cr" (two rows), EI = L = 1.
    INTEGER :: u, ios, nc, np
    CHARACTER(256) :: line
    CHARACTER(16) :: tag
    REAL(wp) :: t, m
    nc = 0
    np = 0
    OPEN (NEWUNIT=u, FILE=ref_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'cannot open '//TRIM(ref_path)
      ERROR STOP 2
    END IF
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (LEN_TRIM(line) == 0 .OR. line(1:1) == '#') CYCLE
      READ (line, *, IOSTAT=ios) tag, t, m
      IF (ios /= 0) CYCLE
      IF (TRIM(tag) == 'clamped' .AND. nc < 5) THEN
        nc = nc + 1
        ref_clamped(nc, :) = [t, m]
      ELSE IF (TRIM(tag) == 'pinned' .AND. np < 2) THEN
        np = np + 1
        ref_pinned(np, :) = [t, m]
      END IF
    END DO
    CLOSE (u)
    IF (nc /= 5 .OR. np /= 2) THEN
      WRITE (*, '(A)') 'reference file incomplete: '//TRIM(ref_path)
      ERROR STOP 2
    END IF
  END SUBROUTINE read_refs

  ! ------------------------------------------------------------------------------------------
  ! a straight rod along +x, node 1 held, the last node sliding along x under a dead tension
  ! ------------------------------------------------------------------------------------------

  SUBROUTINE straight_rod(ne, length, seed, l0)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(IN) :: length
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: seed(:), l0(:)
    INTEGER :: k
    ALLOCATE (seed(6*(ne + 1)), l0(ne))
    l0 = length/ne
    seed = 0.0_wp
    DO k = 0, ne
      seed(6*k + 1) = length*k/ne
      seed(6*k + 4) = 1.0_wp
    END DO
  END SUBROUTINE straight_rod

  SUBROUTINE straight_torsion(ne, gj, phi, tors)
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(IN) :: gj, phi
    TYPE(CD_HermiteTorsionType), INTENT(OUT) :: tors
    tors%active = .TRUE.
    ALLOCATE (tors%gj(ne))
    tors%gj = gj
    tors%phi = phi
    tors%ends(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
    tors%ends(:, 2) = [0.0_wp, 0.0_wp, 1.0_wp]
    tors%ends(:, 3) = [1.0_wp, 0.0_wp, 0.0_wp]
    tors%ends(:, 4) = [0.0_wp, 0.0_wp, 1.0_wp]
  END SUBROUTINE straight_torsion

  SUBROUTINE solve_rod(ne, ea, ei, tension, mode, tors, q, es, em, wline)
    !! Weightless (or w = wline) straight rod, ends in connection mode `mode` (both), node 1
    !! held, last node free along x with the dead load `tension`.
    INTEGER, INTENT(IN) :: ne, mode
    REAL(wp), INTENT(IN) :: ea, ei, tension
    TYPE(CD_HermiteTorsionType), INTENT(INOUT) :: tors
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q(:)
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp), INTENT(IN), OPTIONAL :: wline
    REAL(wp), ALLOCATABLE :: seed(:), l0(:), f(:), curv(:), wv(:)
    REAL(wp) :: res
    INTEGER :: nd, it
    CALL straight_rod(ne, 1.0_wp, seed, l0)
    nd = SIZE(seed)
    ALLOCATE (f(nd), q(nd), curv(ne + 1), wv(ne))
    wv = 0.0_wp
    IF (PRESENT(wline)) wv = wline
    f = 0.0_wp
    f(nd - 5) = tension
    CALL CD_HermiteCable_Static_Solve(l0, [(ea, it=1, ne)], [(ei, it=1, ne)], wv, seed, [1, 2, 3, nd - 4, nd - 3], &
                                      -1.0e6_wp, 0.0_wp, 1, 60, 1.0e-7_wp, 1.0_wp, q, curv, res, it, es, em, &
                                      f_nodal=f, endconn_stiffness=[0.0_wp, 0.0_wp], &
                                      endconn_direction=RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                [3, 2]), &
                                      endconn_mode=[mode, mode], torsion=tors)
  END SUBROUTINE solve_rod

  REAL(wp) FUNCTION onset(ne, tension, mode, mguess) RESULT(mcr)
    !! Critical torque (EI = L = GJ = 1, so M = Phi on the straight state) bisected on the
    !! stability report of the straight state (no descent), bracketed around mguess.
    INTEGER, INTENT(IN) :: ne, mode
    REAL(wp), INTENT(IN) :: tension, mguess
    REAL(wp) :: lo, hi, mid
    INTEGER :: k
    LOGICAL :: st, failed
    lo = 0.8_wp*mguess
    hi = 1.2_wp*mguess
    mcr = -1.0_wp
    IF (.NOT. stable_at(ne, tension, mode, lo, failed)) RETURN
    IF (stable_at(ne, tension, mode, hi, failed)) RETURN
    DO k = 1, 60
      mid = 0.5_wp*(lo + hi)
      st = stable_at(ne, tension, mode, mid, failed)
      IF (failed) RETURN
      IF (st) THEN
        lo = mid
      ELSE
        hi = mid
      END IF
      IF (hi - lo <= 1.0e-9_wp*mguess) EXIT
    END DO
    mcr = 0.5_wp*(lo + hi)
  END FUNCTION onset

  LOGICAL FUNCTION stable_at(ne, tension, mode, m, failed) RESULT(stab)
    INTEGER, INTENT(IN) :: ne, mode
    REAL(wp), INTENT(IN) :: tension, m
    LOGICAL, INTENT(OUT) :: failed
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp), ALLOCATABLE :: q(:)
    INTEGER :: es
    CHARACTER(512) :: em
    CALL straight_torsion(ne, 1.0_wp, m, tors)
    tors%descend = .FALSE.
    CALL solve_rod(ne, 1.0e7_wp, 1.0_wp, tension, mode, tors, q, es, em)
    failed = es /= CD_HCSTAT_OK
    IF (failed) WRITE (*, '(A)') '  solve failed: '//TRIM(em)
    stab = tors%stable .AND. .NOT. failed
  END FUNCTION stable_at

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_pure_torsion()
    !! 10 x 0.2 m, GJ alternating 1e4 / 2.5e4, EI 1e6 (far below its Greenhill onset), clamped
    !! straight ends; Phi = 0.5, 2.5, 10 rad. M_t = Phi / C exactly; with torsional end springs
    !! k = 1e4 at both ends C gains 2e-4.
    REAL(wp), PARAMETER :: PHIS(3) = [0.5_wp, 2.5_wp, 10.0_wp]
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp), ALLOCATABLE :: seed(:), l0(:), q(:), curv(:), f(:)
    REAL(wp) :: res, c, err, drift
    INTEGER :: ip, isp, it, es, nd, e
    CHARACTER(512) :: em
    CALL straight_rod(10, 2.0_wp, seed, l0)
    nd = SIZE(seed)
    ALLOCATE (q(nd), curv(11), f(nd))
    f = 0.0_wp
    f(nd - 5) = 100.0_wp
    DO isp = 0, 1
      DO ip = 1, 3
        tors = CD_HermiteTorsionType()
        tors%active = .TRUE.
        ALLOCATE (tors%gj(10))
        DO e = 1, 10
          tors%gj(e) = MERGE(1.0e4_wp, 2.5e4_wp, MOD(e, 2) == 1)
        END DO
        IF (isp == 1) tors%end_compliance = 1.0e-4_wp
        tors%phi = PHIS(ip)
        tors%ends(:, 1) = [1.0_wp, 0.0_wp, 0.0_wp]
        tors%ends(:, 2) = [0.0_wp, 1.0_wp, 0.0_wp]
        tors%ends(:, 3) = [1.0_wp, 0.0_wp, 0.0_wp]
        tors%ends(:, 4) = [0.0_wp, 1.0_wp, 0.0_wp]
        CALL CD_HermiteCable_Static_Solve(l0, [(1.0e9_wp, it=1, 10)], [(1.0e6_wp, it=1, 10)], [(0.0_wp, it=1, 10)], &
                                          seed, [1, 2, 3, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 1, 60, 1.0e-7_wp, &
                                          1.0_wp, q, curv, res, it, es, em, f_nodal=f, &
                                          endconn_stiffness=[0.0_wp, 0.0_wp], &
                                          endconn_direction=RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                    [3, 2]), &
                                          endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=tors)
        CALL require(es == CD_HCSTAT_OK, 'T: pure torsion solve converges: '//TRIM(em))
        c = 5.0_wp*0.2_wp/1.0e4_wp + 5.0_wp*0.2_wp/2.5e4_wp + 2.0_wp*isp*1.0e-4_wp
        err = ABS(tors%torque - PHIS(ip)/c)/(PHIS(ip)/c)
        drift = nan_max_abs([nan_max_abs(q(2::6)), nan_max_abs(q(3::6)), nan_max_abs(q(5::6)), &
                             nan_max_abs(q(6::6))])/2.0_wp
        WRITE (*, '(A,I0,A,F5.1,A,ES12.5,A,ES9.2,A,ES9.2)') 'pure torsion (springs ', isp, ') Phi=', PHIS(ip), &
          ' rad: M_t=', tors%torque, ' N m, rel. error ', err, ', lateral drift/L ', drift
        CALL require(err <= 1.0e-12_wp, 'T: M_t = Phi/C to round-off')
        CALL require(drift <= 1.0e-12_wp, 'T: the straight centreline stays straight')
        CALL require(ABS(tors%theta) <= 1.0e-12_wp, 'T: Theta = 0 on the straight rod')
        CALL require(tors%stable, 'T: the twisted straight rod is stable below its onset')
      END DO
    END DO
  END SUBROUTINE check_pure_torsion

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_greenhill_clamped()
    INTEGER, PARAMETER :: NES(3) = [8, 16, 32]
    REAL(wp) :: m(3), err(3), order
    INTEGER :: it, k
    DO it = 1, 5
      DO k = 1, 3
        m(k) = onset(NES(k), ref_clamped(it, 1), CD_ENDCONN_RIGID, ref_clamped(it, 2))
        err(k) = ABS(m(k) - ref_clamped(it, 2))/ref_clamped(it, 2)
      END DO
      order = LOG(ABS(m(1) - ref_clamped(it, 2))/MAX(ABS(m(2) - ref_clamped(it, 2)), TINY(1.0_wp)))/LOG(2.0_wp)
      WRITE (*, '(A,F7.1,A,3F12.7,A,F11.8,A,ES9.2,A,F5.2)') 'Greenhill clamped T L^2/EI=', ref_clamped(it, 1), &
        ': M_cr L/EI (N=8,16,32) =', m, ' ref ', ref_clamped(it, 2), ' rel.err(N=32) ', err(3), ' order ', order
      CALL require(ALL(m > 0.0_wp), 'G: onset bracketed for every mesh')
      CALL require(err(3) <= 1.0e-4_wp, 'G: N = 32 onset within 1e-4 of eq. (33)')
      IF (ref_clamped(it, 1) <= 50.0_wp) &
        CALL require(order >= 3.5_wp .AND. order <= 4.5_wp, 'G: observed order between 3.5 and 4.5 (T <= 50)')
    END DO
  END SUBROUTINE check_greenhill_clamped

  SUBROUTINE check_greenhill_pinned()
    REAL(wp) :: m, err
    INTEGER :: it
    DO it = 1, 2
      m = onset(32, ref_pinned(it, 1), CD_ENDCONN_PINNED, ref_pinned(it, 2))
      err = ABS(m - ref_pinned(it, 2))/ref_pinned(it, 2)
      WRITE (*, '(A,F6.1,A,F12.7,A,F11.8,A,ES9.2)') 'Greenhill pinned (semi-tangential) T L^2/EI=', &
        ref_pinned(it, 1), ': M_cr L/EI(N=32) =', m, ' ref ', ref_pinned(it, 2), ' rel.err ', err
      CALL require(err <= 1.0e-4_wp, 'P: pinned constant-velocity-joint onset within 1e-4')
    END DO
  END SUBROUTINE check_greenhill_pinned

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_post_buckling()
    !! Clamped at both ends with both positions held (EI = L = 1, N = 16, EA = 1e4, prestressed
    !! to T L^2/EI = 10 by the end separation). 0.9 M_cr: stable straight. 1.05 M_cr: the straight
    !! saddle is reported unstable without descent; with descent the solve ends stable (the
    !! rotation about the clamp axis is the one allowed zero mode), buckled, lower in energy and
    !! with a relaxed torque.
    REAL(wp), PARAMETER :: MCR = 10.42885644_wp
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp), ALLOCATABLE :: q(:)
    REAL(wp) :: e_straight, m_straight, amp
    INTEGER :: es
    CHARACTER(512) :: em
    CALL straight_torsion(16, 1.0_wp, 0.9_wp*MCR, tors)
    tors%zero_mode_allowed = .TRUE.
    CALL fixed_rod(tors, q, es, em)
    CALL require(es == CD_HCSTAT_OK .AND. tors%stable, 'B: 0.9 M_cr straight state stable: '//TRIM(em))
    CALL require(tors%descents == 0, 'B: no descent below the onset')
    CALL straight_torsion(16, 1.0_wp, 1.05_wp*MCR, tors)
    tors%descend = .FALSE.
    CALL fixed_rod(tors, q, es, em)
    CALL require(es == CD_HCSTAT_OK, 'B: the straight saddle converges without descent: '//TRIM(em))
    CALL require(.NOT. tors%stable .AND. tors%n_negative >= 1, 'B: the straight saddle is reported unstable')
    WRITE (*, '(A,I0,A,ES12.5)') 'post-buckling 1.05 M_cr straight: negative eigenvalues ', tors%n_negative, &
      ', lowest scaled eigenvalue ', tors%lambda_min
    e_straight = tors%energy
    m_straight = tors%torque
    CALL straight_torsion(16, 1.0_wp, 1.05_wp*MCR, tors)
    tors%zero_mode_allowed = .TRUE.
    CALL fixed_rod(tors, q, es, em)
    CALL require(es == CD_HCSTAT_OK, 'B: the descent converges: '//TRIM(em))
    amp = nan_max_abs([nan_max_abs(q(2::6)), nan_max_abs(q(3::6))])
    WRITE (*, '(A,ES12.5,A,F9.5,A,F9.5,A,ES10.3,A,I0,A,ES11.3)') 'post-buckling: E - E_straight = ', &
      tors%energy - e_straight, ', M_t ', tors%torque, ' (straight ', m_straight, '), lateral amplitude/L ', amp, &
      ', descents ', tors%descents, ', Theta ', tors%theta
    CALL require(tors%stable, 'B: the descent ends on a stable state')
    CALL require(tors%descents >= 1, 'B: a descent was taken')
    CALL require(tors%energy < e_straight, 'B: the buckled state has lower energy than the straight saddle')
    CALL require(tors%torque < m_straight, 'B: the torque relaxes on the buckled branch')
    CALL require(amp > 1.0e-3_wp .AND. amp < 0.1_wp, 'B: a buckled state near the onset (amplitude 1e-3 to 0.1 L)')
  END SUBROUTINE check_post_buckling

  SUBROUTINE fixed_rod(tors, q, es, em)
    !! Straight weightless rod, EI = L = 1, EA = 1e4, both positions held 1.001 apart (T = 10),
    !! both ends clamped along +x.
    TYPE(CD_HermiteTorsionType), INTENT(INOUT) :: tors
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: q(:)
    INTEGER, INTENT(OUT) :: es
    CHARACTER(*), INTENT(OUT) :: em
    REAL(wp), ALLOCATABLE :: seed(:), l0(:), curv(:)
    REAL(wp) :: res
    INTEGER :: nd, it, ne
    ne = SIZE(tors%gj)
    CALL straight_rod(ne, 1.0_wp, seed, l0)
    seed(1::6) = 1.001_wp*seed(1::6)
    nd = SIZE(seed)
    ALLOCATE (q(nd), curv(ne + 1))
    CALL CD_HermiteCable_Static_Solve(l0, [(1.0e4_wp, it=1, ne)], [(1.0_wp, it=1, ne)], [(0.0_wp, it=1, ne)], seed, &
                                      [1, 2, 3, nd - 5, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 1, 60, 1.0e-9_wp, &
                                      1.0_wp, q, curv, res, it, es, em, endconn_stiffness=[0.0_wp, 0.0_wp], &
                                      endconn_direction=RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                [3, 2]), &
                                      endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=tors)
  END SUBROUTINE fixed_rod

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_multi_turn()
    !! (a) Straight clamped rod, GJ/EI = 0.2, Phi = 3 turns in one solve (at most pi/4 per twist
    !!     stage): M_t = Phi/C. (b) A sagging line clamped at both ends with gravity, Phi swept by
    !!     2.5 turns in half-turn solves from the warm state: Theta continuous between solves (also
    !!     across the +-pi cut of the raw holonomy), M_t C = Phi - Theta, and one direct solve to
    !!     the end reaches the same state.
    TYPE(CD_HermiteTorsionType) :: tors, tors_direct
    REAL(wp), ALLOCATABLE :: q(:), seed(:), l0(:), q_direct(:)
    REAL(wp) :: phi, theta_prev, c, dmax, offset
    INTEGER :: k, es, ne, pass
    CHARACTER(512) :: em
    CALL straight_torsion(16, 0.2_wp, 6.0_wp*CD_HTORS_PI, tors)
    CALL solve_rod(16, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_OK, 'M: three-turn straight solve converges: '//TRIM(em))
    WRITE (*, '(A,I0,A,ES12.5)') 'multi-turn straight: twist stages ', tors%ramp_steps, ', rel. torque error ', &
      ABS(tors%torque - 0.2_wp*6.0_wp*CD_HTORS_PI)/(0.2_wp*6.0_wp*CD_HTORS_PI)
    CALL require(tors%ramp_steps >= 24, 'M: at most pi/4 per twist stage')
    CALL require(ABS(tors%torque - 0.2_wp*6.0_wp*CD_HTORS_PI) <= 1.0e-11_wp*0.2_wp*6.0_wp*CD_HTORS_PI, &
                 'M: three-turn torque law')
    ! (b) sagging clamped line, ends 0.9 L apart, w = 5 EI/L^3, GJ = 0.3 EI. Pass 2 rolls the
    !     End-2 reference normal by -(pi - 1e-6) about its director, so Theta starts just below pi
    !     and the twisted solves carry it across the +-pi branch cut of the raw holonomy.
    ne = 24
    DEALLOCATE (q)
    ALLOCATE (seed(6*(ne + 1)), l0(ne), q(6*(ne + 1)), q_direct(6*(ne + 1)))
    l0 = 1.0_wp/ne
    c = 1.0_wp/0.3_wp
    DO pass = 1, 2
      DO k = 0, ne
        seed(6*k + 1:6*k + 6) = [0.9_wp*k/ne, 0.0_wp, -0.2_wp*SIN(CD_HTORS_PI*k/ne), &
                                 0.9_wp, 0.0_wp, -0.2_wp*CD_HTORS_PI*COS(CD_HTORS_PI*k/ne)]
      END DO
      tors = CD_HermiteTorsionType()
      tors%active = .TRUE.
      ALLOCATE (tors%gj(ne))
      tors%gj = 0.3_wp
      tors%ends(:, 1) = [1.0_wp, 0.0_wp, -1.0_wp]/SQRT(2.0_wp)
      tors%ends(:, 2) = [0.0_wp, 1.0_wp, 0.0_wp]
      tors%ends(:, 3) = [1.0_wp, 0.0_wp, 1.0_wp]/SQRT(2.0_wp)
      offset = 0.0_wp
      IF (pass == 2) offset = CD_HTORS_PI - 1.0e-6_wp
      ! n_2 rolled by -offset about d_2 (Theta grows by offset)
      tors%ends(:, 4) = COS(offset)*[0.0_wp, 1.0_wp, 0.0_wp] - SIN(offset)*[-1.0_wp, 0.0_wp, 1.0_wp]/SQRT(2.0_wp)
      theta_prev = offset
      DO k = 0, 5
        phi = offset + k*CD_HTORS_PI
        tors%phi = phi
        CALL sag_solve(tors, l0, seed, q, es, em)
        CALL require(es == CD_HCSTAT_OK, 'M: sagging-line twist solve converges: '//TRIM(em))
        IF (es /= CD_HCSTAT_OK) RETURN
        WRITE (*, '(A,I0,A,F6.2,A,ES16.8,A,ES12.5,A,L1,A,ES10.3)') 'multi-turn sag (pass ', pass, '): Phi/2pi=', &
          phi/(2.0_wp*CD_HTORS_PI), ' Theta=', tors%theta, ' M_t=', tors%torque, ' stable ', tors%stable, &
          ' max|y| ', nan_max_abs(q(2::6))
        CALL require(ABS(tors%theta - theta_prev) < 1.0e-3_wp, 'M: Theta continuous between solves')
        CALL require(ABS(tors%torque*c - (phi - tors%theta)) <= 1.0e-10_wp*MAX(1.0_wp, phi), &
                     'M: M_t C = Phi - Theta')
        CALL require(tors%stable, 'M: the twisted sagging line is stable')
        theta_prev = tors%theta
        seed = q
      END DO
      IF (pass == 2) CALL require(tors%theta > CD_HTORS_PI, 'M: Theta carried across pi without a 2 pi slip')
      tors_direct = tors
      tors_direct%has_theta = .FALSE.
      tors_direct%theta = 0.0_wp
      tors_direct%theta_hint = offset
      DO k = 0, ne
        seed(6*k + 1:6*k + 6) = [0.9_wp*k/ne, 0.0_wp, -0.2_wp*SIN(CD_HTORS_PI*k/ne), &
                                 0.9_wp, 0.0_wp, -0.2_wp*CD_HTORS_PI*COS(CD_HTORS_PI*k/ne)]
      END DO
      CALL sag_solve(tors_direct, l0, seed, q_direct, es, em)
      CALL require(es == CD_HCSTAT_OK, 'M: direct 2.5-turn solve converges: '//TRIM(em))
      dmax = nan_max_abs(q_direct - q)
      WRITE (*, '(A,ES10.3,A,ES10.3)') 'multi-turn sag: direct vs swept state ', dmax, ', Theta difference ', &
        ABS(tors_direct%theta - tors%theta)
      CALL require(dmax <= 1.0e-7_wp .AND. ABS(tors_direct%theta - tors%theta) <= 1.0e-8_wp, &
                   'M: the direct solve reaches the swept state')
    END DO
  END SUBROUTINE check_multi_turn

  SUBROUTINE sag_solve(t, l0, s0, qo, es2, em2)
    !! Sagging line (EA 1e5, EI 1, w 5) clamped at both ends along t's end directors.
    TYPE(CD_HermiteTorsionType), INTENT(INOUT) :: t
    REAL(wp), INTENT(IN) :: l0(:), s0(:)
    REAL(wp), INTENT(OUT) :: qo(:)
    INTEGER, INTENT(OUT) :: es2
    CHARACTER(*), INTENT(OUT) :: em2
    REAL(wp), ALLOCATABLE :: curv(:)
    REAL(wp) :: res
    INTEGER :: it, ne, nd
    ne = SIZE(l0)
    nd = SIZE(s0)
    ALLOCATE (curv(ne + 1))
    CALL CD_HermiteCable_Static_Solve(l0, [(1.0e5_wp, it=1, ne)], [(1.0_wp, it=1, ne)], [(5.0_wp, it=1, ne)], &
                                      s0, [1, 2, 3, nd - 5, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 4, 100, &
                                      1.0e-9_wp, 1.0_wp, qo, curv, res, it, es2, em2, &
                                      endconn_stiffness=[0.0_wp, 0.0_wp], &
                                      endconn_direction=RESHAPE([t%ends(:, 1), t%ends(:, 3)], [3, 2]), &
                                      endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=t)
  END SUBROUTINE sag_solve

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_fail_closed()
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp), ALLOCATABLE :: q(:), seed(:), l0(:), curv(:)
    REAL(wp) :: res
    INTEGER :: es, it, nd
    CHARACTER(512) :: em
    CALL straight_torsion(8, 1.0_wp, 1.0_wp, tors)
    DEALLOCATE (tors%gj)
    CALL solve_rod(8, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'GJ') > 0, 'F: missing GJ is rejected by name')
    CALL straight_torsion(8, 1.0_wp, 1.0_wp, tors)
    tors%gj(3) = 0.0_wp
    CALL solve_rod(8, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'GJ must be positive') > 0, 'F: zero GJ is rejected')
    CALL straight_torsion(8, 1.0_wp, 1.0_wp, tors)
    tors%ends(:, 1) = [0.0_wp, 1.0_wp, 0.0_wp]
    tors%ends(:, 2) = [0.0_wp, 0.0_wp, 1.0_wp]
    CALL solve_rod(8, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'rigid connection direction') > 0, &
                 'F: a director off the rigid direction is rejected')
    CALL straight_torsion(8, 1.0_wp, 1.0_wp, tors)
    tors%ends(:, 2) = [1.0_wp, 0.0_wp, 0.0_wp]
    CALL solve_rod(8, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'orthonormal') > 0, &
                 'F: a reference normal along the director is rejected')
    ! an imposed twist beyond 1000 turns (a units slip) stops by name before the solve, instead of
    ! a ramp of millions of stages or an overflowing stage count
    CALL straight_torsion(8, 1.0_wp, 1.0e7_wp, tors)
    CALL solve_rod(8, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'exceeds 1000 turns') > 0 .AND. &
                 INDEX(em, '1.00000E+07') > 0, 'F: an imposed twist above 1000 turns is rejected with its value')
    CALL straight_torsion(8, 1.0_wp, 1.0e12_wp, tors)
    CALL solve_rod(8, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'exceeds 1000 turns') > 0, &
                 'F: an imposed twist beyond the integer stage count is rejected by name')
    CALL straight_torsion(8, 1.0_wp, 1.0_wp, tors)
    tors%theta_hint = 1.0e5_wp
    CALL solve_rod(8, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'twist state') > 0, &
                 'F: a twist branch hint above 1000 turns is rejected by name')
    CALL straight_torsion(8, 1.0_wp, 1.0_wp, tors)
    CALL straight_rod(8, 1.0_wp, seed, l0)
    nd = SIZE(seed)
    ALLOCATE (curv(9))
    DEALLOCATE (q)
    ALLOCATE (q(nd))
    CALL CD_HermiteCable_Static_Solve(l0, [(1.0e7_wp, it=1, 8)], [(1.0_wp, it=1, 8)], [(0.0_wp, it=1, 8)], seed, &
                                      [1, 2, 3, nd - 5, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 1, 20, 1.0e-10_wp, &
                                      1.0_wp, q, curv, res, it, es, em, pseudo_transient=.TRUE., torsion=tors)
    CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'pseudo_transient') > 0, &
                 'F: pseudo-transient continuation with torsion is rejected')
    BLOCK
      REAL(wp) :: kband(34, 6*9), fres(6*9)
      CALL straight_torsion(8, 1.0_wp, 1.0_wp, tors)
      CALL CD_HermiteCable_Static_Solve(l0, [(1.0e7_wp, it=1, 8)], [(1.0_wp, it=1, 8)], [(0.0_wp, it=1, 8)], seed, &
                                        [1, 2, 3, nd - 5, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 1, 20, 1.0e-10_wp, &
                                        1.0_wp, q, curv, res, it, es, em, residual_out=fres, tangent_out=kband, &
                                        torsion=tors)
      CALL require(es == CD_HCSTAT_BADINPUT .AND. INDEX(em, 'tangent_out') > 0, &
                   'F: a banded tangent_out with torsion is rejected (it cannot hold g g^T / C)')
    END BLOCK
  END SUBROUTINE check_fail_closed

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_resolve()
    !! R  re-solve with a stored Theta (has_theta): the untwisted straight rod has Theta = 0, so a
    !!    stored value within pi/2 continues on its branch (torque Phi / C), while one farther away
    !!    (2 and 3.5 rad: the branch of 3.5 would be 2 pi, a torque one turn off) stops by name and
    !!    leaves the stored state as it was.
    REAL(wp), PARAMETER :: STORED(4) = [0.0_wp, 1.0_wp, 2.0_wp, 3.5_wp]
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp), ALLOCATABLE :: q(:)
    INTEGER :: k, es
    LOGICAL :: near
    CHARACTER(512) :: em
    DO k = 1, SIZE(STORED)
      CALL straight_torsion(10, 1.0_wp, 1.0_wp, tors)
      tors%has_theta = .TRUE.
      tors%theta = STORED(k)
      CALL solve_rod(10, 1.0e7_wp, 1.0_wp, 1.0_wp, CD_ENDCONN_RIGID, tors, q, es, em)
      near = STORED(k) <= 0.5_wp*CD_HTORS_PI
      WRITE (*, '(A,F5.2,A,I0,A,F10.6,A,F10.6)') 're-solve from stored Theta ', STORED(k), ': status ', es, &
        ', Theta ', tors%theta, ', torque ', tors%torque
      IF (near) THEN
        CALL require(es == CD_HCSTAT_OK .AND. ABS(tors%torque - 1.0_wp) <= 1.0e-10_wp, &
                     'R: a stored Theta within pi/2 continues on its branch: '//TRIM(em))
      ELSE
        CALL require(es /= CD_HCSTAT_OK .AND. INDEX(em, 'ambiguous') > 0, &
                     'R: a stored Theta beyond pi/2 of the untwisted state stops by name')
        CALL require(tors%has_theta .AND. ABS(tors%theta - STORED(k)) <= 0.0_wp, &
                     'R: the stopped re-solve leaves the stored Theta unchanged')
      END IF
    END DO
    ! the same rod at a tolerance below its untwisted residual floor: the stop names the floor
    BLOCK
      REAL(wp), ALLOCATABLE :: seed(:), l0(:), f(:), curv(:)
      REAL(wp) :: res
      INTEGER :: it, nd
      CALL straight_rod(10, 1.0_wp, seed, l0)
      nd = SIZE(seed)
      ALLOCATE (f(nd), curv(11))
      DEALLOCATE (q)
      ALLOCATE (q(nd))
      f = 0.0_wp
      f(nd - 5) = 1.0_wp
      CALL straight_torsion(10, 1.0_wp, 1.0_wp, tors)
      CALL CD_HermiteCable_Static_Solve(l0, [(1.0e7_wp, it=1, 10)], [(1.0_wp, it=1, 10)], [(0.0_wp, it=1, 10)], &
                                        seed, [1, 2, 3, nd - 4, nd - 3], -1.0e6_wp, 0.0_wp, 1, 60, 1.0e-9_wp, &
                                        1.0_wp, q, curv, res, it, es, em, f_nodal=f, &
                                        endconn_stiffness=[0.0_wp, 0.0_wp], &
                                        endconn_direction=RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], &
                                                                  [3, 2]), &
                                        endconn_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID], torsion=tors)
      WRITE (*, '(A,I0,A)') 'tolerance below the residual floor: status ', es, ' ('//TRIM(em)//')'
      CALL require(es /= CD_HCSTAT_OK .AND. INDEX(em, 'residual floor') > 0 .AND. .NOT. tors%has_theta, &
                   'R: a tolerance below the untwisted residual floor is reported as such')
    END BLOCK
  END SUBROUTINE check_resolve

END PROGRAM test_hermite_torsion_static
