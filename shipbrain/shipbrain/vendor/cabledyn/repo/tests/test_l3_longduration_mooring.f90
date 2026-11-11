! File: tests/test_l3_longduration_mooring.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l3_longduration_mooring
  !! L3 LONG-DURATION dynamic mooring parity vs OrcaFlex 11.6c -- the 1-hour VolturnUS-S run,
  !! scored on the RESPONSE, not just the wall-clock. One IEA-15MW VolturnUS-S all-chain catenary
  !! line (R4 studless, volume-equivalent OD 0.333 m, 685 kg/m, EA 3.27e9 N, 850 m; relative frame:
  !! fairlead at the origin with the free surface at z = +14, anchor on the seabed at
  !! (779.6, 0, -186)), the fairlead driven for ONE HOUR by a two-component harmonic representative
  !! of slow-drift + wave-frequency platform motion:
  !!   surge x_f(t) = 5.0 sin(2 pi t / 90) m,   heave z_f(t) = 2.0 sin(2 pi t / 12) m.
  !! Production configuration: dt = 0.1 s, rho_inf = 0.4, modified Newton, MoorDyn BA = -1 zeta
  !! axial damping, Morison drag (Cdn 1.37 / Cdt 0.64, the L2-2 OrcaFlex-matched chain set), added
  !! mass (Can 1 / Cat 0), buoyancy recovery, penalty seabed (kBot 3e6 Pa/m), TENSION-ONLY
  !! elements (a chain carries no compression; the +5 m surge phase slackens the line).
  !!
  !! OrcaFlex reference (OrcFxAPI 11.6c, validation/scripts/orcaflex_longduration_mooring.py, STILL water forced,
  !! probed End B drive exact at +/-5.000 / +/-2.000 m AND phase-matched to sin(omega t) -- the
  !! OrcaFlex harmonic phase lags are set to 90 deg because its harmonics are cosine-like at zero
  !! phase, and the probed drive phase reads -0.35 / -0.88 deg from pure sin; implicit dt 0.1 s,
  !! 200 s build-up + 3600 s, scored on [200, 3600]; OrcaFlex carries no line structural damping --
  !! the BA config asymmetry is the same convention the L2-2 parity used):
  !!   static fairlead tension 2427.011 kN, mean 2439.385 kN, std 206.079 kN,
  !!   min / max 2057.857 / 2850.911 kN,
  !!   Fourier amplitude 228.569 kN at 90 s, 178.796 kN at 12 s (integer-multiple windows).
  !!
  !! CableDyn scores the IDENTICAL window [200, 3600] s (drive phase-aligned with the reference:
  !! both drives run sin(omega t) from t = 0, so every statistic samples the same 90 s + 12 s beat
  !! phases; the half-cosine ramp ends at t = 100 s, well before scoring), with the same
  !! integer-multiple Fourier windows ([270, 3600] for 90 s, [204, 3600] for 12 s). Wall-clock is
  !! reported informationally.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, &
                           CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve_Continuation, CD_STATIC_OK
  USE CableDyn_Damping, ONLY: CD_Resolve_Legacy_BA, CD_Cable_Element_Damping_Tension, CD_DAMP_OK
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_Step_Model, CD_Get_Model_State, &
                            CD_End_Model, CD_Get_Model_EndForces, CD_MODEL_OK
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793_wp, G = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: HSPAN = 779.6_wp, DEPTH = 186.0_wp, WLINE = 14.0_wp, KBOT = 3.0e6_wp
  REAL(wp), PARAMETER :: LEN = 850.0_wp, EA0 = 3.27e9_wp, MASS0 = 685.0_wp, DIAM0 = 0.333_wp
  REAL(wp), PARAMETER :: CDN = 1.37_wp, CDT = 0.64_wp, CAN = 1.0_wp, CAT = 0.0_wp
  INTEGER, PARAMETER :: NSEG = 50
  REAL(wp), PARAMETER :: AX = 5.0_wp, T1 = 90.0_wp, AZ = 2.0_wp, T2 = 12.0_wp
  REAL(wp), PARAMETER :: DT = 0.1_wp, T_END = 3600.0_wp, T_SCORE = 200.0_wp
  REAL(wp), PARAMETER :: T_RAMP = 100.0_wp   ! rest-consistent half-cosine amplitude ramp
  ! OrcaFlex 11.6c reference (validation/scripts/orcaflex_longduration_mooring.py; see header)
  REAL(wp), PARAMETER :: REF_STATIC = 2427.011_wp, REF_MEAN = 2439.385_wp, REF_STD = 206.079_wp
  REAL(wp), PARAMETER :: REF_MIN = 2057.857_wp, REF_MAX = 2850.911_wp
  REAL(wp), PARAMETER :: REF_A90 = 228.569_wp, REF_A12 = 178.796_wp

  TYPE(CD_LineType) :: lts(1)
  TYPE(CD_LineSection) :: secs(1)
  TYPE(CableSolverConfig) :: scfg
  TYPE(GenAlphaConfig) :: dcfg
  TYPE(CD_ModelType) :: model
  INTEGER, ALLOCATABLE :: conn(:, :), fixed(:)
  REAL(wp), ALLOCATABLE :: l0(:), ea(:), mpl(:), diam(:), kn(:), w(:), f_ext(:), load(:, :)
  REAL(wp), ALLOCATABLE :: q0(:), q(:), v(:), a(:), tension(:), td(:), ba(:), fluidv(:, :), waterline(:)
  REAL(wp), ALLOCATABLE :: pq(:), pv(:), pa(:)
  REAL(wp) :: anchor(3), fairlead(3), factors(4), h, gl, ba1
  REAL(wp) :: t, om1, om2, fl_ten, fair_static, ramp, dramp, ddramp
  REAL(wp) :: ssum, ssq, smin, smax, c90, s90, c12, s12, t_lo90, t_lo12
  REAL(wp) :: mean, std, a90, a12
  ! statistics of the FairTen channel (the line-end force on the fairlead)
  REAL(wp) :: csum, csq, cmin, cmax, cten, cmean, cstd, f_first(3), f_last(3)
  REAL(wp) :: cc90, cs90, cc12, cs12, ca90, ca12
  INTEGER :: ne, nn, ndof, i, k, es, step, nstep, nacc, n90, n12, nf
  INTEGER(8) :: clk0, clk1, clkrate
  LOGICAL :: conv, st, af
  INTEGER :: n_iter, n_stages
  CHARACTER(200) :: em
  INTEGER :: nfail

  nfail = 0
  factors = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
  om1 = 2.0_wp*PI/T1; om2 = 2.0_wp*PI/T2
  ne = NSEG; nn = ne + 1; ndof = 3*nn
  anchor = [HSPAN, 0.0_wp, -DEPTH]; fairlead = [0.0_wp, 0.0_wp, 0.0_wp]

  lts(1) = CD_LineType(ea=EA0, mass_per_length=MASS0, diameter=DIAM0)
  secs(1) = CD_LineSection(line_type=1, length=LEN, n_segments=ne)
  CALL CD_Build_Line_Mesh(secs, lts, .TRUE., conn, l0, ea, mpl, diam, es, em)
  CALL require(es == CD_LINE_OK, 'build: '//TRIM(em))
  CALL CD_Resolve_Legacy_BA(-1.0_wp, l0(1), EA0, MASS0, ba1, es, em)
  CALL require(es == CD_DAMP_OK, 'ba: '//TRIM(em))
  CALL CD_Nodal_Seabed_Stiffness(KBOT, diam, l0, kn, es, em)
  CALL require(es == CD_LINE_OK, 'kn: '//TRIM(em))

  ALLOCATE (w(ne), f_ext(ndof), load(3, ne), q0(ndof), q(ndof), tension(ne), td(ne), ba(ne), &
            fluidv(3, nn), waterline(nn))
  ba = ba1
  fluidv = 0.0_wp
  waterline = WLINE                          ! free surface at z = +14 in the fairlead-origin frame
  CALL CD_Submerged_Weight(mpl, diam, RHO, G, w, es, em)
  CALL require(es == 0, 'weight')
  DO i = 1, ne
    load(:, i) = [0.0_wp, 0.0_wp, -w(i)]
  END DO
  CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
  CALL require(es == 0, 'load')
  CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, q0, h, gl, es, em)
  CALL require(es == CD_CAT_OK, 'seed')

  ALLOCATE (fixed(6 + (ne - 1)))
  fixed(1:3) = [1, 2, 3]; k = 3
  DO i = 2, ne
    k = k + 1; fixed(k) = 3*i - 1
  END DO
  fixed(k + 1:k + 3) = [ndof - 2, ndof - 1, ndof]
  CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .TRUE., f_ext, fixed, scfg, factors, &
                                          q, conv, st, af, n_iter, n_stages, es, em, &
                                          seabed_z_floor=-DEPTH, seabed_kn=kn)
  CALL require(es == CD_STATIC_OK .AND. conv, 'static IC')
  CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, nn]), conn, l0, ea, .TRUE., tension, es, em)
  CALL require(es == 0, 'static tension')
  fair_static = tension(ne)*1.0e-3_wp
  WRITE (*, '(A,F10.3,A,F10.3,A,F6.2,A)') '  [L3-long] static fairlead = ', fair_static, &
    ' kN   OrcaFlex ', REF_STATIC, '   err ', 100.0_wp*ABS(fair_static - REF_STATIC)/REF_STATIC, '%'

  ALLOCATE (v(ndof), a(ndof), pq(ndof), pv(ndof), pa(ndof))
  dcfg%rho_inf = 0.4_wp                      ! production mooring setting
  dcfg%modified_newton = .FALSE.             ! full Newton: the +/-5 m surge works the taut branch
  !                                            through strong geometric stiffening each cycle
  v = 0.0_wp
  CALL CD_Init_Model(model, q, v, conn, l0, ea, mpl, .TRUE., f_ext, fixed, dcfg, es, em, &
                     seabed_z_floor=-DEPTH, seabed_kn=kn, ba=ba, &
                     fluid_velocity=fluidv, drag_waterline_z=waterline, drag_rho=RHO, &
                     drag_diameter=DIAM0, drag_cdn=CDN, drag_cdt=CDT, &
                     buoyancy_waterline_z=waterline, buoyancy_rho=RHO, &
                     buoyancy_diameter=DIAM0, buoyancy_gravity=G, &
                     added_mass_waterline_z=waterline, added_mass_rho=RHO, &
                     added_mass_diameter=DIAM0, added_mass_can=CAN, added_mass_cat=CAT)
  CALL require(es == CD_MODEL_OK, 'model init: '//TRIM(em))
  CALL CD_Get_Model_State(model, q, v, a, es, em)
  CALL require(es == CD_MODEL_OK, 'state0')

  ! Fourier windows: the largest integer multiple of each period ending at T_END within the window.
  n90 = INT((T_END - T_SCORE)/T1); t_lo90 = T_END - REAL(n90, wp)*T1
  n12 = INT((T_END - T_SCORE)/T2); t_lo12 = T_END - REAL(n12, wp)*T2

  ssum = 0.0_wp; ssq = 0.0_wp; smin = HUGE(1.0_wp); smax = -HUGE(1.0_wp); nacc = 0
  csum = 0.0_wp; csq = 0.0_wp; cmin = HUGE(1.0_wp); cmax = -HUGE(1.0_wp)
  c90 = 0.0_wp; s90 = 0.0_wp; c12 = 0.0_wp; s12 = 0.0_wp; nf = 0
  cc90 = 0.0_wp; cs90 = 0.0_wp; cc12 = 0.0_wp; cs12 = 0.0_wp
  CALL SYSTEM_CLOCK(clk0, clkrate)
  nstep = NINT(T_END/DT)
  DO step = 1, nstep
    t = REAL(step, wp)*DT
    ! Rest-consistent half-cosine amplitude ramp r(t) over T_RAMP (r(0)=r'(0)=r''(0)=0 within
    ! round-off), with the exact product-rule velocity/acceleration.
    IF (t < T_RAMP) THEN
      ramp = 0.5_wp*(1.0_wp - COS(PI*t/T_RAMP))
      dramp = 0.5_wp*(PI/T_RAMP)*SIN(PI*t/T_RAMP)
      ddramp = 0.5_wp*(PI/T_RAMP)**2*COS(PI*t/T_RAMP)
    ELSE
      ramp = 1.0_wp; dramp = 0.0_wp; ddramp = 0.0_wp
    END IF
    pq = q; pv = 0.0_wp; pa = 0.0_wp
    pq(ndof - 2) = fairlead(1) + ramp*AX*SIN(om1*t)
    pv(ndof - 2) = dramp*AX*SIN(om1*t) + ramp*AX*om1*COS(om1*t)
    pa(ndof - 2) = ddramp*AX*SIN(om1*t) + 2.0_wp*dramp*AX*om1*COS(om1*t) - ramp*AX*om1*om1*SIN(om1*t)
    pq(ndof) = fairlead(3) + ramp*AZ*SIN(om2*t)
    pv(ndof) = dramp*AZ*SIN(om2*t) + ramp*AZ*om2*COS(om2*t)
    pa(ndof) = ddramp*AZ*SIN(om2*t) + 2.0_wp*dramp*AZ*om2*COS(om2*t) - ramp*AZ*om2*om2*SIN(om2*t)
    CALL CD_Step_Model(model, DT, conv, st, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
    IF (es /= CD_MODEL_OK .OR. .NOT. conv) THEN
      WRITE (*, '(A,F10.3,A,L2,A,I0,A)') '  [L3-long] FAILED at t = ', t, '  conv=', conv, '  es=', es, &
        '  msg: '//TRIM(em)
      CALL require(.FALSE., 'step failed/non-convergent'); EXIT
    END IF
    CALL CD_Get_Model_State(model, q, v, a, es, em)
    IF (t >= T_SCORE) THEN
      CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, nn]), conn, l0, ea, .TRUE., tension, es, em)
      CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td, es, em)
      fl_ten = ABS(tension(ne) + td(ne))*1.0e-3_wp
      ssum = ssum + fl_ten; ssq = ssq + fl_ten*fl_ten; nacc = nacc + 1
      smin = MIN(smin, fl_ten); smax = MAX(smax, fl_ten)
      CALL CD_Get_Model_EndForces(model, f_first, f_last, es, em)
      cten = NORM2(f_last)*1.0e-3_wp
      csum = csum + cten; csq = csq + cten*cten
      cmin = MIN(cmin, cten); cmax = MAX(cmax, cten)
      IF (t >= t_lo90) THEN
        c90 = c90 + fl_ten*COS(om1*t); s90 = s90 + fl_ten*SIN(om1*t); nf = nf + 1
        cc90 = cc90 + cten*COS(om1*t); cs90 = cs90 + cten*SIN(om1*t)
      END IF
      IF (t >= t_lo12) THEN
        c12 = c12 + fl_ten*COS(om2*t); s12 = s12 + fl_ten*SIN(om2*t)
        cc12 = cc12 + cten*COS(om2*t); cs12 = cs12 + cten*SIN(om2*t)
      END IF
    END IF
  END DO
  CALL SYSTEM_CLOCK(clk1)
  mean = ssum/REAL(MAX(nacc, 1), wp)
  std = SQRT(MAX(ssq/REAL(MAX(nacc, 1), wp) - mean*mean, 0.0_wp))
  a90 = 2.0_wp*SQRT(c90*c90 + s90*s90)/REAL(MAX(nf, 1), wp)
  cmean = csum/REAL(MAX(nacc, 1), wp)
  cstd = SQRT(MAX(csq/REAL(MAX(nacc, 1), wp) - cmean*cmean, 0.0_wp))
  a12 = 2.0_wp*SQRT(c12*c12 + s12*s12)/REAL(NINT((T_END - t_lo12)/DT), wp)
  ca90 = 2.0_wp*SQRT(cc90*cc90 + cs90*cs90)/REAL(MAX(nf, 1), wp)
  ca12 = 2.0_wp*SQRT(cc12*cc12 + cs12*cs12)/REAL(NINT((T_END - t_lo12)/DT), wp)

  WRITE (*, '(A,F8.1,A)') '  [L3-long] CableDyn 1-hour march wall-clock = ', &
    REAL(clk1 - clk0, wp)/REAL(clkrate, wp), ' s'
  WRITE (*, '(A,F10.3,A,F10.3,A,F6.2,A)') '  [L3-long] tension mean = ', mean, '   OrcaFlex ', REF_MEAN, &
    '   err ', 100.0_wp*ABS(mean - REF_MEAN)/REF_MEAN, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A,F6.2,A)') '  [L3-long] tension std  = ', std, '   OrcaFlex ', REF_STD, &
    '   err ', 100.0_wp*ABS(std - REF_STD)/REF_STD, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A,F6.2,A)') '  [L3-long] tension min  = ', smin, '   OrcaFlex ', REF_MIN, &
    '   err ', 100.0_wp*ABS(smin - REF_MIN)/REF_MIN, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A,F6.2,A)') '  [L3-long] tension max  = ', smax, '   OrcaFlex ', REF_MAX, &
    '   err ', 100.0_wp*ABS(smax - REF_MAX)/REF_MAX, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A,F6.2,A)') '  [L3-long] Fourier @90s = ', a90, '   OrcaFlex ', REF_A90, &
    '   err ', 100.0_wp*ABS(a90 - REF_A90)/REF_A90, '%'
  WRITE (*, '(A,F10.3,A,F10.3,A,F6.2,A)') '  [L3-long] Fourier @12s = ', a12, '   OrcaFlex ', REF_A12, &
    '   err ', 100.0_wp*ABS(a12 - REF_A12)/REF_A12, '%'

  ! Gates: calibrated from the observed parity (VALIDATION.md); tension statistics are the axial
  ! fatigue drivers, so mean tight, distribution moments and extremes with honest margin.
  ! Observed parity: static 1.28% (the committed static-gate offset), mean 1.41%, std 0.18%,
  ! min 2.14%, max 1.14%, Fourier 1.13% / 1.75% -- the DYNAMIC content (std, spectral amplitudes)
  ! is essentially exact; the mean/extremes carry the documented static offset. Gates ~2-3x margin.
  WRITE (*, '(A,4(F10.3,A))') '  [L3-long] FairTen channel mean/std/min/max = ', cmean, ' / ', cstd, ' / ', &
    cmin, ' / ', cmax, ' kN'
  WRITE (*, '(A,4(F6.2,A))') '  [L3-long] FairTen channel err vs OrcaFlex (%) = ', &
    100.0_wp*ABS(cmean - REF_MEAN)/REF_MEAN, ' / ', 100.0_wp*ABS(cstd - REF_STD)/REF_STD, ' / ', &
    100.0_wp*ABS(cmin - REF_MIN)/REF_MIN, ' / ', 100.0_wp*ABS(cmax - REF_MAX)/REF_MAX, ''
  WRITE (*, '(A,2(F10.3,A),2(F6.2,A))') '  [L3-long] FairTen channel Fourier @90s/@12s = ', ca90, ' / ', ca12, &
    ' kN; err vs OrcaFlex (%) = ', 100.0_wp*ABS(ca90 - REF_A90)/REF_A90, ' / ', 100.0_wp*ABS(ca12 - REF_A12)/REF_A12, ''
  CALL require(ABS(cmean - REF_MEAN)/REF_MEAN < 0.02_wp, 'FairTen channel mean within 2%')
  CALL require(ABS(cstd - REF_STD)/REF_STD < 0.03_wp, 'FairTen channel std within 3%')
  CALL require(ABS(cmin - REF_MIN)/REF_MIN < 0.05_wp, 'FairTen channel min within 5%')
  CALL require(ABS(cmax - REF_MAX)/REF_MAX < 0.03_wp, 'FairTen channel max within 3%')
  CALL require(ABS(fair_static - REF_STATIC)/REF_STATIC < 0.02_wp, 'static fairlead within 2%')
  CALL require(ABS(mean - REF_MEAN)/REF_MEAN < 0.02_wp, 'mean tension within 2%')
  CALL require(ABS(std - REF_STD)/REF_STD < 0.03_wp, 'tension std within 3%')
  CALL require(ABS(smin - REF_MIN)/REF_MIN < 0.05_wp, 'tension min within 5%')
  CALL require(ABS(smax - REF_MAX)/REF_MAX < 0.03_wp, 'tension max within 3%')
  CALL require(ABS(a90 - REF_A90)/REF_A90 < 0.05_wp, 'slow-drift Fourier amplitude within 5%')
  CALL require(ABS(a12 - REF_A12)/REF_A12 < 0.05_wp, 'wave-frequency Fourier amplitude within 5%')

  CALL CD_End_Model(model, es, em)
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: 1-hour VolturnUS-S mooring dynamic parity vs OrcaFlex (scored response + wall-clock)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l3_longduration_mooring
