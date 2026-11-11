! File: tests/test_hermite_fmf.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_fmf
  !! Gate for the OpenFAST-style FMF lifecycle over the Hermite dynamic power cable
  !! (CableDyn_OpenFAST_HermiteFMF): kinematics in at the coupled hang-off, loads out.
  !!
  !! Rig: the Lozon 80 m Gulf-of-Mexico lazy-wave cable (the committed L3-6 dynamic rig at
  !! stride 2), static equilibrium by buoyancy continuation, then the 3 m / 12 s hang-off
  !! heave with Morison drag + added mass.
  !!
  !! Cases:
  !!   1. SHELL TRANSPARENCY: driving the cable through Init/UpdateStates is bit-identical
  !!      to driving CD_HermiteCable_Dyn_Step directly with the same prescribed kinematics
  !!      (the lifecycle adds bookkeeping, not arithmetic).
  !!   2. STATIC REACTION BALANCE: at the at-rest equilibrium the two endpoint reactions
  !!      close the global force balance against the net submerged weight (all three
  !!      components), and the hang-off reaction is consistent with the axial-tension
  !!      readout EA(|m|-1) along the end tangent.
  !!   3. DYNAMIC REACTION: over the heave window the fairlead load varies smoothly, stays
  !!      finite, and its range brackets the static value.
  !!   4. FAIL-CLOSED: uninitialised calls, a free coupled endpoint, bad dt, and non-finite
  !!      inputs are rejected.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Shapes
  USE CableDyn_HermiteCableStatic, ONLY: CD_HermiteCable_Static_Solve, CD_HCSTAT_OK
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_Init, CD_HFMF_Set_Drag, &
                                          CD_HFMF_Set_AddedMass, CD_HFMF_UpdateStates, CD_HFMF_CalcOutput, &
                                          CD_HFMF_Set_Contact, CD_HFMF_SetCoupledKinematics, &
                                          CD_HFMF_Refresh_Acceleration, CD_HFMF_MinSpanZ, CD_HFMF_End, &
                                          CD_HFMF_OK, CD_HFMF_BADINPUT
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp, PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: EA = 4.69e8_wp, EI_FULL = 1.99e4_wp
  REAL(wp), PARAMETER :: BAREM = 36.7_wp, BARED = 0.16_wp, ZSITE = -14.0_wp
  REAL(wp), PARAMETER :: LTOP = 68.114_wp, LBUOY = 50.0_wp
  REAL(wp), PARAMETER :: BMASS = 59.53_wp, BOD = 0.29_wp
  REAL(wp), PARAMETER :: AMP = 3.0_wp, PER = 12.0_wp, DT = 0.05_wp
  ! two heave periods; the reaction range is scored on the SECOND period only (the drive
  ! starts with a velocity discontinuity, so the first period carries the impulsive-start
  ! transient -- large but physical inertial reactions the steady window must not inherit)
  INTEGER, PARAMETER :: NSTEP = 480, NSTEADY = 240, STRIDE = 2
  ! The committed L3-6 80 m hang-off tension channel (l3_lazywave_dynamic, OrcaFlex
  ! 11.6c still-water references) in N: the steady fairlead-load MAGNITUDE range must
  ! reproduce it. The magnitude is the honest comparand to a tension channel -- the
  ! z-component alone carries the ~8 deg end-inclination factor (~1%) on top.
  REAL(wp), PARAMETER :: REF_TMIN = 5634.2_wp, REF_TMAX = 13080.6_wp
  REAL(wp), PARAMETER :: CH_GATE = 0.03_wp

  INTEGER :: nfail, nnf, nn, ne, i, e, u, ios, es, iters, nfix, isamp, s
  REAL(wp) :: Lsus, l0e, a_mid, dum, res, buoy_w, bare_w, t, zt, vt, at, z0
  REAL(wp) :: y_rest_a(3), y_rest_b(3), yk(3), tmagn, treadout, wnet, ymin, ymax, ymagmin, ymagmax, ymag
  REAL(wp), ALLOCATABLE :: posf(:, :), pos(:, :), seed(:), q_static(:), l0(:), EAv(:), EIv(:)
  REAL(wp), ALLOCATABLE :: w(:), rhoa(:), curv(:), tv(:)
  REAL(wp), ALLOCATABLE :: hdiam(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
  REAL(wp), ALLOCATABLE :: knnode(:), cnnode(:), a_before(:), inertial(:), balance(:)
  INTEGER, ALLOCATABLE :: fixed(:)
  REAL(wp) :: pq(1), pv(1), pa(1), u_pos(3), u_vel(3), u_acc(3)
  INTEGER :: pdof(1)
  TYPE(CD_HFMF_ModuleType) :: fmf, fmf_b
  TYPE(CD_HermiteCableDynType) :: direct
  CHARACTER(300) :: em

  nfail = 0
  bare_w = (BAREM - RHOW*0.25_wp*PI*BARED**2)*GACC
  buoy_w = (BMASS - RHOW*0.25_wp*PI*BOD**2)*GACC

  ! --- committed 80 m suspended-span seed at stride 2, site frame ---
  OPEN (NEWUNIT=u, FILE='gomex80_lazywave_seed.xyz', STATUS='OLD', ACTION='READ', IOSTAT=ios)
  IF (ios /= 0) THEN
    WRITE (*, '(A)') 'FAIL: cannot open gomex80_lazywave_seed.xyz'; ERROR STOP 1
  END IF
  READ (u, *) nnf, Lsus
  READ (u, *) dum, dum
  ALLOCATE (posf(3, nnf))
  DO i = 1, nnf
    READ (u, *) posf(1, i), posf(2, i), posf(3, i)
  END DO
  CLOSE (u)
  nn = (nnf - 1)/STRIDE + 1
  IF (MOD(nnf - 1, STRIDE) /= 0) nn = nn + 1
  ALLOCATE (pos(3, nn))
  isamp = 0
  DO i = 1, nnf, STRIDE
    isamp = isamp + 1; pos(:, isamp) = posf(:, i)
  END DO
  IF (isamp < nn) pos(:, nn) = posf(:, nnf)
  pos(3, :) = pos(3, :) + ZSITE

  ne = nn - 1
  l0e = Lsus/REAL(ne, wp)
  ALLOCATE (seed(6*nn), q_static(6*nn), l0(ne), EAv(ne), EIv(ne), w(ne), rhoa(ne), curv(nn), tv(3))
  ALLOCATE (fixed(6 + 2*nn), hdiam(ne), hcdn(ne), hcdt(ne), hcan(ne), hcat(ne))
  seed = 0.0_wp
  DO i = 1, nn
    seed(6*(i - 1) + 1:6*(i - 1) + 3) = pos(:, i)
    IF (i < nn) THEN
      tv = pos(:, i + 1) - pos(:, i)
    ELSE
      tv = pos(:, i) - pos(:, i - 1)
    END IF
    tv = tv/SQRT(SUM(tv**2))
    seed(6*(i - 1) + 4:6*(i - 1) + 6) = tv
  END DO
  DO e = 1, ne
    l0(e) = l0e; EAv(e) = EA
    a_mid = REAL(e, wp)*l0e - 0.5_wp*l0e
    EIv(e) = EI_FULL
    IF (a_mid > LTOP .AND. a_mid <= LTOP + LBUOY) THEN
      w(e) = buoy_w; rhoa(e) = BMASS; hdiam(e) = BOD
    ELSE
      w(e) = bare_w; rhoa(e) = BAREM; hdiam(e) = BARED
    END IF
  END DO
  hcdn = 1.2_wp; hcdt = 0.1_wp; hcan = 1.0_wp; hcat = 0.0_wp
  nfix = 0
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = i; END DO
  DO i = 1, 3; nfix = nfix + 1; fixed(nfix) = 6*(nn - 1) + i; END DO
  DO i = 1, nn
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 2
    nfix = nfix + 1; fixed(nfix) = 6*(i - 1) + 5
  END DO

  CALL CD_HermiteCable_Static_Solve(l0, EAv, EIv, w, seed, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                                    8, 80, 1.0e-6_wp, 0.7_wp, q_static, curv, res, iters, es, em)
  CALL require(es == CD_HCSTAT_OK, 'static lazy-wave equilibrium converged: '//TRIM(em))
  IF (es /= CD_HCSTAT_OK) CALL bail()

  ! ================= case 2: static reaction balance =================
  CALL CD_HFMF_Init(fmf, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                    0.5_wp, DT, 1, es, em)
  CALL require(es == CD_HFMF_OK, 'FMF init (hang-off coupled): '//TRIM(em))
  CALL CD_HFMF_Init(fmf_b, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                    0.5_wp, DT, nn, es, em)
  CALL require(es == CD_HFMF_OK, 'FMF init (touchdown coupled): '//TRIM(em))
  CALL CD_HFMF_CalcOutput(fmf, y_rest_a, es, em)
  CALL require(es == CD_HFMF_OK, 'rest CalcOutput at the hang-off')
  CALL CD_HFMF_CalcOutput(fmf_b, y_rest_b, es, em)
  CALL require(es == CD_HFMF_OK, 'rest CalcOutput at the touchdown')
  ! A direct-feedthrough row-1 motion is non-stepping: after contact was installed,
  ! refresh must update free accelerations at the moved q/v while preserving the
  ! caller's prescribed acceleration on the coupled fixed DOFs.
  CALL CD_HFMF_Init(fmf_b, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                    q_static(6*nn - 3) + 0.01_wp, 0.0_wp, 0.5_wp, DT, nn, es, em)
  CALL require(es == CD_HFMF_OK, 'FMF row-1 contact refresh rig init: '//TRIM(em))
  ALLOCATE (knnode(nn), cnnode(nn)); knnode = 1.0e5_wp; cnnode = 1.0e3_wp
  CALL CD_HFMF_Set_Contact(fmf_b, knnode, cnnode, 0.4_wp, es, em)
  CALL require(es == CD_HFMF_OK, 'FMF row-1 contact config: '//TRIM(em))
  u_pos = q_static(6*nn - 5:6*nn - 3) + [0.02_wp, 0.0_wp, -0.02_wp]
  u_vel = [0.3_wp, 0.0_wp, -0.2_wp]
  u_acc = [0.0_wp, 0.0_wp, 0.7_wp]
  CALL CD_HFMF_SetCoupledKinematics(fmf_b, u_pos, u_vel, u_acc, es, em)
  CALL require(es == CD_HFMF_OK, 'FMF row-1 motion commit: '//TRIM(em))
  a_before = fmf_b%line%a
  CALL CD_HFMF_Refresh_Acceleration(fmf_b, es, em)
  CALL require(es == CD_HFMF_OK, 'FMF row-1 acceleration refresh: '//TRIM(em))
  CALL require(nan_max_abs(MERGE(fmf_b%line%a - a_before, 0.0_wp, fmf_b%line%freemask)) > 1.0e-12_wp, &
               'row-1 contact refresh changes the free-node acceleration')
  CALL require(nan_max_abs(fmf_b%line%a(fmf_b%pdof) - u_acc) <= TINY(1.0_wp), &
               'row-1 contact refresh preserves prescribed coupled acceleration')
  ! Independent equilibrium check over the unfactored consistent mass retained in the
  ! model workspace. This detects omission of M_fp*a_p even if the shell restores a_p.
  ALLOCATE (inertial(fmf_b%line%ndof), balance(fmf_b%line%ndof))
  CALL test_band_matvec(fmf_b%line%ws_Msumb, fmf_b%line%a, inertial)
  balance = inertial + fmf_b%line%ws_R
  CALL require(nan_max_abs(MERGE(balance, 0.0_wp, fmf_b%line%freemask)) <= &
               1.0e-10_wp*MAX(1.0_wp, nan_max_abs(fmf_b%line%ws_R)), &
               'row-1 refresh satisfies free-DOF consistent-mass balance with prescribed acceleration')
  DEALLOCATE (inertial, balance)
  CALL CD_HFMF_End(fmf_b)
  wnet = SUM(w*l0)
  WRITE (*, '(A,3F12.2)') 'FMF rest hang-off reaction  (N) = ', y_rest_a
  WRITE (*, '(A,3F12.2)') 'FMF rest touchdown reaction (N) = ', y_rest_b
  WRITE (*, '(A,F12.2,A,F12.2)') 'FMF balance: sum(y_z) = ', y_rest_a(3) + y_rest_b(3), &
    '   -net weight = ', -wnet
  ! the two endpoint pulls on the supports carry the net submerged weight
  CALL require(ABS(y_rest_a(3) + y_rest_b(3) + wnet) < 1.0e-4_wp*ABS(wnet), &
               'endpoint reactions close the vertical balance to the solver tolerance')
  CALL require(ABS(y_rest_a(1) + y_rest_b(1)) < 1.0e-4_wp*ABS(wnet), &
               'endpoint reactions close the horizontal balance')
  ! the hang-off pull is consistent with the axial-tension readout T = EA(|m|-1)
  tmagn = SQRT(SUM(y_rest_a**2))
  treadout = EA*(SQRT(q_static(4)**2 + q_static(5)**2 + q_static(6)**2) - 1.0_wp)
  WRITE (*, '(A,F12.2,A,F12.2,A,F6.2,A)') 'FMF |y_A| = ', tmagn, '   EA(|m|-1) = ', treadout, &
    '   diff ', 100.0_wp*ABS(tmagn - treadout)/treadout, '%'
  CALL require(ABS(tmagn - treadout)/treadout < 0.02_wp, &
               'hang-off reaction magnitude consistent with the end-tangent tension readout (2%)')

  ! ================= case 1 + 3: shell transparency + dynamic reaction =================
  CALL CD_HFMF_Set_Drag(fmf, RHOW, hdiam, hcdn, hcdt, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em)
  CALL require(es == CD_HFMF_OK, 'FMF drag config: '//TRIM(em))
  CALL CD_HFMF_Set_AddedMass(fmf, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)
  CALL require(es == CD_HFMF_OK, 'FMF added-mass config: '//TRIM(em))

  CALL CD_HermiteCable_Dyn_Init(direct, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), &
                                -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'direct dynamic init: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_Drag(direct, RHOW, hdiam, hcdn, hcdt, 0.0_wp, &
                                    [0.0_wp, 0.0_wp, 0.0_wp], es, em)
  CALL CD_HermiteCable_Dyn_Set_AddedMass(direct, RHOW, hdiam, hcan, hcat, 0.0_wp, es, em)

  z0 = q_static(3)
  pdof(1) = 3
  ymin = HUGE(1.0_wp); ymax = -HUGE(1.0_wp)
  ymagmin = HUGE(1.0_wp); ymagmax = -HUGE(1.0_wp)
  t = 0.0_wp
  DO s = 1, NSTEP
    t = t + DT
    zt = z0 + AMP*SIN(2.0_wp*PI*t/PER)
    vt = AMP*(2.0_wp*PI/PER)*COS(2.0_wp*PI*t/PER)
    at = -AMP*(2.0_wp*PI/PER)**2*SIN(2.0_wp*PI*t/PER)
    u_pos = [q_static(1), q_static(2), zt]
    u_vel = [0.0_wp, 0.0_wp, vt]
    u_acc = [0.0_wp, 0.0_wp, at]
    CALL CD_HFMF_UpdateStates(fmf, u_pos, u_vel, u_acc, es, em)
    CALL require(es == CD_HFMF_OK, 'FMF UpdateStates converged')
    IF (es /= CD_HFMF_OK) EXIT
    ! the direct model drives only the heave DOF; x/y of node 1 are held by fixed_dofs at
    ! the same values, so the two problems are identical
    pq(1) = zt; pv(1) = vt; pa(1) = at
    CALL CD_HermiteCable_Dyn_Step(direct, DT, 100, 1.0e-4_wp, es, em, &
                                  pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
    CALL require(es == CD_HCDYN_OK, 'direct step converged')
    IF (es /= CD_HCDYN_OK) EXIT
    CALL require(nan_max_abs(fmf%line%q - direct%q) <= 0.0_wp, 'shell trajectory bit-identical to direct')
    IF (s > NSTEADY) THEN
      CALL CD_HFMF_CalcOutput(fmf, yk, es, em)
      CALL require(es == CD_HFMF_OK, 'dynamic CalcOutput')
      ymin = MIN(ymin, yk(3)); ymax = MAX(ymax, yk(3))
      ymag = SQRT(SUM(yk**2))
      ymagmin = MIN(ymagmin, ymag); ymagmax = MAX(ymagmax, ymag)
    END IF
  END DO
  WRITE (*, '(A,F12.2,A,F12.2,A,F12.2)') 'FMF steady y_z range = [', ymin, ', ', ymax, &
    ']   rest y_z = ', y_rest_a(3)
  WRITE (*, '(A,F12.2,A,F12.2,A)') 'FMF steady |y| range = [', ymagmin, ', ', ymagmax, ']'
  WRITE (*, '(A,F6.2,A,F6.2,A)') 'FMF |y| range vs L3-6 tension channel [5634.2, 13080.6]: min err ', &
    100.0_wp*ABS(ymagmin - REF_TMIN)/REF_TMIN, '%   max err ', &
    100.0_wp*ABS(ymagmax - REF_TMAX)/REF_TMAX, '%'
  CALL require(ymin < y_rest_a(3) .AND. ymax > y_rest_a(3), &
               'steady fairlead load brackets the static value over the heave cycle')
  ! the loads-out cross-validation is GATED, not just narrated: the steady fairlead-load
  ! magnitude extrema reproduce the committed OrcaFlex-validated L3-6 hang-off tension
  ! channel of the same rig (the reaction magnitude differs from the wall tension only by
  ! the bending shear + nodal tributary share, ~0.2% at rest)
  CALL require(ABS(ymagmin - REF_TMIN)/REF_TMIN < CH_GATE, &
               'steady fairlead-load minimum on the L3-6 tension channel (3%)')
  CALL require(ABS(ymagmax - REF_TMAX)/REF_TMAX < CH_GATE, &
               'steady fairlead-load maximum on the L3-6 tension channel (3%)')

  ! ================= case 4: fail-closed =================
  CALL check_fail_closed()

  ! ================= case 5: exact centreline span minimum =================
  CALL test_exact_span_min()

  CALL CD_HFMF_End(fmf)
  CALL CD_HermiteCable_Dyn_End(direct)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: Hermite dynamic power cable behind the OpenFAST-style FMF lifecycle'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE bail()
    WRITE (*, '(A)') 'FAIL: rig setup failed'
    ERROR STOP 1
  END SUBROUTINE bail

  PURE SUBROUTINE test_band_matvec(abg, x, y)
    !! Test-side multiplication for the Hermite chain's documented KL=KU=11 LAPACK
    !! general-band layout. Kept independent of the private production helper so the
    !! acceleration-refresh gate checks the stored mass/residual equilibrium directly.
    REAL(wp), INTENT(IN) :: abg(:, :), x(:)
    REAL(wp), INTENT(OUT) :: y(:)
    INTEGER, PARAMETER :: kl = 11, ku = 11
    INTEGER :: ii, jj, n
    n = SIZE(x)
    y = 0.0_wp
    DO jj = 1, n
      DO ii = MAX(1, jj - ku), MIN(n, jj + kl)
        y(ii) = y(ii) + abg(kl + ku + 1 + ii - jj, jj)*x(jj)
      END DO
    END DO
  END SUBROUTINE test_band_matvec

  SUBROUTINE check_fail_closed()
    USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN
    TYPE(CD_HFMF_ModuleType) :: bad
    REAL(wp) :: y3(3), nanv
    INTEGER :: es2, fixed_free(6)
    CHARACTER(300) :: em2
    nanv = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
    ! uninitialised module rejects lifecycle calls
    CALL CD_HFMF_UpdateStates(bad, [0.0_wp, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], &
                              [0.0_wp, 0.0_wp, 0.0_wp], es2, em2)
    CALL require(es2 == CD_HFMF_BADINPUT, 'uninitialised UpdateStates rejected')
    CALL CD_HFMF_CalcOutput(bad, y3, es2, em2)
    CALL require(es2 == CD_HFMF_BADINPUT, 'uninitialised CalcOutput rejected')
    ! a coupled endpoint whose translations are not fixed is rejected
    fixed_free = [6*(nn - 1) + 1, 6*(nn - 1) + 2, 6*(nn - 1) + 3, 2, 5, 8]
    CALL CD_HFMF_Init(bad, l0, EAv, EIv, rhoa, w, q_static, fixed_free, -2000.0_wp, 0.0_wp, &
                      0.5_wp, DT, 1, es2, em2)
    CALL require(es2 == CD_HFMF_BADINPUT, 'free coupled endpoint rejected at Init')
    ! bad dt rejected
    CALL CD_HFMF_Init(bad, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                      0.5_wp, 0.0_wp, 1, es2, em2)
    CALL require(es2 == CD_HFMF_BADINPUT, 'nonpositive dt rejected at Init')
    ! non-finite kinematics rejected
    CALL CD_HFMF_UpdateStates(fmf, [nanv, 0.0_wp, 0.0_wp], [0.0_wp, 0.0_wp, 0.0_wp], &
                              [0.0_wp, 0.0_wp, 0.0_wp], es2, em2)
    CALL require(es2 == CD_HFMF_BADINPUT, 'non-finite prescribed kinematics rejected')
    ! a FAILED re-initialisation must preserve the already-working module (the candidate
    ! pattern): the bad dt is rejected and the existing lifecycle keeps functioning
    CALL CD_HFMF_Init(fmf, l0, EAv, EIv, rhoa, w, q_static, fixed(1:nfix), -2000.0_wp, 0.0_wp, &
                      0.5_wp, 0.0_wp, 1, es2, em2)
    CALL require(es2 == CD_HFMF_BADINPUT, 'bad re-initialisation rejected')
    CALL CD_HFMF_CalcOutput(fmf, y3, es2, em2)
    CALL require(es2 == CD_HFMF_OK, 'module preserved and functional after the failed re-init')
  END SUBROUTINE check_fail_closed

  SUBROUTINE test_exact_span_min()
    !! FIX-1 direct coverage: CD_HFMF_MinSpanZ returns the EXACT centreline minimum from the
    !! cubic's stationary points, catching an interior sag that dips below BOTH element end nodes
    !! -- which fixed-point sampling can miss. Craft a single-element cable whose two nodes sit at
    !! z = 0 but whose cubic z(xi) dips to a NEGATIVE minimum at a NON-grid xi (~0.302); the exact
    !! result must (a) fall below the nodes, (b) match a fine 2001-sample oracle, and (c) sit
    !! strictly below the previous fixed 13-sample estimate (the exact-vs-sampled gap this fix
    !! closes). The module is hand-built to the minimum CD_HFMF_MinSpanZ reads (initialized,
    !! line%ne, line%l0, line%q); its allocatable components auto-release at return.
    TYPE(CD_HFMF_ModuleType) :: m
    REAL(wp) :: zex, zfine, zcoarse, zc, xi, Hh(4), dHh(4)
    REAL(wp) :: z1, mz1, z2, mz2, Ll
    INTEGER :: kk
    Ll = 1.0_wp
    z1 = 0.0_wp; mz1 = -1.0_wp; z2 = 0.0_wp; mz2 = -0.2_wp
    m%line%ne = 1
    ALLOCATE (m%line%l0(1)); m%line%l0(1) = Ll
    ALLOCATE (m%line%q(12))
    m%line%q = 0.0_wp
    ! DOF order per node [r(3), m(3)]; only z (comp 3) and tangent-z (comp 6) drive z(xi).
    m%line%q(1:6) = [0.0_wp, 0.0_wp, z1, 1.0_wp, 0.0_wp, mz1]
    m%line%q(7:12) = [Ll, 0.0_wp, z2, 1.0_wp, 0.0_wp, mz2]
    m%initialized = .TRUE.

    zex = CD_HFMF_MinSpanZ(m)
    ! independent fine 2001-sample oracle over the same cubic
    zfine = HUGE(1.0_wp)
    DO kk = 0, 2000
      xi = REAL(kk, wp)/2000.0_wp
      CALL CD_HermiteCable_Shapes(xi, Ll, Hh, dHh)
      zc = Hh(1)*z1 + Hh(2)*mz1 + Hh(3)*z2 + Hh(4)*mz2
      zfine = MIN(zfine, zc)
    END DO
    ! the previous estimator sampled 13 fixed points (xi = k/12); reproduce it to expose the gap
    zcoarse = HUGE(1.0_wp)
    DO kk = 0, 12
      xi = REAL(kk, wp)/12.0_wp
      CALL CD_HermiteCable_Shapes(xi, Ll, Hh, dHh)
      zc = Hh(1)*z1 + Hh(2)*mz1 + Hh(3)*z2 + Hh(4)*mz2
      zcoarse = MIN(zcoarse, zc)
    END DO
    WRITE (*, '(A,F12.8,A,F12.8,A,F12.8)') 'MinSpanZ exact = ', zex, '  fine-oracle = ', zfine, &
      '  13-sample = ', zcoarse
    CALL require(zex < -0.01_wp, 'exact span-min catches the interior dip below both end nodes')
    CALL require(ABS(zex - zfine) < 1.0e-5_wp, 'exact span-min matches the fine-sample oracle')
    CALL require(zex < zcoarse - 1.0e-5_wp, 'exact span-min is strictly below the old 13-sample estimate')
    CALL CD_HFMF_End(m)
  END SUBROUTINE test_exact_span_min

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_fmf
