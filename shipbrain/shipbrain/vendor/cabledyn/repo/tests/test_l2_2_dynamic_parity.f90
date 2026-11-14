! File: tests/test_l2_2_dynamic_parity.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l2_2_dynamic_parity
  !! L2-2 dynamic external-reference / OrcaFlex parity on the Fortran core. Each grounded chain
  !! (WD0050 41-segment, WD0200 76-segment, WD0600 170-segment) is driven by the prescribed ZZP1 fairlead
  !! heave z = A sin(2 pi t / 10) (A1 = 2 m, A2 = 5 m) in still water, with the full
  !! dynamic load set composed into the implicit generalised-alpha step: Morison drag +
  !! added mass + legacy axial (BA) damping + buoyancy recovery (the surface-piercing
  !! fairlead) + penalty seabed, on top of the submerged self-weight.
  !! The fairlead-tension variation (elastic + Td) is scored against OrcaFlex through the
  !! summary values of its fairlead-tension series (tests/data/l2_2_dynamic_refs/
  !! orcaflex_summary.txt, reduced by validation/scripts/l2_2_orcaflex_summary.py from the
  !! OrcaFlex series MoorDyn-C distributes): mean, standard deviation, maximum and minimum over
  !! the 20 s window, and the first three harmonics of the 0.1 Hz drive (amplitude and phase).
  !! Each is compared as a variation about the static tension, normalised by the reference's
  !! peak-to-peak scale 2 max_t |dFair_ref|, with the pointwise gate's 0.15 as the acceptance;
  !! the dominant first harmonic is also held to 25% of its own amplitude.
  !!
  !! An optional second argument perturbs the run (ea=<factor> scales EA, cdn=<factor> scales
  !! the normal drag) so the non-vacuity check can show that the summary gate rejects a
  !! perturbed model.
  !!
  !! The analytic sinusoid is warmed up for 60 s before t=0. The Fortran penalty
  !! seabed is normal-only (no c_n damper), so a small touchdown-region difference
  !! from a damped seabed contact model is expected and absorbed by
  !! the 15% band.
  !!
  !! tension_only = .FALSE. (the validated L2-1 static path for these grounded chains):
  !! these ZZP1 amplitudes keep the SUSPENDED span in tension throughout -- the OrcaFlex
  !! fairlead minimum is 368 kN even at A2, so the line never snaps slack (unlike the
  !! L5 snap-load gate, which is genuinely tension-only). The grounded run sits at ~0
  !! tension on the seabed exactly as in L2-1, which matches the reference to <1.6% with this
  !! flag; the dynamic response is the same under .TRUE. since no suspended element
  !! crosses into compression. This is NOT the snap regime, so .FALSE. is correct here.
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
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  REAL(wp), PARAMETER :: GRAV = 9.80665_wp, RHO = 1025.0_wp
  REAL(wp), PARAMETER :: EA0 = 1.674e9_wp, MASS0 = 390.0_wp, DIAM0 = 0.252_wp
  REAL(wp), PARAMETER :: CDN = 1.37_wp, CDT = 0.64_wp, CAN = 1.0_wp, CAT = 0.0_wp
  REAL(wp), PARAMETER :: KN_BASE = 1.0e5_wp
  REAL(wp), PARAMETER :: PERIOD = 10.0_wp, PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: DT = 0.05_wp, WARMUP = 60.0_wp, SCORE_WINDOW = 20.0_wp, REF_DT = 0.1_wp
  REAL(wp), PARAMETER :: GATE = 0.15_wp, GATE_H1 = 0.25_wp
  INTEGER, PARAMETER :: NSUM = 10   ! mean std max min a1 ph1 a2 ph2 a3 ph3

  INTEGER :: nfail
  CHARACTER(32) :: selected_cell
  REAL(wp) :: ea_factor, cdn_factor
  nfail = 0
  CALL read_selected_cell(selected_cell)
  CALL read_perturbation(ea_factor, cdn_factor)

  !          label     anchor x   depth    total L   n_seg  amp
  IF (should_run_cell(selected_cell, 'WD0050/A1')) &
    CALL run_cell('WD0050/A1', 400.0_wp, 50.0_wp, 410.0_wp, 41, 2.0_wp)
  IF (should_run_cell(selected_cell, 'WD0050/A2')) &
    CALL run_cell('WD0050/A2', 400.0_wp, 50.0_wp, 410.0_wp, 41, 5.0_wp)
  IF (should_run_cell(selected_cell, 'WD0200/A1')) &
    CALL run_cell('WD0200/A1', 700.0_wp, 200.0_wp, 760.0_wp, 76, 2.0_wp)
  IF (should_run_cell(selected_cell, 'WD0200/A2')) &
    CALL run_cell('WD0200/A2', 700.0_wp, 200.0_wp, 760.0_wp, 76, 5.0_wp)
  IF (should_run_cell(selected_cell, 'WD0600/A1')) &
    CALL run_cell('WD0600/A1', 1500.0_wp, 600.0_wp, 1700.0_wp, 170, 2.0_wp)
  IF (should_run_cell(selected_cell, 'WD0600/A2')) &
    CALL run_cell('WD0600/A2', 1500.0_wp, 600.0_wp, 1700.0_wp, 170, 5.0_wp)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: L2-2 dynamic external/OrcaFlex fairlead-tension parity (within 15%)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE read_selected_cell(selected)
    CHARACTER(*), INTENT(OUT) :: selected
    CHARACTER(32) :: arg
    INTEGER :: narg

    selected = 'ALL'
    narg = COMMAND_ARGUMENT_COUNT()
    IF (narg == 0) RETURN
    CALL GET_COMMAND_ARGUMENT(1, arg)
    IF (LEN_TRIM(arg) > 0) selected = ADJUSTL(arg)
  END SUBROUTINE read_selected_cell

  SUBROUTINE read_perturbation(ea_f, cdn_f)
    !! Optional second argument: ea=<factor> or cdn=<factor> (the non-vacuity check).
    REAL(wp), INTENT(OUT) :: ea_f, cdn_f
    CHARACTER(64) :: arg
    INTEGER :: ios
    REAL(wp) :: f

    ea_f = 1.0_wp; cdn_f = 1.0_wp
    IF (COMMAND_ARGUMENT_COUNT() < 2) RETURN
    CALL GET_COMMAND_ARGUMENT(2, arg)
    arg = ADJUSTL(arg)
    READ (arg(INDEX(arg, '=') + 1:), *, IOSTAT=ios) f
    IF (ios /= 0 .OR. INDEX(arg, '=') == 0 .OR. .NOT. f > 0.0_wp) THEN
      WRITE (*, '(A,A)') 'FAIL: bad perturbation argument ', TRIM(arg); ERROR STOP 1
    END IF
    IF (arg(1:3) == 'ea=') THEN
      ea_f = f
    ELSE IF (arg(1:4) == 'cdn=') THEN
      cdn_f = f
    ELSE
      WRITE (*, '(A,A)') 'FAIL: bad perturbation argument ', TRIM(arg); ERROR STOP 1
    END IF
    WRITE (*, '(A,F6.3,A,F6.3)') 'PERTURBED RUN: EA x', ea_f, ', Cdn x', cdn_f
  END SUBROUTINE read_perturbation

  PURE LOGICAL FUNCTION should_run_cell(selected, label) RESULT(run)
    CHARACTER(*), INTENT(IN) :: selected, label

    run = TRIM(selected) == 'ALL' .OR. TRIM(selected) == TRIM(label)
  END FUNCTION should_run_cell

  PURE FUNCTION series_tag(label) RESULT(tag)
    !! Filesystem-safe tag for a cell label, e.g. 'WD0050/A1' -> 'WD0050_A1'.
    CHARACTER(*), INTENT(IN) :: label
    CHARACTER(LEN_TRIM(label)) :: tag
    INTEGER :: i
    tag = TRIM(label)
    DO i = 1, LEN(tag)
      IF (tag(i:i) == '/') tag(i:i) = '_'
    END DO
  END FUNCTION series_tag

  SUBROUTINE load_external_series(ext_file, label, ext_kn)
    !! Load a vendored MoorDyn-C v2.6.1 fairlead-tension series (2 columns: t, fairten_kN;
    !! '!'/'#' comments skipped), from tests/data/l2_2_external_refs/. Generated by
    !! validation/scripts/moordyn_c_driver.cpp via GetLineNodeTen(node 0), validated vs the closed-form catenary.
    CHARACTER(*), INTENT(IN) :: ext_file, label
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: ext_kn(:)
    CHARACTER(320) :: path
    CHARACTER(512) :: line
    INTEGER :: unit, ios, ipath, nrow
    REAL(wp) :: t, fair

    unit = -1
    ALLOCATE (ext_kn(256))
    DO ipath = 1, 2
      IF (ipath == 1) THEN
        path = '../tests/data/l2_2_external_refs/'//TRIM(ext_file)
      ELSE
        path = 'tests/data/l2_2_external_refs/'//TRIM(ext_file)
      END IF
      OPEN (NEWUNIT=unit, FILE=TRIM(path), STATUS='OLD', ACTION='READ', IOSTAT=ios)
      IF (ios == 0) EXIT
    END DO
    IF (ios /= 0) THEN
      CALL require(.FALSE., label//':external-reference-open')
      RETURN
    END IF
    nrow = 0
    DO
      READ (unit, '(A)', IOSTAT=ios) line
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        CALL require(.FALSE., label//':external-reference-read'); CLOSE (unit); RETURN
      END IF
      line = ADJUSTL(line)
      IF (LEN_TRIM(line) == 0) CYCLE
      IF (line(1:1) == '#' .OR. line(1:1) == '!') CYCLE
      READ (line, *, IOSTAT=ios) t, fair
      ! Validate t finiteness too: a NaN timestamp would slip past the
      ! ABS(t - grid) > tol timebase check below (NaN compares .FALSE.).
      IF (ios /= 0 .OR. .NOT. IEEE_IS_FINITE(t) .OR. .NOT. IEEE_IS_FINITE(fair)) THEN
        CALL require(.FALSE., label//':external-reference-read'); CLOSE (unit); RETURN
      END IF
      IF (nrow == SIZE(ext_kn)) CALL grow_reference(ext_kn)
      nrow = nrow + 1
      ! The series must sit exactly on the 0 : REF_DT : SCORE_WINDOW grid (row k at t=(k-1)*REF_DT);
      ! a wrong cadence or shifted start must fail the gate, not be scored against mismatched instants.
      IF (ABS(t - REAL(nrow - 1, wp)*REF_DT) > 1.0e-4_wp) THEN
        CALL require(.FALSE., label//':external-reference-timebase'); CLOSE (unit); RETURN
      END IF
      ext_kn(nrow) = fair
    END DO
    CLOSE (unit)
    CALL require(nrow >= 2, label//':external-reference-rows')
    ext_kn = ext_kn(:nrow)
  END SUBROUTINE load_external_series

  SUBROUTINE run_cell(label, anchor_x, depth, total_len, n_seg, amp)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: anchor_x, depth, total_len, amp
    INTEGER, INTENT(IN) :: n_seg
    INTEGER :: ne, nn, ndof, i, k, es, n_iter, n_stages, step, nstep, isamp, nsamp
    TYPE(CD_LineType) :: lts(1)
    TYPE(CD_LineSection) :: secs(1)
    INTEGER, ALLOCATABLE :: conn(:, :), fixed(:)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), mpl(:), diam(:), w(:), f_ext(:), load(:, :), q0(:), q(:), kn(:)
    REAL(wp), ALLOCATABLE :: v(:), a(:), pq(:), pv(:), pa(:), ba(:), fluidv(:, :), waterline(:)
    REAL(wp), ALLOCATABLE :: tension(:), td(:), fair_series(:), chan_series(:)
    REAL(wp) :: ref_sum(NSUM)
    REAL(wp) :: f_first(3), f_last(3), chan_static_kn
    REAL(wp) :: anchor(3), fairlead(3), h, gl, ba1, factors(4), omega
    REAL(wp) :: heave, vz, az, t_np1, tau, fl_ten, fair_static_kn, ref_static_kn, ref_amp
    LOGICAL  :: conv, st, af
    TYPE(CableSolverConfig) :: scfg
    TYPE(GenAlphaConfig) :: dcfg
    TYPE(CD_ModelType) :: model
    CHARACTER(200) :: em
    factors = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]
    omega = 2.0_wp*PI/PERIOD
    CALL load_reference_summary(label, ref_sum)
    IF (nfail > 0) RETURN
    nsamp = NINT(SCORE_WINDOW/REF_DT) + 1
    ALLOCATE (fair_series(nsamp), chan_series(nsamp))
    fair_series = -HUGE(1.0_wp)
    chan_series = -HUGE(1.0_wp)
    ref_static_kn = static_fairlead_reference(label)

    ne = n_seg; nn = ne + 1; ndof = 3*nn
    anchor = [anchor_x, 0.0_wp, -depth]; fairlead = [0.0_wp, 0.0_wp, 0.0_wp]

    ! --- mesh + per-element properties ---
    lts(1) = CD_LineType(ea=EA0*ea_factor, mass_per_length=MASS0, diameter=DIAM0)
    secs(1) = CD_LineSection(line_type=1, length=total_len, n_segments=ne)
    CALL CD_Build_Line_Mesh(secs, lts, .FALSE., conn, l0, ea, mpl, diam, es, em)
    CALL require(es == CD_LINE_OK, label//':build')
    CALL CD_Resolve_Legacy_BA(-1.0_wp, l0(1), EA0*ea_factor, MASS0, ba1, es, em)
    CALL require(es == CD_DAMP_OK, label//':ba')
    CALL CD_Nodal_Seabed_Stiffness(KN_BASE, diam, l0, kn, es, em)
    CALL require(es == CD_LINE_OK, label//':kn')

    ! --- self-weight + static equilibrium IC (catenary seed + continuation + seabed) ---
    ALLOCATE (w(ne), f_ext(ndof), load(3, ne), q0(ndof), q(ndof), tension(ne), td(ne), ba(ne), &
              fluidv(3, nn), waterline(nn))
    ba = ba1
    fluidv = 0.0_wp
    waterline = 0.0_wp
    CALL CD_Submerged_Weight(mpl, diam, RHO, GRAV, w, es, em)
    CALL require(es == 0, label//':weight')
    DO i = 1, ne
      load(:, i) = [0.0_wp, 0.0_wp, -w(i)]
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    CALL require(es == 0, label//':load')
    CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, q0, h, gl, es, em)
    CALL require(es == CD_CAT_OK, label//':seed')

    ALLOCATE (fixed(6 + (ne - 1)))
    fixed(1:3) = [1, 2, 3]; k = 3
    DO i = 2, ne
      k = k + 1; fixed(k) = 3*i - 1
    END DO
    fixed(k + 1:k + 3) = [ndof - 2, ndof - 1, ndof]
    CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, .FALSE., f_ext, fixed, scfg, factors, &
                                            q, conv, st, af, n_iter, n_stages, es, em, &
                                            seabed_z_floor=-depth, seabed_kn=kn)
    CALL require(es == CD_STATIC_OK .AND. conv, label//':static-IC')
    CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, nn]), conn, l0, ea, .FALSE., tension, es, em)
    CALL require(es == 0, label//':static-tension')
    fair_static_kn = tension(ne)*1.0e-3_wp

    ! --- dynamic march with the prescribed ZZP1 heave through the production persistent model path ---
    ALLOCATE (v(ndof), a(ndof), pq(ndof), pv(ndof), pa(ndof))
    dcfg%rho_inf = 0.8_wp                 ! match the reference: the L2-2 deck leaves
    !                                       rho_inf at the bridge default 0.8, so the reference
    !                                       it scores against uses 0.8 -- tuning it here would
    !                                       change the numerical damping for every scored cell.
    dcfg%modified_newton = .TRUE.         ! reuse the (FD-hydro) tangent within a step
    v = 0.0_wp
    CALL CD_Init_Model(model, q, v, conn, l0, ea, mpl, .FALSE., f_ext, fixed, dcfg, es, em, &
                       seabed_z_floor=-depth, seabed_kn=kn, ba=ba, &
                       fluid_velocity=fluidv, drag_waterline_z=waterline, drag_rho=RHO, &
                       drag_diameter=DIAM0, drag_cdn=CDN*cdn_factor, drag_cdt=CDT, &
                       buoyancy_waterline_z=waterline, buoyancy_rho=RHO, &
                       buoyancy_diameter=DIAM0, buoyancy_gravity=GRAV, &
                       added_mass_waterline_z=waterline, added_mass_rho=RHO, &
                       added_mass_diameter=DIAM0, added_mass_can=CAN, added_mass_cat=CAT)
    CALL require(es == CD_MODEL_OK, label//':model-init: '//TRIM(em))
    IF (es /= CD_MODEL_OK) RETURN
    CALL CD_Get_Model_State(model, q, v, a, es, em)
    CALL require(es == CD_MODEL_OK, label//':model-state0: '//TRIM(em))
    IF (es /= CD_MODEL_OK) RETURN
    ! the FairTen channel (line-end force on the fairlead) at the static state
    CALL CD_Get_Model_EndForces(model, f_first, f_last, es, em)
    CALL require(es == CD_MODEL_OK, label//':end-force0: '//TRIM(em))
    chan_static_kn = NORM2(f_last)*1.0e-3_wp

    nstep = NINT((WARMUP + SCORE_WINDOW)/DT)
    DO step = 1, nstep
      tau = -WARMUP + REAL(step, wp)*DT
      t_np1 = tau
      CALL heave_kin(t_np1, amp, omega, heave, vz, az)
      pq = q; pv = 0.0_wp; pa = 0.0_wp     ! anchor + interior-y held at the static state
      pq(ndof) = fairlead(3) + heave; pv(ndof) = vz; pa(ndof) = az
      CALL CD_Step_Model(model, DT, conv, st, n_iter, es, em, prescribed_q=pq, prescribed_v=pv, prescribed_a=pa)
      CALL require(es == CD_MODEL_OK .AND. conv, label//':step')
      IF (es /= CD_MODEL_OK) RETURN
      CALL CD_Get_Model_State(model, q, v, a, es, em)
      CALL require(es == CD_MODEL_OK, label//':model-state-step')
      IF (es /= CD_MODEL_OK) RETURN
      IF (tau >= -1.0e-9_wp .AND. ABS(REAL(NINT(tau/REF_DT), wp)*REF_DT - tau) < 1.0e-8_wp) THEN
        CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, nn]), conn, l0, ea, .FALSE., tension, es, em)
        CALL CD_Cable_Element_Damping_Tension(q, v, conn, l0, ba, td, es, em)
        ! report the total as a MAGNITUDE |elastic + Td| -- the same quantity the
        ! external references report. BA
        ! damping can oppose/exceed the elastic tension on a fast stroke, so the signed
        ! sum could dip negative and inflate the range against a never-reported value.
        fl_ten = ABS(tension(ne) + td(ne))
        isamp = NINT(tau/REF_DT) + 1
        IF (isamp >= 1 .AND. isamp <= nsamp) fair_series(isamp) = fl_ten*1.0e-3_wp
        ! the FairTen channel: the force the line exerts on the fairlead (element tension with
        ! axial damping, plus the end node's weight, drag and seabed share)
        CALL CD_Get_Model_EndForces(model, f_first, f_last, es, em)
        CALL require(es == CD_MODEL_OK, label//':end-force: '//TRIM(em))
        IF (isamp >= 1 .AND. isamp <= nsamp) chan_series(isamp) = NORM2(f_last)*1.0e-3_wp
      END IF
    END DO

    CALL require(ALL(fair_series > -0.5_wp*HUGE(1.0_wp)), label//':all-reference-samples-filled')
    ref_amp = MAX(ref_sum(3) - ref_static_kn, ref_static_kn - ref_sum(4))
    CALL score_summary(label//':fairlead', fair_series, fair_static_kn, ref_sum, ref_static_kn, ref_amp)

    ! CableDyn vs MoorDyn-C v2.6.1 dynamic fairlead parity (pointwise variation metric; both
    ! series are centred on their own time mean, so a static offset does not enter).
    ! Statics agree to <0.5% (L2-1 / arbiter), so this scores a genuinely dynamic difference; the
    ! MoorDyn-C reference uses the validated GetLineNodeTen(node 0) fairlead readout.
    BLOCK
      REAL(wp), ALLOCATABLE :: ext_series(:)
      REAL(wp) :: ext_static, ext_amp, ext_err, fair_mean, chan_mean
      CALL load_external_series('EXT_'//series_tag(label)//'.txt', label, ext_series)
      ! Require the MoorDyn-C series to cover exactly the same sample window as fair_series
      ! (201 samples on the 0.1 s / 20 s grid); a truncated or wrong-cadence reference must fail
      ! the gate, not be silently scored on an overlapping prefix.
      CALL require(SIZE(ext_series) == SIZE(fair_series), label//':external-reference-sample-count')
      IF (nfail == 0) THEN
        ext_static = SUM(ext_series)/REAL(SIZE(ext_series), wp)
        ext_amp = nan_max_abs(ext_series - ext_static)
        CALL require(IEEE_IS_FINITE(ext_amp) .AND. ext_amp > 0.0_wp, label//':external-reference-range')
      END IF
      IF (nfail == 0) THEN
        fair_mean = SUM(fair_series)/REAL(SIZE(fair_series), wp)
        chan_mean = SUM(chan_series)/REAL(SIZE(chan_series), wp)
        ext_err = nan_max_abs((fair_series - fair_mean) - (ext_series - ext_static))/(2.0_wp*ext_amp)
        WRITE (*, '(A,A,F7.3,A)') label, '  vs MoorDyn-C variation metric = ', ext_err, ' (gate 0.150)'
        CALL require(ext_err <= GATE, label//':MoorDyn-C-parity-within-15pct')
        ! the same metric scored on the FairTen channel itself (the line-end force)
        ext_err = nan_max_abs((chan_series - chan_mean) - (ext_series - ext_static))/(2.0_wp*ext_amp)
        WRITE (*, '(A,A,F7.3,A)') label, '  FairTen channel vs MoorDyn-C variation metric = ', ext_err, &
          ' (gate 0.150)'
        CALL require(ext_err <= GATE, label//':FairTen-channel-MoorDyn-C-parity-within-15pct')
        CALL score_summary(label//':FairTen-channel', chan_series, chan_static_kn, ref_sum, ref_static_kn, &
                           ref_amp)
      END IF
    END BLOCK

    CALL CD_End_Model(model, es, em)
    CALL require(es == CD_MODEL_OK, label//':model-end')
    DEALLOCATE (conn, l0, ea, mpl, diam, w, f_ext, load, q0, q, kn, fixed, &
                v, a, pq, pv, pa, ba, fluidv, waterline, tension, td, fair_series, chan_series)
  END SUBROUTINE run_cell

  SUBROUTINE load_reference_summary(label, ref_sum)
    !! Read the OrcaFlex summary row of one cell from tests/data/l2_2_dynamic_refs/orcaflex_summary.txt
    !! (cell tag, then mean std max min a1 ph1 a2 ph2 a3 ph3; kN and degrees; '!' comments).
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(OUT) :: ref_sum(NSUM)
    CHARACTER(320) :: path
    CHARACTER(512) :: line
    CHARACTER(32) :: tag
    INTEGER :: unit, ios, ipath, nfound

    ref_sum = 0.0_wp
    unit = -1
    DO ipath = 1, 2
      IF (ipath == 1) THEN
        path = '../tests/data/l2_2_dynamic_refs/orcaflex_summary.txt'
      ELSE
        path = 'tests/data/l2_2_dynamic_refs/orcaflex_summary.txt'
      END IF
      OPEN (NEWUNIT=unit, FILE=TRIM(path), STATUS='OLD', ACTION='READ', IOSTAT=ios)
      IF (ios == 0) EXIT
    END DO
    IF (ios /= 0) THEN
      CALL require(.FALSE., label//':reference-open')
      RETURN
    END IF

    nfound = 0
    DO
      READ (unit, '(A)', IOSTAT=ios) line
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        CALL require(.FALSE., label//':reference-read'); CLOSE (unit); RETURN
      END IF
      line = ADJUSTL(line)
      IF (LEN_TRIM(line) == 0) CYCLE
      IF (line(1:1) == '#' .OR. line(1:1) == '!') CYCLE
      READ (line, *, IOSTAT=ios) tag
      IF (ios /= 0) THEN
        CALL require(.FALSE., label//':reference-read'); CLOSE (unit); RETURN
      END IF
      IF (TRIM(tag) /= series_tag(label)) CYCLE
      READ (line, *, IOSTAT=ios) tag, ref_sum
      IF (ios /= 0 .OR. .NOT. ALL(IEEE_IS_FINITE(ref_sum))) THEN
        CALL require(.FALSE., label//':reference-read'); CLOSE (unit); RETURN
      END IF
      nfound = nfound + 1
    END DO
    CLOSE (unit)
    CALL require(nfound == 1, label//':reference-row-unique')
    ! a usable summary: positive spread, max above min, positive harmonic amplitudes
    CALL require(ref_sum(2) > 0.0_wp .AND. ref_sum(3) > ref_sum(4) .AND. &
                 ALL(ref_sum(5:9:2) > 0.0_wp), label//':reference-range')
  END SUBROUTINE load_reference_summary

  PURE SUBROUTINE series_summary(y, sm)
    !! mean, std (population), max and min over all samples; harmonic k of the drive period,
    !! a_k cos(2 pi k t / PERIOD + ph_k), from the whole periods (all samples but the last).
    REAL(wp), INTENT(IN) :: y(:)
    REAL(wp), INTENT(OUT) :: sm(NSUM)
    REAL(wp) :: mw, c, s, tt
    INTEGER :: n, nw, i, k

    n = SIZE(y); nw = n - 1
    sm(1) = SUM(y)/REAL(n, wp)
    sm(2) = SQRT(SUM((y - sm(1))**2)/REAL(n, wp))
    sm(3) = MAXVAL(y); sm(4) = MINVAL(y)
    mw = SUM(y(1:nw))/REAL(nw, wp)
    DO k = 1, 3
      c = 0.0_wp; s = 0.0_wp
      DO i = 1, nw
        tt = REAL(i - 1, wp)*REF_DT
        c = c + (y(i) - mw)*COS(2.0_wp*PI*REAL(k, wp)*tt/PERIOD)
        s = s - (y(i) - mw)*SIN(2.0_wp*PI*REAL(k, wp)*tt/PERIOD)
      END DO
      c = 2.0_wp*c/REAL(nw, wp); s = 2.0_wp*s/REAL(nw, wp)
      sm(3 + 2*k) = SQRT(c*c + s*s)
      sm(4 + 2*k) = ATAN2(s, c)*180.0_wp/PI
    END DO
  END SUBROUTINE series_summary

  SUBROUTINE score_summary(label, series, static_kn, ref_sum, ref_static_kn, ref_amp)
    !! Compare a CableDyn series with the OrcaFlex summary: every statistic as a variation about
    !! the static tension over the reference peak-to-peak scale 2 ref_amp (gate 0.15), and the
    !! first harmonic also over its own amplitude (gate 0.25).
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), INTENT(IN) :: series(:), static_kn, ref_sum(NSUM), ref_static_kn, ref_amp
    REAL(wp) :: sm(NSUM), e(7), den, h1_rel
    COMPLEX(wp) :: z, zr
    INTEGER :: k
    CHARACTER(8), PARAMETER :: names(7) = [CHARACTER(8) :: 'mean', 'std', 'max', 'min', 'h1', 'h2', 'h3']

    CALL series_summary(series, sm)
    den = 2.0_wp*ref_amp
    e(1) = ABS((sm(1) - static_kn) - (ref_sum(1) - ref_static_kn))/den
    e(2) = ABS(sm(2) - ref_sum(2))/den
    e(3) = ABS((sm(3) - static_kn) - (ref_sum(3) - ref_static_kn))/den
    e(4) = ABS((sm(4) - static_kn) - (ref_sum(4) - ref_static_kn))/den
    DO k = 1, 3
      z = CMPLX(sm(3 + 2*k)*COS(sm(4 + 2*k)*PI/180.0_wp), sm(3 + 2*k)*SIN(sm(4 + 2*k)*PI/180.0_wp), wp)
      zr = CMPLX(ref_sum(3 + 2*k)*COS(ref_sum(4 + 2*k)*PI/180.0_wp), &
                 ref_sum(3 + 2*k)*SIN(ref_sum(4 + 2*k)*PI/180.0_wp), wp)
      e(4 + k) = ABS(z - zr)/den
      IF (k == 1) h1_rel = ABS(z - zr)/ABS(zr)
    END DO
    WRITE (*, '(A,A,7(1X,A,F6.3),A,F6.3,A)') label, ' vs OrcaFlex summary:', &
      (TRIM(names(k))//'=', e(k), k=1, 7), '  h1/|h1_ref|=', h1_rel, ' (gates 0.150 / 0.250)'
    WRITE (*, '(A,A,F9.2,A,F9.2,A,F8.2,A,F8.2,A,F8.2)') label, ' CableDyn a1 ', sm(5), ' (OrcaFlex ', &
      ref_sum(5), ')  ph1 ', sm(6), ' (OrcaFlex ', ref_sum(6), ')  std ', sm(2)
    DO k = 1, 7
      CALL require(e(k) <= GATE, label//':orcaflex-summary-'//TRIM(names(k))//'-within-15pct')
    END DO
    CALL require(h1_rel <= GATE_H1, label//':orcaflex-summary-h1-within-25pct-of-amplitude')
  END SUBROUTINE score_summary

  SUBROUTINE grow_reference(values)
    REAL(wp), ALLOCATABLE, INTENT(INOUT) :: values(:)
    REAL(wp), ALLOCATABLE :: tmp(:)
    INTEGER :: n
    n = SIZE(values)
    ALLOCATE (tmp(2*n))
    tmp(1:n) = values
    DEALLOCATE (values)
    CALL MOVE_ALLOC(tmp, values)
  END SUBROUTINE grow_reference

  SUBROUTINE heave_kin(t, amp, omega, heave, vz, az)
    !! ZZP1 heave A sin(omega t), matching the vendored external/OrcaFlex motion file.
    REAL(wp), INTENT(IN)  :: t, amp, omega
    REAL(wp), INTENT(OUT) :: heave, vz, az
    heave = amp*SIN(omega*t)
    vz = amp*omega*COS(omega*t)
    az = -amp*omega*omega*SIN(omega*t)
  END SUBROUTINE heave_kin

  FUNCTION static_fairlead_reference(label) RESULT(value)
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp) :: value
    IF (INDEX(label, 'WD0050') == 1) THEN
      value = 991.6_wp
    ELSE IF (INDEX(label, 'WD0200') == 1) THEN
      value = 2065.4_wp
    ELSE IF (INDEX(label, 'WD0600') == 1) THEN
      value = 5232.6_wp
    ELSE
      CALL require(.FALSE., label//':static-reference')
      value = 0.0_wp
    END IF
  END FUNCTION static_fairlead_reference

  SUBROUTINE require(cond, lbl)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: lbl
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A,A)') 'MISMATCH [', lbl, ']: condition false'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l2_2_dynamic_parity
