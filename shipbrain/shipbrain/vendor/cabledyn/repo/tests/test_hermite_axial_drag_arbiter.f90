! File: tests/test_hermite_axial_drag_arbiter.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hermite_axial_drag_arbiter
  !! CLOSED-FORM ARBITER for the axial (skin) drag tension transfer -- the completion of the
  !! l3_lazywave_dynamic tension-swing diagnosis. When two solvers disagree on one term, ask which
  !! matches the closed form for the agreed inputs (the catenary-arbiter move, applied to the one
  !! term the 2x2 decomposition isolated).
  !!
  !! THE ARBITER PROBLEM (chosen so the closed form is exact, with its conventions explicit):
  !! a straight VERTICAL bare cable (Lozon bare section: d 0.16 m, m 36.7 kg/m, EA 469 MN,
  !! EI 19.9 kN m^2, submerged weight w = (m - rho pi d^2/4) g = 166.36 N/m), length L = 60 m,
  !! hanging from a heaved top node at (0,0,-20) with the bottom end FREE. The bottom-free hanging
  !! line translates RIGIDLY with the top (axial elastic transit time L/c ~ 0.017 s << the 12 s
  !! drive; strain O(1e-5) so deformed length = reference length), so the velocity profile is
  !! exactly UNIFORM -- no profile assumption, no sampling question. The line is fully submerged at
  !! all times (top -20+1.5 m; still water, no waves -- no Wheeler question). Transverse DOFs are
  !! fixed (the motion is purely axial; the normal drag term is identically inactive since v_n = 0,
  !! even though Cd_n = 1.2 is set, mirroring the lazy-wave configuration).
  !!
  !! CLOSED FORM for the top (hang-off) wall tension, per unit length integrated over L:
  !!   T_top(t) = L * [ w  +  m_lin * a(t)  +  (1/2) rho pi d Cd_t |v(t)| v(t) ]
  !! with v(t), a(t) the top (== everywhere) velocity/acceleration of the prescribed heave
  !! z(t) = z0 + A sin(2 pi t / T), A = 1.5 m, T = 12 s. The axial added mass is zero (Cat = 0)
  !! and the normal added mass acts only on the fixed transverse DOFs, so inertia carries the
  !! structural mass only. The drag term uses the SKIN (pi d) convention -- the convention CableDyn
  !! implements and the arbiter therefore tests directly.
  !!
  !! GATE: CableDyn's measured hang-off tension (EA(|m1|-1) at the driven node) matches the closed
  !! form POINTWISE over the steady window to < 2 % of the dynamic swing, and the max/min match.
  !!
  !! OrcaFlex 11.6c twin (validation/scripts/orcaflex_axial_drag_arbiter.py, same line / drive / coefficients,
  !! End A free, End B on the harmonic driver, seg 1.5 m, implicit dt 0.05 s): its End B effective
  !! tension max/min over the steady window is committed in the header of that tool and quoted in
  !! VALIDATION.md next to this gate -- the arbitration verdict is recorded there.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_Drag, CD_HermiteCable_Dyn_Set_AddedMass, &
                                          CD_HermiteCable_Dyn_Step, CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp
  REAL(wp), PARAMETER :: RHOW = 1025.0_wp, GACC = 9.80665_wp
  REAL(wp), PARAMETER :: D = 0.16_wp, MLIN = 36.7_wp, EA = 4.69e8_wp, EI = 1.99e4_wp
  REAL(wp), PARAMETER :: L = 60.0_wp, ZTOP = -20.0_wp
  REAL(wp), PARAMETER :: CDN = 1.2_wp, CDT = 0.1_wp, CAN = 1.0_wp, CAT = 0.0_wp
  REAL(wp), PARAMETER :: AMP = 1.5_wp, PER = 12.0_wp, DT = 0.05_wp
  REAL(wp), PARAMETER :: T_END = 36.0_wp, T_SCORE = 12.0_wp
  INTEGER, PARAMETER :: NE = 40

  REAL(wp) :: w_sub, ct_coef, z0, t, zt, vt, at, mnorm, t_meas, t_cf, err_pw, swing_cf
  REAL(wp) :: tmax_m, tmin_m, tmax_cf, tmin_cf
  INTEGER :: nn, i, k, es, s, nfail, nstep
  REAL(wp), ALLOCATABLE :: seed(:), l0(:), EAv(:), EIv(:), wv(:), rhoa(:)
  REAL(wp), ALLOCATABLE :: hd(:), hcdn(:), hcdt(:), hcan(:), hcat(:)
  INTEGER, ALLOCATABLE :: fixed(:)
  INTEGER :: pdof(1)
  REAL(wp) :: pq(1), pv(1), pa(1)
  TYPE(CD_HermiteCableDynType) :: model
  CHARACTER(300) :: em

  nfail = 0
  w_sub = (MLIN - RHOW*0.25_wp*PI*D**2)*GACC          ! 166.36 N/m, pulls -z
  ct_coef = 0.5_wp*RHOW*PI*D*CDT                       ! skin (pi d) tangential-drag coefficient

  nn = NE + 1
  ALLOCATE (seed(6*nn), l0(NE), EAv(NE), EIv(NE), wv(NE), rhoa(NE))
  ALLOCATE (hd(NE), hcdn(NE), hcdt(NE), hcan(NE), hcat(NE))
  l0 = L/REAL(NE, wp); EAv = EA; EIv = EI; wv = w_sub; rhoa = MLIN
  hd = D; hcdn = CDN; hcdt = CDT; hcan = CAN; hcat = CAT
  seed = 0.0_wp
  DO i = 1, nn
    seed(6*(i - 1) + 3) = ZTOP - REAL(i - 1, wp)*L/REAL(NE, wp)   ! r_z, top -> bottom
    seed(6*(i - 1) + 6) = -1.0_wp                                 ! m_z: unit tangent pointing down
  END DO
  ! Pure axial problem: fix r_x, r_y, m_x, m_y at EVERY node (exactly zero in the true solution --
  ! no over-constraint for uniform axial motion of a straight vertical line); the top r_z is the
  ! prescribed drive; the bottom r_z and every m_z are free.
  ALLOCATE (fixed(4*nn + 1))
  k = 0
  DO i = 1, nn
    fixed(k + 1) = 6*(i - 1) + 1; fixed(k + 2) = 6*(i - 1) + 2
    fixed(k + 3) = 6*(i - 1) + 4; fixed(k + 4) = 6*(i - 1) + 5
    k = k + 4
  END DO
  fixed(k + 1) = 3                                     ! top r_z: prescribed heave

  CALL CD_HermiteCable_Dyn_Init(model, l0, EAv, EIv, rhoa, wv, seed, fixed, &
                                -2000.0_wp, 0.0_wp, 0.5_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'arbiter init: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_Drag(model, RHOW, hd, hcdn, hcdt, 0.0_wp, [0.0_wp, 0.0_wp, 0.0_wp], es, em)
  CALL require(es == CD_HCDYN_OK, 'arbiter drag: '//TRIM(em))
  CALL CD_HermiteCable_Dyn_Set_AddedMass(model, RHOW, hd, hcan, hcat, 0.0_wp, es, em)
  CALL require(es == CD_HCDYN_OK, 'arbiter added mass: '//TRIM(em))

  z0 = ZTOP
  pdof(1) = 3
  err_pw = 0.0_wp
  tmax_m = -HUGE(1.0_wp); tmin_m = HUGE(1.0_wp)
  tmax_cf = -HUGE(1.0_wp); tmin_cf = HUGE(1.0_wp)
  ! closed-form swing scale for the pointwise normalisation: max drag + inertia amplitudes
  swing_cf = L*(MLIN*AMP*(2.0_wp*PI/PER)**2 + ct_coef*(AMP*2.0_wp*PI/PER)**2)
  nstep = NINT(T_END/DT)
  t = 0.0_wp
  DO s = 1, nstep
    t = t + DT
    zt = z0 + AMP*SIN(2.0_wp*PI*t/PER)
    vt = AMP*(2.0_wp*PI/PER)*COS(2.0_wp*PI*t/PER)
    at = -AMP*(2.0_wp*PI/PER)**2*SIN(2.0_wp*PI*t/PER)
    pq(1) = zt; pv(1) = vt; pa(1) = at
    CALL CD_HermiteCable_Dyn_Step(model, DT, 50, 1.0e-5_wp, es, em, &
                                  pres_dofs=pdof, pres_q=pq, pres_v=pv, pres_a=pa)
    IF (es /= CD_HCDYN_OK) THEN
      CALL require(.FALSE., 'arbiter step stalled: '//TRIM(em)); EXIT
    END IF
    IF (t >= T_SCORE) THEN
      mnorm = SQRT(model%q(4)**2 + model%q(5)**2 + model%q(6)**2)
      t_meas = EA*(mnorm - 1.0_wp)
      ! closed form at the same instant: T = L (w + m a + ct |v| v); a positive-down heave pulls
      ! the top up -> a(t) with the -z inertia sign: the line accelerating UP (+z) needs EXTRA top
      ! tension, so T = L (w + m_lin*a_z(t) + ct*|v_z|*v_z(t)) with a_z = at, v_z = vt (both +z up):
      t_cf = L*(w_sub + MLIN*at + ct_coef*ABS(vt)*vt)
      err_pw = MAX(err_pw, ABS(t_meas - t_cf))
      tmax_m = MAX(tmax_m, t_meas); tmin_m = MIN(tmin_m, t_meas)
      tmax_cf = MAX(tmax_cf, t_cf); tmin_cf = MIN(tmin_cf, t_cf)
    END IF
  END DO
  CALL require(es == CD_HCDYN_OK, 'all arbiter steps converged')

  WRITE (*, '(A,F10.2,A,F10.2,A)') '  [arbiter] measured  T_top max/min = ', tmax_m, ' / ', tmin_m, ' N'
  WRITE (*, '(A,F10.2,A,F10.2,A)') '  [arbiter] closed-form  max/min    = ', tmax_cf, ' / ', tmin_cf, ' N'
  WRITE (*, '(A,F8.3,A,F8.2,A)') '  [arbiter] pointwise |T - T_cf| max = ', &
    100.0_wp*err_pw/swing_cf, '% of the dynamic swing scale (', swing_cf, ' N)'
  CALL require(err_pw/swing_cf < 0.02_wp, 'CableDyn matches the closed form pointwise (<2% of the swing)')
  CALL require(ABS(tmax_m - tmax_cf)/swing_cf < 0.02_wp, 'tension max matches the closed form')
  CALL require(ABS(tmin_m - tmin_cf)/swing_cf < 0.02_wp, 'tension min matches the closed form')

  CALL CD_HermiteCable_Dyn_End(model)
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: axial-drag tension transfer matches the 1D closed form (skin pi*d convention)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_hermite_axial_drag_arbiter
