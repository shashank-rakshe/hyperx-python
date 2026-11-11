! File: tests/test_deck_driver.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_deck_driver
  !! Gate for the standalone `cabledyn` legacy-style deck driver: the static IC and
  !! dynamic march of EI=0 and finite-EI lines read from a `.dat` deck
  !! (doc/driver_format.md). Writes self-contained decks to temp files, runs
  !! CD_Run_Deck_Driver, reads the `.out`, and checks:
  !!   1. the WD0050 grounded chain matches the OrcaFlex static reference (fairlead/anchor
  !!      tension within 2%) -- the deck path reproduces the L2-1/L3-1 result;
  !!   2. the OrcaFlex line model: ONE line built from several SECTIONS of the SAME line
  !!      type but DIFFERENT mesh size solves to the same tension (mesh-consistent) --
  !!      exercising per-section user meshing;
  !!   3. the WD0050 L3-2 regular-wave dynamic deck path reproduces the scored
  !!      OrcaFlex reference through the public `.dat` -> `.out` workflow;
  !!   4. fail-closed on invalid or unsupported feature combinations -- a clear BADINPUT
  !!      error, never a wrong-physics solve.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Model, ONLY: CD_ModelType, CD_End_Model, CD_Model_Is_Initialized, CD_Model_NDOF, &
                            CD_Get_Model_State, CD_Calc_Model_CoupledLoads, CD_MODEL_OK, &
                            CD_Step_Model, CD_Get_Model_Tension, CD_Model_NElem, CD_Get_Model_Syrope_State
  USE CableDyn_System, ONLY: CD_SystemType, CD_End_System, CD_System_Is_Initialized, CD_System_NLines, &
                             CD_System_NCoupledDOF, CD_System_Line_NDOF, CD_Get_System_Line_State, &
                             CD_SYSTEM_OK
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_Init_Deck_Models, &
                                 CD_Init_Deck_System, CD_Init_Deck_Aggregate, CD_End_Deck_Aggregate, &
                                 CD_DeckAggregateType, &
                                 CD_Classify_Dynamic_Completion, CD_Channel_Token_Parses, CD_Deck_Fluid_Probe, &
                                 CD_DECKDRV_OK, CD_DECKDRV_BADINPUT, CD_DECKDRV_SOLVEFAIL
  USE CableDyn_SO3, ONLY: CD_Exp_SO3
  USE CableDyn_Conventions, ONLY: CD_Body_Rotation
  USE, INTRINSIC :: IEEE_EXCEPTIONS, ONLY: IEEE_USUAL, IEEE_GET_HALTING_MODE, IEEE_SET_HALTING_MODE, IEEE_SET_FLAG
  IMPLICIT NONE
  LOGICAL :: fp_halt(3)   ! saved IEEE halting modes around deliberately non-finite inputs

  ! OrcaFlex WD0050 static reference (frictionless seabed), as in the L3-1 gate.
  REAL(wp), PARAMETER :: ORCA_FAIR = 998110.8935321609_wp, ORCA_ANCH = 832242.1912115519_wp
  ! dt-converged OrcaFlex WD0050 regular-wave reference, as in the L3-2 gate
  ! (test_l3_orcaflex_wave_dynamic: mean within 2 %, swing within 15 %)
  REAL(wp), PARAMETER :: ORCA_WAVE_MEAN = 998148.768523274_wp
  REAL(wp), PARAMETER :: ORCA_WAVE_SWING = 7881.65283203125_wp
  REAL(wp), PARAMETER :: RTOL = 0.02_wp
  CHARACTER(*), PARAMETER :: LONG_MOTION_FILE = &
                             'deck_motion_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_0123456789.txt'
  CHARACTER(*), PARAMETER :: OVERFLOW_DECK_DIR = 'deck_motion_overflow_subdirectory_0123456789'
  CHARACTER(*), PARAMETER :: OVERFLOW_MOTION_FILE = REPEAT('nested/', 67)//'motion.txt'
  INTEGER :: nfail
  REAL(wp) :: fair, anch, fair2, anch2
  ! IEA-15MW VolturnUS-S 3-line static tension (t=0; N) through the driver path, gated two ways:
  ! against OrcaFlex 11.6c (fairlead 2427.0 kN, as in the L2 VolturnUS gate; 3 % band, observed
  ! 0.4 %), and against this deck's own converged tensions (a regression record at the 8-digit
  ! output precision; 1e-6 band, so any change of the static solution is seen).
  REAL(wp), PARAMETER :: VOLT_FT_ORCA = 2427.0e3_wp, VOLT_ORCA_RTOL = 0.03_wp
  REAL(wp), PARAMETER :: VOLT_FT_REF(3) = [2437119.7_wp, 2436139.5_wp, 2436139.5_wp]
  REAL(wp), PARAMETER :: VOLT_AT_REF(3) = [1351631.9_wp, 1350668.3_wp, 1350668.3_wp]
  REAL(wp), PARAMETER :: VOLT_RTOL = 1.0e-6_wp
  REAL(wp) :: volt_ft(3), volt_at(3)
  INTEGER :: volt_k
  INTEGER :: n_sys
  REAL(wp) :: dt_sys, g_sys, rho_sys
  REAL(wp) :: dyn_flat_fair, dyn_flat_anch, dyn_bathy_fair, dyn_bathy_anch
  REAL(wp) :: finite_fric0, finite_fric1, finite_bathy, finite_point_x, finite_node_x, finite_anch
  REAL(wp) :: finite_bathy_point_x, finite_bathy_node_x, finite_bathy_anch
  REAL(wp) :: finite_slope, finite_slope_anch
  REAL(wp) :: still_drag0_fair, still_drag1_fair
  REAL(wp) :: connect_ten1, connect_ten2, connect_z, connect_vz
  REAL(wp) :: stag_ten1, stag_ten2, stag_z, stag_vz
  REAL(wp) :: connect_bathy_ten1, connect_bathy_ten2, connect_bathy_z, connect_bathy_vz
  REAL(wp) :: connect_nomass_ten1, connect_nomass_ten2, connect_nomass_z, connect_nomass_vz
  REAL(wp) :: massless_ten1, massless_ten2, massless_z, massless_vz
  REAL(wp) :: fail_ten1, fail_ten2, fail_z, fail_vz
  REAL(wp) :: connect_added_ten1, connect_added_ten2, connect_added_z, connect_added_vz
  REAL(wp) :: rigid6_deep_z, rigid6_contact_z, rigid6_nomass_z, rigid6_added_z
  REAL(wp) :: rod_deep_za, rod_deep_zb, rod_contact_za, rod_contact_zb
  LOGICAL :: conv
  INTEGER :: es
  CHARACTER(256) :: em
  TYPE(CD_ModelType), ALLOCATABLE :: models(:)
  TYPE(CD_SystemType) :: deck_system
  ! Stock-dialect (MoorDyn coupled-deck) compatibility readouts
  REAL(wp), ALLOCATABLE :: stock_q(:), stock_v(:), stock_a(:)
  REAL(wp) :: stock_minz_env
  INTEGER :: stock_ndof

  nfail = 0
  CALL check_dynamic_completion_policy()

  ! --- (1) single-section WD0050 chain ---
  CALL write_single_deck('deck_single.dat')
  CALL CD_Run_Deck_Driver('deck_single.dat', 'deck_single', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'single-section deck converged: '//TRIM(em))
  CALL read_out('deck_single.out', fair, anch, es)
  CALL require(es == 0, 'read single-section .out')
  CALL require(ABS(fair - ORCA_FAIR)/ORCA_FAIR < RTOL, 'fairlead tension within 2% OrcaFlex')
  CALL require(ABS(anch - ORCA_ANCH)/ORCA_ANCH < RTOL, 'anchor tension within 2% OrcaFlex')
  WRITE (*, '(A,F10.3,A,F10.3,A)') 'Deck-driver single: fairlead=', fair*1.0e-3_wp, &
    ' kN  anchor=', anch*1.0e-3_wp, ' kN'

  ! Static templates may retain an explicitly disabled motionFile row. Both
  ! documented selectors must be equivalent to omitting the option entirely.
  CALL write_single_deck('deck_motion_none.dat', 'NoNe', 'missing-motion.txt')
  CALL CD_Run_Deck_Driver('deck_motion_none.dat', 'deck_motion_none', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'none-disabled motionFile remains static: '//TRIM(em))
  CALL read_out('deck_motion_none.out', fair2, anch2, es)
  CALL require(es == 0, 'read none-disabled motionFile .out')
  CALL require(ABS(fair2 - fair)/fair < 1.0e-12_wp .AND. ABS(anch2 - anch)/anch < 1.0e-12_wp, &
               'none-disabled motionFile matches omitted option')
  CALL write_single_deck('deck_motion_zero.dat', '0')
  CALL CD_Run_Deck_Driver('deck_motion_zero.dat', 'deck_motion_zero', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'zero-disabled motionFile remains static: '//TRIM(em))
  CALL read_out('deck_motion_zero.out', fair2, anch2, es)
  CALL require(es == 0, 'read zero-disabled motionFile .out')
  CALL require(ABS(fair2 - fair)/fair < 1.0e-12_wp .AND. ABS(anch2 - anch)/anch < 1.0e-12_wp, &
               'zero-disabled motionFile matches omitted option')

  ! --- (1b) IEA-15MW VolturnUS-S: full 3D, 3 catenary chains, driver end-to-end vs reference ---
  ! The user-facing driver path reproduces the static IC (t=0) on the reference-platform mooring:
  ! the three 120-deg all-chain lines of the IEA-15MW VolturnUS-S semi-sub, absolute fairlead /
  ! anchor positions, exercised through parse -> solve -> .out. Mirrors
  ! examples/iea15mw_volturnus_mooring.dat (extended to the full three-line ring).
  CALL write_volturnus_deck('deck_volturnus.dat')
  CALL CD_Run_Deck_Driver('deck_volturnus.dat', 'deck_volturnus', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'VolturnUS-S deck converged: '//TRIM(em))
  CALL read_out6('deck_volturnus.out', volt_ft, volt_at, es)
  CALL require(es == 0, 'read VolturnUS-S .out (6 channels)')
  DO volt_k = 1, 3
    CALL require(ABS(volt_ft(volt_k) - VOLT_FT_ORCA)/VOLT_FT_ORCA < VOLT_ORCA_RTOL, &
                 'VolturnUS-S fairlead tension within 3% of OrcaFlex')
    CALL require(ABS(volt_ft(volt_k) - VOLT_FT_REF(volt_k))/VOLT_FT_REF(volt_k) < VOLT_RTOL, &
                 'VolturnUS-S fairlead tension equals its regression record')
    CALL require(ABS(volt_at(volt_k) - VOLT_AT_REF(volt_k))/VOLT_AT_REF(volt_k) < VOLT_RTOL, &
                 'VolturnUS-S anchor tension equals its regression record')
  END DO
  WRITE (*, '(A,3F9.1,A,3F9.1)') 'Deck-driver VolturnUS-S fair(kN)=', volt_ft*1.0e-3_wp, &
    '  anch(kN)=', volt_at*1.0e-3_wp

  ! --- (2) OrcaFlex line model: one line, two SECTIONS, SAME type, DIFFERENT mesh ---
  CALL write_multisec_deck('deck_multi.dat')
  CALL CD_Run_Deck_Driver('deck_multi.dat', 'deck_multi', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'multi-section deck converged: '//TRIM(em))
  CALL read_out('deck_multi.out', fair2, anch2, es)
  CALL require(es == 0, 'read multi-section .out')
  ! same physical line, finer per-section mesh -> same tension to a tight mesh-consistency band
  CALL require(ABS(fair2 - fair)/fair < 0.01_wp, 'same-type/diff-mesh fairlead matches single mesh')
  CALL require(ABS(anch2 - anch)/anch < 0.01_wp, 'same-type/diff-mesh anchor matches single mesh')
  WRITE (*, '(A,F10.3,A,F10.3,A)') 'Deck-driver multi : fairlead=', fair2*1.0e-3_wp, &
    ' kN  anchor=', anch2*1.0e-3_wp, ' kN'

  ! --- (2b) non-contiguous / out-of-order POINT + LINE ids resolve correctly ---
  ! Guards the class of bugs where external ids are used as array indices.
  ! as subscripts. Points 20 (anchor) + 10 (fairlead), line id 7 -> same WD0050 tensions.
  CALL write_idmap_deck('deck_idmap.dat')
  CALL CD_Run_Deck_Driver('deck_idmap.dat', 'deck_idmap', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'non-contiguous-id deck converged: '//TRIM(em))
  CALL read_out('deck_idmap.out', fair2, anch2, es)
  CALL require(es == 0, 'read non-contiguous-id .out')
  CALL require(ABS(fair2 - fair)/fair < 1.0e-6_wp, 'FairTen7 (line id 7) resolves to the right line')
  CALL require(ABS(anch2 - anch)/anch < 1.0e-6_wp, 'AnchTen7 resolves to the right line')

  ! --- (2c) stock (MoorDyn) anchor-first endpoint order is NORMALIZED, not rejected:
  ! a Fixed NodeA with a Coupled/Vessel NodeB swaps into the CableDyn convention
  ! (End A = fairlead) with the line's SECTIONS order reversed, so both orders
  ! resolve to the same internal anchor->fairlead model and the same solution. ---
  CALL write_reversed_deck('deck_rev.dat')
  CALL CD_Run_Deck_Driver('deck_rev.dat', 'deck_rev', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'stock anchor-first endpoint deck converged: '//TRIM(em))
  CALL read_out('deck_rev.out', fair2, anch2, es)
  CALL require(es == 0, 'read anchor-first .out')
  CALL require(ABS(fair2 - fair)/fair < 1.0e-6_wp, 'anchor-first FairTen matches fairlead-first deck')
  CALL require(ABS(anch2 - anch)/anch < 1.0e-6_wp, 'anchor-first AnchTen matches fairlead-first deck')

  ! --- (2c2) the full stock MoorDyn coupled-deck dialect on the same WD0050 rig:
  ! title banner + Echo preamble, stock LINE TYPES header (Cd Ca CdAx CaAx column
  ! order), stock 7-column LINES row (anchor-first attachments, implicit single
  ! SECTIONS row), OPTIONS rows with trailing commentary including the dynamic-
  ! relaxation IC class (dtIC/TmaxIC/CdScaleIC/threshIC), WriteLog/dtOut, explicit
  ! "0 WaveKin"/"0 Currents", and an END-terminated OUTPUTS list. Resolves to the
  ! same internal model as the CableDyn-dialect deck -> identical tensions. ---
  CALL write_stock_deck('deck_stock.dat', with_dtm=.FALSE., with_seabed=.TRUE., wavekin_val=0)
  CALL CD_Run_Deck_Driver('deck_stock.dat', 'deck_stock', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'stock-dialect deck converged: '//TRIM(em))
  CALL read_out('deck_stock.out', fair2, anch2, es)
  CALL require(es == 0, 'read stock-dialect .out')
  CALL require(ABS(fair2 - fair)/fair < 1.0e-6_wp, 'stock-dialect FairTen matches CableDyn-dialect deck')
  CALL require(ABS(anch2 - anch)/anch < 1.0e-6_wp, 'stock-dialect AnchTen matches CableDyn-dialect deck')

  ! --- (2c3) a nonzero stock WaveKin (caller-supplied wave kinematics) fails closed ---
  CALL write_stock_deck('deck_stock_wk.dat', with_dtm=.FALSE., with_seabed=.TRUE., wavekin_val=1)
  CALL CD_Run_Deck_Driver('deck_stock_wk.dat', 'deck_stock_wk', conv, es, em)
  CALL require(es == CD_DECKDRV_BADINPUT, 'nonzero WaveKin fails closed: '//TRIM(em))

  ! --- (2d) WtrDpth is OPTIONAL: a deck with no seabed solves the line suspended ---
  CALL write_noseabed_deck('deck_nosb.dat')
  CALL CD_Run_Deck_Driver('deck_nosb.dat', 'deck_nosb', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'no-WtrDpth (suspended) deck converged: '//TRIM(em))

  ! --- (2e) static LINE Outputs p/t write dedicated per-line files ---
  CALL write_line_outputs_deck('deck_line_outputs.dat')
  CALL CD_Run_Deck_Driver('deck_line_outputs.dat', 'deck_line_outputs', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'static line-output deck converged: '//TRIM(em))
  CALL check_static_line_output_files('deck_line_outputs.Line1.p.out', 'deck_line_outputs.Line1.t.out')
  CALL write_dynamic_line_outputs_deck('deck_line_outputs_dyn.dat')
  CALL CD_Run_Deck_Driver('deck_line_outputs_dyn.dat', 'deck_line_outputs_dyn', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic line-output deck converged: '//TRIM(em))
  CALL check_dynamic_line_output_files('deck_line_outputs_dyn.Line1.p.out', 'deck_line_outputs_dyn.Line1.t.out')

  ! --- (2e) static deck can use a structured bathymetry file instead of flat WtrDpth ---
  CALL write_bathymetry_file('deck_bathy.xyz', 50.0_wp)
  CALL write_bathymetry_deck('deck_bathy.dat', 'deck_bathy.xyz')
  CALL CD_Run_Deck_Driver('deck_bathy.dat', 'deck_bathy', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'static bathymetry deck converged: '//TRIM(em))
  CALL read_out('deck_bathy.out', fair2, anch2, es)
  CALL require(es == 0, 'read static bathymetry .out')
  CALL require(ABS(fair2 - fair)/fair < 1.0e-6_wp, 'constant bathymetry fairlead matches flat WtrDpth')
  CALL require(ABS(anch2 - anch)/anch < 1.0e-6_wp, 'constant bathymetry anchor matches flat WtrDpth')

  ! --- (2e) legacy-style `--` comment lines (incl. inside OPTIONS/OUTPUTS) are stripped ---
  CALL write_comment_deck('deck_comment.dat')
  CALL CD_Run_Deck_Driver('deck_comment.dat', 'deck_comment', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'deck with -- comments parses + converges: '//TRIM(em))
  CALL read_out('deck_comment.out', fair2, anch2, es)
  CALL require(es == 0 .AND. ABS(fair2 - fair)/fair < 1.0e-6_wp, '-- comments do not perturb the solve')

  ! --- (2f) dtM/TMax enables a held-coupled dynamic march from the static IC ---
  CALL write_dynamic_held_deck('deck_dynamic.dat')
  CALL CD_Run_Deck_Driver('deck_dynamic.dat', 'deck_dynamic', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic held-end deck converged: '//TRIM(em))
  CALL check_dynamic_out('deck_dynamic.out')
  CALL read_dynamic_tensions('deck_dynamic.out', dyn_flat_fair, dyn_flat_anch, es)
  CALL require(es == 0, 'read flat dynamic tensions')
  CALL write_dynamic_bathymetry_deck('deck_bathy_dyn.dat', 'deck_bathy.xyz')
  CALL CD_Run_Deck_Driver('deck_bathy_dyn.dat', 'deck_bathy_dyn', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic constant-bathymetry deck converged: '//TRIM(em))
  CALL check_dynamic_out('deck_bathy_dyn.out')
  CALL read_dynamic_tensions('deck_bathy_dyn.out', dyn_bathy_fair, dyn_bathy_anch, es)
  CALL require(es == 0, 'read bathymetry dynamic tensions')
  CALL require(ABS(dyn_bathy_fair - dyn_flat_fair)/dyn_flat_fair < 1.0e-8_wp, &
               'constant bathymetry dynamic fairlead matches flat WtrDpth')
  CALL require(ABS(dyn_bathy_anch - dyn_flat_anch)/dyn_flat_anch < 1.0e-8_wp, &
               'constant bathymetry dynamic anchor matches flat WtrDpth')
  CALL write_dynamic_current_deck('deck_current.dat')
  CALL CD_Run_Deck_Driver('deck_current.dat', 'deck_current', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic uniform-current deck converged: '//TRIM(em))
  CALL check_dynamic_current_out('deck_current.out', dyn_flat_fair)
  CALL write_dynamic_current_profile_deck('deck_current_profile.dat')
  CALL CD_Run_Deck_Driver('deck_current_profile.dat', 'deck_current_profile', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic current-profile deck converged: '//TRIM(em))
  CALL check_dynamic_current_out('deck_current_profile.out', dyn_flat_fair)
  CALL write_dynamic_wave_deck('deck_wave.dat')
  CALL CD_Run_Deck_Driver('deck_wave.dat', 'deck_wave', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Airy-wave deck converged: '//TRIM(em))
  CALL check_dynamic_wave_out('deck_wave.out')
  CALL write_l3_wave_deck('deck_l3_wave.dat')
  CALL CD_Run_Deck_Driver('deck_l3_wave.dat', 'deck_l3_wave', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'L3-2 dynamic deck converged: '//TRIM(em))
  CALL check_l3_wave_deck_out('deck_l3_wave.out')
  CALL write_dynamic_jonswap_deck('deck_jonswap.dat')
  CALL CD_Run_Deck_Driver('deck_jonswap.dat', 'deck_jonswap', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic JONSWAP deck converged: '//TRIM(em))
  CALL check_dynamic_wave_out('deck_jonswap.out')
  CALL write_dynamic_motion_deck('deck_motion.dat', 'deck_motion.txt')
  CALL write_motion_file('deck_motion.txt')
  CALL CD_Run_Deck_Driver('deck_motion.dat', 'deck_motion', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic prescribed-motion deck converged: '//TRIM(em))
  CALL check_dynamic_motion_out('deck_motion.out')
  ! TMax off the dtM grid fails closed (the march would end between steps)
  CALL write_dynamic_connect_deck('deck_tmax_offgrid.dat', run_tmax=0.0123_wp)
  CALL CD_Run_Deck_Driver('deck_tmax_offgrid.dat', 'deck_tmax_offgrid', conv, es, em)
  CALL require(es == CD_DECKDRV_BADINPUT .AND. INDEX(em, 'TMax must be an integer multiple of dtM') > 0, &
               'TMax that is not a multiple of dtM fails closed: '//TRIM(em))
  ! the line-model entry leaves the end motion to its caller: a motionFile fails closed by name
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: mmodels(:)
    CALL CD_Init_Deck_Models('deck_motion.dat', mmodels, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'does not apply a motionFile') > 0, &
                 'CD_Init_Deck_Models rejects a motionFile: '//TRIM(em))
  END BLOCK
  ! A deliberately under-iterated march must stop before the failed state is
  ! committed.  This is an end-to-end gate on the public driver contract, not
  ! only a unit check of the completion-status classifier.
  CALL write_dynamic_motion_deck('deck_motion_nonconvergent.dat', 'deck_motion.txt', nonconvergent=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_motion_nonconvergent.dat', 'deck_motion_nonconvergent', conv, es, em)
  CALL require(es == CD_DECKDRV_SOLVEFAIL .AND. .NOT. conv .AND. &
               INDEX(em, 'recovery failed') > 0 .AND. INDEX(em, 'subdivision cap 1024') > 0 .AND. &
               INDEX(em, 'inspection only') > 0, &
               'non-convergent march fails closed with an inspection-only diagnostic: '//TRIM(em))
  CALL check_dynamic_failure_out('deck_motion_nonconvergent.out')
  CALL write_dynamic_motion_deck('deck_motion_relpath.dat', './deck_motion.txt')
  CALL CD_Run_Deck_Driver('deck_motion_relpath.dat', 'deck_motion_relpath', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'motionFile path with slash converged: '//TRIM(em))
  CALL check_dynamic_motion_out('deck_motion_relpath.out')
  CALL ensure_directory('deck_sub')
  CALL write_dynamic_motion_deck('deck_sub/deck_motion_local.dat', 'motion_local.txt')
  CALL write_motion_file('deck_sub/motion_local.txt')
  CALL CD_Run_Deck_Driver('deck_sub/deck_motion_local.dat', 'deck_motion_local', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'motionFile resolves relative to deck directory: '//TRIM(em))
  CALL check_dynamic_motion_out('deck_motion_local.out')
  CALL write_dynamic_motion_deck('deck_motion_longpath.dat', LONG_MOTION_FILE)
  CALL write_motion_file(LONG_MOTION_FILE)
  CALL CD_Run_Deck_Driver('deck_motion_longpath.dat', 'deck_motion_longpath', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'motionFile path longer than deck identifiers converged: '//TRIM(em))
  CALL check_dynamic_motion_out('deck_motion_longpath.out')
  CALL write_dynamic_motion_deck('deck_sub/deck_motion_shortname.dat', 'm')
  CALL write_motion_file('deck_sub/m')
  CALL CD_Run_Deck_Driver('deck_sub/deck_motion_shortname.dat', 'deck_motion_shortname', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'one-character motionFile name converged: '//TRIM(em))
  CALL check_dynamic_motion_out('deck_motion_shortname.out')
  CALL ensure_directory(OVERFLOW_DECK_DIR)
  CALL write_dynamic_motion_deck(OVERFLOW_DECK_DIR//'/deck.dat', OVERFLOW_MOTION_FILE)
  CALL CD_Run_Deck_Driver(OVERFLOW_DECK_DIR//'/deck.dat', 'deck_motion_overflow', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'motionFile path is too long') > 0, &
               'overlong resolved motionFile path fails explicitly without truncation: '//TRIM(em))
  CALL write_dynamic_motion_deck('deck_motion_drag0.dat', 'deck_motion.txt', 0.0_wp)
  CALL write_dynamic_motion_deck('deck_motion_drag1.dat', 'deck_motion.txt', 1.37_wp)
  CALL CD_Run_Deck_Driver('deck_motion_drag0.dat', 'deck_motion_drag0', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'still-water zero-drag prescribed-motion deck converged: '//TRIM(em))
  CALL CD_Run_Deck_Driver('deck_motion_drag1.dat', 'deck_motion_drag1', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'still-water line-drag prescribed-motion deck converged: '//TRIM(em))
  CALL read_motion_last_fair('deck_motion_drag0.out', still_drag0_fair, es)
  CALL require(es == 0, 'read still-water zero-drag prescribed-motion fairlead tension')
  CALL read_motion_last_fair('deck_motion_drag1.out', still_drag1_fair, es)
  CALL require(es == 0, 'read still-water line-drag prescribed-motion fairlead tension')
  CALL require(ABS(still_drag1_fair - still_drag0_fair)/MAX(ABS(still_drag0_fair), 1.0_wp) > 1.0e-8_wp, &
               'WtrDpth-only prescribed-motion line drag changes fairlead tension')
  CALL write_dynamic_finite_ei_deck('deck_finite_dyn.dat')
  CALL CD_Run_Deck_Driver('deck_finite_dyn.dat', 'deck_finite_dyn', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI deck converged: '//TRIM(em))
  CALL check_dynamic_finite_ei_out('deck_finite_dyn.out')
  CALL write_dynamic_finite_above_bed_deck('deck_finite_above_bed.dat')
  CALL CD_Run_Deck_Driver('deck_finite_above_bed.dat', 'deck_finite_above_bed', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, &
               'slack finite-EI line with both endpoints above bed converged on Hermite contact route: '//TRIM(em))
  CALL write_dynamic_mixed_finite_ei_deck('deck_finite_mixed.dat')
  CALL CD_Run_Deck_Driver('deck_finite_mixed.dat', 'deck_finite_mixed', conv, es, em)
  CALL require(es == CD_DECKDRV_BADINPUT .AND. INDEX(em, 'mixed EI=0 and finite-EI') > 0, &
               'suspended mixed EI=0/finite-EI deck fails closed before Hermite build: '//TRIM(em))
  CALL write_dynamic_finite_ei_deck('deck_finite_outputs.dat', line_outputs=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_finite_outputs.dat', 'deck_finite_outputs', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI line-output deck converged: '//TRIM(em))
  CALL check_dynamic_finite_line_output_files('deck_finite_outputs.Line1.p.out', &
                                              'deck_finite_outputs.Line1.t.out')
  CALL write_text_file('deck_finite_current.dat', deck_with_finite_ei_current())
  CALL CD_Run_Deck_Driver('deck_finite_current.dat', 'deck_finite_current', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI current deck converged: '//TRIM(em))
  CALL check_dynamic_finite_ei_out('deck_finite_current.out')
  CALL write_text_file('deck_finite_wave.dat', deck_with_finite_ei_wave())
  CALL CD_Run_Deck_Driver('deck_finite_wave.dat', 'deck_finite_wave', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI wave deck converged: '//TRIM(em))
  CALL check_dynamic_finite_ei_out('deck_finite_wave.out')
  CALL write_dynamic_finite_motion_deck('deck_finite_motion.dat', 'deck_finite_motion.txt')
  CALL write_finite_motion_file('deck_finite_motion.txt')
  CALL CD_Run_Deck_Driver('deck_finite_motion.dat', 'deck_finite_motion', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI prescribed-motion deck converged: '//TRIM(em))
  CALL check_dynamic_finite_motion_out('deck_finite_motion.out')
  CALL write_dynamic_finite_motion_deck('deck_finite_motion_outputs.dat', 'deck_finite_motion.txt', &
                                        line_outputs=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_finite_motion_outputs.dat', 'deck_finite_motion_outputs', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI prescribed line-output deck converged: '//TRIM(em))
  CALL check_dynamic_finite_line_output_files('deck_finite_motion_outputs.Line1.p.out', &
                                              'deck_finite_motion_outputs.Line1.t.out', &
                                              expected_rows=4, expected_end_time=0.03_wp, expected_end_a_z=-19.985_wp)
  CALL write_dynamic_finite_friction_deck('deck_finite_friction0.dat', 'deck_finite_friction.txt', 0.0_wp)
  CALL write_dynamic_finite_friction_deck('deck_finite_friction1.dat', 'deck_finite_friction.txt', 0.8_wp)
  CALL write_finite_friction_motion_file('deck_finite_friction.txt')
  CALL CD_Run_Deck_Driver('deck_finite_friction0.dat', 'deck_finite_friction0', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI no-friction touchdown deck converged: '//TRIM(em))
  CALL CD_Run_Deck_Driver('deck_finite_friction1.dat', 'deck_finite_friction1', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI friction touchdown deck converged: '//TRIM(em))
  CALL read_finite_friction_out('deck_finite_friction0.out', finite_point_x, finite_node_x, finite_fric0, finite_anch)
  CALL read_finite_friction_out('deck_finite_friction1.out', finite_point_x, finite_node_x, finite_fric1, finite_anch)
  CALL require(ABS(finite_point_x - 40.03_wp) < 1.0e-12_wp, 'finite-EI friction Point2px follows motionFile')
  CALL require(ABS(finite_node_x - finite_point_x) < 1.0e-12_wp, 'finite-EI friction fairlead node follows motionFile')
  CALL require(ABS(finite_fric0) > 1.0_wp .AND. ABS(finite_fric1) > 1.0_wp .AND. ABS(finite_anch) > 1.0_wp, &
               'finite-EI friction deck tensions finite and nonzero')
  CALL require(ABS(finite_fric1 - finite_fric0)/MAX(ABS(finite_fric0), 1.0_wp) > 1.0e-6_wp, &
               'finite-EI seabed friction changes touchdown tension')
  CALL write_bathymetry_file('deck_finite_bathy.xyz', 80.0_wp)
  CALL write_dynamic_finite_bathymetry_deck('deck_finite_bathy.dat', 'deck_finite_friction.txt', &
                                            'deck_finite_bathy.xyz', 0.8_wp)
  CALL CD_Run_Deck_Driver('deck_finite_bathy.dat', 'deck_finite_bathy', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI bathymetry touchdown deck converged: '//TRIM(em))
  CALL read_finite_friction_out('deck_finite_bathy.out', finite_bathy_point_x, finite_bathy_node_x, &
                                finite_bathy, finite_bathy_anch)
  CALL require(ABS(finite_bathy_point_x - finite_point_x) < 1.0e-12_wp, &
               'finite-EI bathymetry Point2px follows the same motionFile')
  CALL require(ABS(finite_bathy_node_x - finite_node_x) < 1.0e-12_wp, &
               'finite-EI bathymetry fairlead node follows the same motionFile')
  CALL require(ABS(finite_bathy - finite_fric1)/MAX(ABS(finite_fric1), 1.0_wp) < 1.0e-8_wp, &
               'constant bathymetry finite-EI fairlead tension matches flat WtrDpth')
  CALL require(ABS(finite_bathy_anch - finite_anch)/MAX(ABS(finite_anch), 1.0_wp) < 1.0e-8_wp, &
               'constant bathymetry finite-EI anchor tension matches flat WtrDpth')
  CALL write_sloped_bathymetry_file('deck_finite_slope.xyz', 80.0_wp, 80.5_wp)
  CALL write_dynamic_finite_bathymetry_deck('deck_finite_slope.dat', 'deck_finite_friction.txt', &
                                            'deck_finite_slope.xyz', 0.8_wp)
  CALL CD_Run_Deck_Driver('deck_finite_slope.dat', 'deck_finite_slope', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI sloped-bathymetry deck converged: '//TRIM(em))
  CALL read_finite_friction_out('deck_finite_slope.out', finite_bathy_point_x, finite_bathy_node_x, &
                                finite_slope, finite_slope_anch)
  CALL require(ABS(finite_slope) > 1.0_wp .AND. ABS(finite_slope_anch) > 1.0_wp, &
               'sloped-bathymetry finite-EI tensions are finite and nonzero')
  CALL require(ABS(finite_slope_anch - finite_bathy_anch)/MAX(ABS(finite_bathy_anch), 1.0_wp) > 1.0e-6_wp, &
               'structured bathymetry slope changes finite-EI touchdown response')
  CALL write_dynamic_finite_current_seed_deck('deck_finite_current_seed.dat')
  CALL CD_Run_Deck_Driver('deck_finite_current_seed.dat', 'deck_finite_current_seed', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'finite-EI current-seed deck converged: '//TRIM(em))
  CALL check_finite_current_seed_out('deck_finite_current_seed.out')
  CALL write_dynamic_finite_current_seed_deck('deck_finite_current_seed_mod.dat', modified_newton=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_finite_current_seed_mod.dat', 'deck_finite_current_seed_mod', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'finite-EI current-seed modified-Newton deck converged: '//TRIM(em))
  CALL check_finite_current_seed_out('deck_finite_current_seed_mod.out')
  CALL compare_finite_current_seed_out('deck_finite_current_seed.out', 'deck_finite_current_seed_mod.out')
  CALL write_text_file('deck_finite_lazy_wave.dat', deck_with_finite_ei_lazy_wave())
  CALL CD_Run_Deck_Driver('deck_finite_lazy_wave.dat', 'deck_finite_lazy_wave', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic finite-EI lazy-wave deck converged: '//TRIM(em))
  CALL check_dynamic_finite_ei_lazy_wave_out('deck_finite_lazy_wave.out')
  CALL write_text_file('deck_finite_lazy_wave_sectioned.dat', deck_with_sectioned_finite_ei_lazy_wave())
  CALL CD_Run_Deck_Driver('deck_finite_lazy_wave_sectioned.dat', 'deck_finite_lazy_wave_sectioned', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'sectioned finite-EI lazy-wave statics converged: '//TRIM(em))
  CALL check_dynamic_finite_ei_lazy_wave_out('deck_finite_lazy_wave_sectioned.out', &
                                             end_node=73, mid_lift_min=-56.0_wp, expected_rows=1)
  CALL write_text_file('deck_finite_lazy_wave_native.dat', deck_with_native_finite_ei_lazy_wave())
  CALL CD_Run_Deck_Driver('deck_finite_lazy_wave_native.dat', 'deck_finite_lazy_wave_native', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'native finite-EI lazy-wave deck converged: '//TRIM(em))
  CALL check_dynamic_finite_ei_lazy_wave_out('deck_finite_lazy_wave_native.out')
  CALL write_dynamic_connect_deck('deck_connect_dyn.dat')
  CALL CD_Run_Deck_Driver('deck_connect_dyn.dat', 'deck_connect_dyn', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Connect-point deck converged: '//TRIM(em))
  CALL check_dynamic_connect_out('deck_connect_dyn.out')
  CALL read_dynamic_connect_out('deck_connect_dyn.out', connect_ten1, connect_ten2, connect_z, connect_vz, es)
  CALL require(es == 0, 'read dynamic Connect tensions')
  CALL write_dynamic_connect_deck('deck_connect_line_outputs.dat', line_outputs=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_connect_line_outputs.dat', 'deck_connect_line_outputs', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Connect LINE Outputs deck converged: '//TRIM(em))
  CALL check_dynamic_connect_line_output_files('deck_connect_line_outputs.Line1.p.out', &
                                               'deck_connect_line_outputs.Line1.t.out')
  CALL write_bathymetry_file('deck_connect_bathy.xyz', 10.0_wp)
  CALL write_dynamic_connect_bathymetry_deck('deck_connect_bathy.dat', 'deck_connect_bathy.xyz')
  CALL CD_Run_Deck_Driver('deck_connect_bathy.dat', 'deck_connect_bathy', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Connect bathymetry deck converged: '//TRIM(em))
  CALL check_dynamic_connect_out('deck_connect_bathy.out')
  CALL read_dynamic_connect_out('deck_connect_bathy.out', connect_bathy_ten1, connect_bathy_ten2, &
                                connect_bathy_z, connect_bathy_vz, es)
  CALL require(es == 0, 'read dynamic Connect bathymetry tensions')
  CALL require(ABS(connect_bathy_ten1 - connect_ten1)/MAX(ABS(connect_ten1), 1.0_wp) < 1.0e-8_wp, &
               'constant bathymetry Connect FairTen1 matches flat WtrDpth')
  CALL require(ABS(connect_bathy_ten2 - connect_ten2)/MAX(ABS(connect_ten2), 1.0_wp) < 1.0e-8_wp, &
               'constant bathymetry Connect FairTen2 matches flat WtrDpth')
  CALL require(ABS(connect_bathy_z - connect_z) < 1.0e-10_wp .AND. ABS(connect_bathy_vz - connect_vz) < 1.0e-10_wp, &
               'constant bathymetry Connect point state matches flat WtrDpth')
  ! MASSLESS Connect junction (the MoorDyn Mass=0 mid-line split pattern): the deck
  ! must parse, run, and stay finite -- the point advances on the attached lines'
  ! end-node consistent-mass diagonal share, treated implicitly. Both junctions start
  ! from their static force balance, so both are at rest at the first output step.
  CALL write_dynamic_connect_deck('deck_connect_massless.dat', connect_mass=0.0_wp)
  CALL CD_Run_Deck_Driver('deck_connect_massless.dat', 'deck_connect_massless', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'massless Connect junction deck converged: '//TRIM(em))
  CALL check_dynamic_connect_out('deck_connect_massless.out')
  CALL read_dynamic_connect_out('deck_connect_massless.out', massless_ten1, massless_ten2, &
                                massless_z, massless_vz, es)
  CALL require(es == 0, 'read massless Connect tensions')
  CALL require(ABS(massless_vz) < 1.0e-6_wp .AND. ABS(connect_vz) < 1.0e-6_wp, &
               'weighted and massless Connect junctions start at rest (static force balance)')

  ! LINE FAILURES on the same rig. (a) A FAILURE row that can never fire inside the
  ! window (FailTime > TMax) must leave the trajectory BIT-IDENTICAL to the
  ! no-failure twin: reserve-point pre-allocation widens the exchange extent but
  ! must not touch the physics until a trigger fires. (b) A time-triggered row
  ! detaches line 2 from the Connect junction mid-run: the run stays convergent and
  ! the final row diverges from the twin. (c) A FAILURE deck without dtM/TMax and a
  ! FAILURE deck through an entry point with no failure support both fail closed.
  ! A FAILURE deck marches on the staggered point scheme: its twin selects it too.
  CALL write_dynamic_connect_deck('deck_connect_stag.dat', option_row='staggered bodyScheme')
  CALL CD_Run_Deck_Driver('deck_connect_stag.dat', 'deck_connect_stag', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'staggered Connect twin converged: '//TRIM(em))
  CALL read_dynamic_connect_out('deck_connect_stag.out', stag_ten1, stag_ten2, stag_z, stag_vz, es)
  CALL require(es == 0, 'read staggered Connect twin outputs')
  CALL write_dynamic_connect_deck('deck_fail_never.dat', failure_row='1 P2 2 5.0 0.0')
  CALL CD_Run_Deck_Driver('deck_fail_never.dat', 'deck_fail_never', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'never-firing FAILURE deck converged: '//TRIM(em))
  CALL read_dynamic_connect_out('deck_fail_never.out', fail_ten1, fail_ten2, fail_z, fail_vz, es)
  CALL require(es == 0, 'read never-firing FAILURE outputs')
  CALL require(ABS(fail_ten1 - stag_ten1) <= 0.0_wp .AND. ABS(fail_ten2 - stag_ten2) <= 0.0_wp .AND. &
               ABS(fail_z - stag_z) <= 0.0_wp .AND. ABS(fail_vz - stag_vz) <= 0.0_wp, &
               'never-firing FAILURE trajectory is bit-identical to the no-failure twin')
  CALL write_dynamic_connect_deck('deck_fail_time.dat', failure_row='1 P2 2 0.004 0.0')
  CALL CD_Run_Deck_Driver('deck_fail_time.dat', 'deck_fail_time', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'time-triggered FAILURE deck converged: '//TRIM(em))
  CALL read_dynamic_connect_out('deck_fail_time.out', fail_ten1, fail_ten2, fail_z, fail_vz, es)
  CALL require(es == 0, 'read time-triggered FAILURE outputs')
  CALL require(ABS(fail_ten2 - connect_ten2) + ABS(fail_ten1 - connect_ten1) + &
               ABS(fail_z - connect_z) + ABS(fail_vz - connect_vz) > 1.0e-12_wp, &
               'time-triggered FAILURE diverges from the intact twin after the detach')
  ! (b1b) Point<P>F after the detach: line 2 leaves the junction P2 for a reserve point,
  ! so from then on Point2F is line 1's end force alone and its magnitude is FairTen1.
  ! Before the detach both lines pull on P2 and the resultant differs from FairTen1.
  CALL write_dynamic_connect_deck('deck_fail_pforce.dat', failure_row='1 P2 2 0.004 0.0', &
                                  outputs='FairTen1 Point2Fx Point2Fy Point2Fz')
  CALL CD_Run_Deck_Driver('deck_fail_pforce.dat', 'deck_fail_pforce', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'Point<P>F FAILURE deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: row(5), first(5), last(5), fmag
    INTEGER :: u, ios, nrow
    CHARACTER(512) :: hdr
    nrow = 0
    OPEN (NEWUNIT=u, FILE='deck_fail_pforce.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open Point<P>F FAILURE output')
    IF (ios == 0) THEN
      READ (u, '(A)') hdr
      READ (u, '(A)') hdr
      DO
        READ (u, *, IOSTAT=ios) row
        IF (ios /= 0) EXIT
        nrow = nrow + 1
        IF (nrow == 1) first = row
        last = row
      END DO
      CLOSE (u)
    END IF
    CALL require(nrow >= 2, 'Point<P>F FAILURE output has rows')
    IF (nrow >= 2) THEN
      fmag = NORM2(first(3:5))
      CALL require(.NOT. (ABS(fmag - first(2)) <= 1.0e-6_wp*first(2)), &
                   'intact junction: Point2F carries both lines')
      fmag = NORM2(last(3:5))
      CALL require(ABS(fmag - last(2)) <= 1.0e-5_wp*last(2), &
                   'after the detach Point2F is line 1 alone (|Point2F| = FairTen1)')
    END IF
  END BLOCK
  ! (b2) Tension trigger: the taut rig carries ~2 kN at rest, so FailTen = 1 N
  ! fires at the FIRST committed step -- the same step the time trigger fired --
  ! and the two failed trajectories must be BIT-IDENTICAL (same detach, same step).
  CALL write_dynamic_connect_deck('deck_fail_ten.dat', failure_row='1 P2 2 0.0 1.0')
  CALL CD_Run_Deck_Driver('deck_fail_ten.dat', 'deck_fail_ten', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'tension-triggered FAILURE deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: tt1, tt2, tz, tvz
    CALL read_dynamic_connect_out('deck_fail_ten.out', tt1, tt2, tz, tvz, es)
    CALL require(es == 0, 'read tension-triggered FAILURE outputs')
    CALL require(ABS(tt1 - fail_ten1) <= 0.0_wp .AND. ABS(tt2 - fail_ten2) <= 0.0_wp .AND. &
                 ABS(tz - fail_z) <= 0.0_wp .AND. ABS(tvz - fail_vz) <= 0.0_wp, &
                 'tension trigger firing at the same step matches the time trigger bit-for-bit')
  END BLOCK
  ! (b3) Multi-line row: BOTH lines detach from the junction in one firing (the
  ! tension probe and the detach both walk a >1-line list); the junction keeps its
  ! own 20 kg mass with no attached lines and the run stays convergent and finite.
  CALL write_dynamic_connect_deck('deck_fail_both.dat', failure_row='1 P2 1,2 0.0 1.0')
  CALL CD_Run_Deck_Driver('deck_fail_both.dat', 'deck_fail_both', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'multi-line FAILURE deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: bt1, bt2, bz, bvz
    CALL read_dynamic_connect_out('deck_fail_both.out', bt1, bt2, bz, bvz, es)
    CALL require(es == 0, 'read multi-line FAILURE outputs')
    CALL require(ABS(bt1 - connect_ten1) + ABS(bt2 - connect_ten2) > 1.0e-12_wp, &
                 'multi-line FAILURE diverges from the intact twin')
  END BLOCK
  ! (b4) Duplicate rows: MoorDyn ignores duplicate failure configurations. Two
  ! identical multi-line rows must run to completion (the second is a no-op) and
  ! match the single-row run bit-for-bit -- each row needs its own reserve slot,
  ! so the reserve ids differ; the DYNAMICS must not.
  CALL write_dynamic_connect_deck('deck_fail_dup.dat', failure_row='1 P2 1,2 0.0 1.0', &
                                  failure_row2='2 P2 1,2 0.0 1.0')
  CALL CD_Run_Deck_Driver('deck_fail_dup.dat', 'deck_fail_dup', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'duplicate FAILURE rows deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: dt1, dt2, dz, dvz, bt1, bt2, bz, bvz
    CALL read_dynamic_connect_out('deck_fail_dup.out', dt1, dt2, dz, dvz, es)
    CALL require(es == 0, 'read duplicate FAILURE outputs')
    CALL read_dynamic_connect_out('deck_fail_both.out', bt1, bt2, bz, bvz, es)
    CALL require(es == 0, 're-read multi-line FAILURE outputs')
    CALL require(ABS(dt1 - bt1) <= 0.0_wp .AND. ABS(dt2 - bt2) <= 0.0_wp .AND. &
                 ABS(dz - bz) <= 0.0_wp .AND. ABS(dvz - bvz) <= 0.0_wp, &
                 'duplicate FAILURE row is ignored: trajectory matches the single-row run bit-for-bit')
  END BLOCK
  ! (b5) LONG line list: the LineID column exceeds any fixed name-token width
  ! (80+ chars of repeated ids ending in line 1). Truncation would drop the final
  ! id and detach only line 2; the full parse detaches BOTH lines at the first
  ! step -- exactly the multi-line run -- so the trajectories must be
  ! bit-identical.
  CALL write_dynamic_connect_deck('deck_fail_long.dat', failure_row='1 P2 '//REPEAT('2,', 40)//'1 0.004 0.0')
  CALL CD_Run_Deck_Driver('deck_fail_long.dat', 'deck_fail_long', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'long-list FAILURE deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: lt1, lt2, lz, lvz, bt1, bt2, bz, bvz
    CALL read_dynamic_connect_out('deck_fail_long.out', lt1, lt2, lz, lvz, es)
    CALL require(es == 0, 'read long-list FAILURE outputs')
    CALL read_dynamic_connect_out('deck_fail_both.out', bt1, bt2, bz, bvz, es)
    CALL require(es == 0, 're-read multi-line FAILURE outputs (long-list check)')
    CALL require(ABS(lt1 - bt1) <= 0.0_wp .AND. ABS(lt2 - bt2) <= 0.0_wp .AND. &
                 ABS(lz - bz) <= 0.0_wp .AND. ABS(lvz - bvz) <= 0.0_wp, &
                 'long-list FAILURE parses every id: trajectory matches the multi-line run bit-for-bit')
  END BLOCK
  ! MoorDyn WaterKin file (CurrentMod 1 depth profile): the file-driven current
  ! must be BIT-IDENTICAL to the equivalent inline profile OPTION, and the
  ! fail-closed battery covers the unsupported wave modes.
  CALL write_waterkin_file('wk_cur.dat', wavekinmod='0', deepest_first=.FALSE.)
  CALL write_dynamic_connect_deck('deck_wk.dat', option_row='wk_cur.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk.dat', 'deck_wk', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'WaterKin current deck converged: '//TRIM(em))
  CALL write_dynamic_connect_deck('deck_wk_inline.dat', &
                                  option_row='profile -10.0 0.30 0.05 0.0 0.0 0.10 0.02 0.0 current')
  CALL CD_Run_Deck_Driver('deck_wk_inline.dat', 'deck_wk_inline', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'inline profile twin converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
    CALL read_dynamic_connect_out('deck_wk.out', w1a, w1b, w1c, w1d, es)
    CALL require(es == 0, 'read WaterKin outputs')
    CALL read_dynamic_connect_out('deck_wk_inline.out', w2a, w2b, w2c, w2d, es)
    CALL require(es == 0, 'read inline twin outputs')
    CALL require(ABS(w1a - w2a) <= 0.0_wp .AND. ABS(w1b - w2b) <= 0.0_wp .AND. &
                 ABS(w1c - w2c) <= 0.0_wp .AND. ABS(w1d - w2d) <= 0.0_wp, &
                 'WaterKin file current is bit-identical to the inline profile')
  END BLOCK
  ! Only the first WaveKinMod token classifies SEASTATE. A numeric mode's
  ! trailing explanatory comment may mention SeaState without changing mode 0.
  CALL write_waterkin_file('wk_comment.dat', wavekinmod='0', deepest_first=.FALSE., &
                           wavekin_suffix='WaveKinMod - mode 2 uses SeaState, but this row is mode 0')
  CALL write_dynamic_connect_deck('deck_wk_comment.dat', option_row='wk_comment.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_comment.dat', 'deck_wk_comment', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'numeric WaveKinMod with SeaState comment converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
    CALL read_dynamic_connect_out('deck_wk.out', w1a, w1b, w1c, w1d, es)
    CALL read_dynamic_connect_out('deck_wk_comment.out', w2a, w2b, w2c, w2d, es)
    CALL require(MAX(ABS(w1a - w2a), ABS(w1b - w2b), ABS(w1c - w2c), ABS(w1d - w2d)) <= 0.0_wp, &
                 'WaveKinMod trailing SeaState comment leaves CurrentMod-1 bit-identical')
  END BLOCK
  ! deepest-first rows are flipped exactly as MoorDyn does -- same result bitwise
  CALL write_waterkin_file('wk_flip.dat', wavekinmod='0', deepest_first=.TRUE.)
  CALL write_dynamic_connect_deck('deck_wk_flip.dat', option_row='wk_flip.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_flip.dat', 'deck_wk_flip', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'deepest-first WaterKin deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
    CALL read_dynamic_connect_out('deck_wk.out', w1a, w1b, w1c, w1d, es)
    CALL read_dynamic_connect_out('deck_wk_flip.out', w2a, w2b, w2c, w2d, es)
    CALL require(ABS(w1a - w2a) <= 0.0_wp .AND. ABS(w1b - w2b) <= 0.0_wp .AND. &
                 ABS(w1c - w2c) <= 0.0_wp .AND. ABS(w1d - w2d) <= 0.0_wp, &
                 'deepest-first rows flip to the identical profile')
  END BLOCK
  CALL write_wave_elevation_file('wk_eta_short.dat', 1.0_wp, 2.0_wp, 0.0_wp, &
                                 nrows=4, row_dt=0.25_wp)
  CALL write_wave_elevation_file('wk_eta_padded.dat', 1.0_wp, 2.0_wp, 0.0_wp, &
                                 nrows=32, row_dt=0.25_wp, zero_after_index=3)
  CALL write_waterkin_file('wk_wave_short.dat', wavekinmod='1', deepest_first=.FALSE., &
                           wave_file='wk_eta_short.dat', dtwave=0.25_wp)
  CALL write_waterkin_file('wk_wave_padded.dat', wavekinmod='1', deepest_first=.FALSE., &
                           wave_file='wk_eta_padded.dat', dtwave=0.25_wp)
  ! TMax = 0 (a static-start check) reduces the record over its own length: 40 s of a 10 s wave
  CALL write_wave_elevation_file('wk_eta_t0.dat', 1.0_wp, 10.0_wp, 0.0_wp, nperiods=4)
  CALL write_waterkin_file('wk_wave_t0.dat', wavekinmod='1', deepest_first=.FALSE., &
                           wave_file='wk_eta_t0.dat', dtwave=0.25_wp)
  CALL write_dynamic_connect_deck('deck_wk_wave_t0.dat', option_row='wk_wave_t0.dat WaterKin', run_tmax=0.0_wp)
  CALL CD_Run_Deck_Driver('deck_wk_wave_t0.dat', 'deck_wk_wave_t0', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'WaveKinMod 1 record at TMax = 0 checks the static start: '//TRIM(em))
  ! a 1 s window has no component at or below the default 0.5 Hz WvHiCOff: refused by name
  CALL write_dynamic_connect_deck('deck_wk_wave_cut.dat', option_row='wk_wave_short.dat WaterKin', &
                                  run_tmax=1.0_wp)
  CALL CD_Run_Deck_Driver('deck_wk_wave_cut.dat', 'deck_wk_wave_cut', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'none WvHiCOff') > 0, &
               'a record with nothing below WvHiCOff is refused by name: '//TRIM(em))
  CALL write_dynamic_connect_deck('deck_wk_wave_short.dat', option_row='wk_wave_short.dat WaterKin', &
                                  option_row2='none WvHiCOff', run_tmax=1.0_wp)
  CALL write_dynamic_connect_deck('deck_wk_wave_padded.dat', option_row='wk_wave_padded.dat WaterKin', &
                                  option_row2='none WvHiCOff', run_tmax=1.0_wp)
  CALL CD_Run_Deck_Driver('deck_wk_wave_short.dat', 'deck_wk_wave_short', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'short WaveKinMod 1 record converged: '//TRIM(em))
  CALL CD_Run_Deck_Driver('deck_wk_wave_padded.dat', 'deck_wk_wave_padded', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'explicitly padded WaveKinMod 1 record converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
    CALL read_dynamic_connect_out('deck_wk_wave_short.out', w1a, w1b, w1c, w1d, es)
    CALL read_dynamic_connect_out('deck_wk_wave_padded.out', w2a, w2b, w2c, w2d, es)
    CALL require(MAX(ABS(w1a - w2a), ABS(w1b - w2b), ABS(w1c - w2c), ABS(w1d - w2d)) <= 0.0_wp, &
                 'short WaveKinMod 1 record is bit-identical to explicit zero padding through TMax')
  END BLOCK
  ! A WaterKin file in a subfolder names its WaveKinFile relative to the deck, as MoorDyn-F
  ! resolves it against the primary input folder: same record, same trajectory.
  CALL ensure_directory('wk_sub')
  CALL write_waterkin_file('wk_sub/wk_wave_sub.dat', wavekinmod='1', deepest_first=.FALSE., &
                           wave_file='wk_eta_short.dat', dtwave=0.25_wp)
  CALL write_dynamic_connect_deck('deck_wk_wave_sub.dat', option_row='wk_sub/wk_wave_sub.dat WaterKin', &
                                  option_row2='none WvHiCOff', run_tmax=1.0_wp)
  CALL CD_Run_Deck_Driver('deck_wk_wave_sub.dat', 'deck_wk_wave_sub', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'deck-relative WaveKinFile of a nested WaterKin file: '//TRIM(em))
  IF (es == CD_DECKDRV_OK) THEN
    BLOCK
      REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
      CALL read_dynamic_connect_out('deck_wk_wave_short.out', w1a, w1b, w1c, w1d, es)
      CALL read_dynamic_connect_out('deck_wk_wave_sub.out', w2a, w2b, w2c, w2d, es)
      CALL require(MAX(ABS(w1a - w2a), ABS(w1b - w2b), ABS(w1c - w2c), ABS(w1d - w2d)) <= 0.0_wp, &
                   'nested WaterKin file with a deck-relative WaveKinFile reproduces the flat layout')
    END BLOCK
  END IF
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'CurrentMod 1 file overrides an available host field: '//TRIM(em))
    CALL require(.NOT. wkagg%host_wave_enabled .AND. .NOT. wkagg%host_current_enabled, &
                 'file-current-only WaterKin disables both host selectors')
    CALL require(ALLOCATED(wkagg%host_current_profile_z) .AND. &
                 ALLOCATED(wkagg%host_current_profile_velocity), &
                 'file-current-only WaterKin retains its profile for coupled sampling')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  ! WaterKin provenance is independent of the combined deck environment. A
  ! CurrentMod-1-only file plus an ordinary Airy OPTION is not WaveKinMod-1;
  ! the aggregate must reach the normal host/deck double-counting boundary.
  CALL write_dynamic_connect_deck('deck_wk_cur_inline_wave.dat', &
                                  option_row='wk_cur.dat WaterKin', &
                                  option_row2='airy 1.0 1.0 0.0 waves')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_cur_inline_wave.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'double-counting') > 0 .AND. &
                 INDEX(em, 'WaveKinMod 1') == 0, &
                 'CurrentMod-1 file plus inline waves keeps distinct WaterKin provenance')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  ! Deck waves with neither a host field nor the still-water flag: nothing on the
  ! aggregate route evaluates them, so the init must fail closed by name rather than
  ! run with zero wave kinematics.
  CALL write_dynamic_connect_deck('deck_agg_selfwave.dat', option_row='airy 1.0 1.0 0.0 waves')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_agg_selfwave.dat', 0.005_wp, wkagg, es, em, env_wtrdpth=70.0_wp)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'deck waves are not evaluated') > 0, &
                 'aggregate without a host field rejects deck waves: '//TRIM(em))
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  CALL write_waterkin_file('wk_none.dat', wavekinmod='0', deepest_first=.FALSE., currentmod='0')
  CALL write_dynamic_connect_deck('deck_wk_none.dat', option_row='wk_none.dat WaterKin')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_none.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'WaterKin 0/0 accepts an available-but-disabled host field: '//TRIM(em))
    CALL require(.NOT. wkagg%host_wave_enabled .AND. .NOT. wkagg%host_current_enabled, &
                 'WaterKin 0/0 disables both host selectors')
    CALL require(.NOT. ALLOCATED(wkagg%host_current_profile_z), &
                 'WaterKin 0/0 carries no file current profile')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  CALL write_dynamic_connect_deck('deck_wk_legacy_host.dat', option_row='none current')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_legacy_host.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'deck without WaterKin accepts legacy host field: '//TRIM(em))
    CALL require(wkagg%host_wave_enabled .AND. wkagg%host_current_enabled, &
                 'no WaterKin policy retains the legacy complete-host fallback')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  ! Positional current/wave records may carry the same human-readable trailing
  ! description as ordinary value/keyword options (a copied example row must not
  ! fall through to the generic path and report keyword "2.0").
  CALL write_dynamic_connect_deck('deck_option_wave_comment.dat', &
                                  option_row='airy 2.0 8.0 0.0 waves - regular wave (m, s, deg)')
  CALL CD_Run_Deck_Driver('deck_option_wave_comment.dat', 'deck_option_wave_comment', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'wave OPTION accepts trailing description: '//TRIM(em))
  CALL write_dynamic_connect_deck('deck_option_current_comment.dat', &
                                  option_row='uniform 0.2 0.0 0.0 current - velocity (m/s)')
  CALL CD_Run_Deck_Driver('deck_option_current_comment.dat', 'deck_option_current_comment', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'current OPTION accepts trailing description: '//TRIM(em))
  ! WaveKinMod 1: reduce a sampled elevation history to Fourier components. A
  ! pure Airy history must reproduce the equivalent inline wave/current deck.
  ! The source record is twice the run TMax and its second half is deliberately
  ! contaminated. The FFT window must ignore that tail and match one clean period. The 1 Hz wave
  ! lies above the 0.5 Hz default WvHiCOff, so these decks keep every component.
  CALL write_wave_elevation_file('wk_eta.dat', 1.0_wp, 1.0_wp, 0.0_wp, nperiods=2, tail_bias=0.4_wp)
  CALL write_waterkin_file('wk_wave.dat', wavekinmod='1', deepest_first=.FALSE., &
                           wave_file='wk_eta.dat', dtwave=0.25_wp)
  CALL write_dynamic_connect_deck('deck_wk_wave.dat', option_row='wk_wave.dat WaterKin', &
                                  option_row2='none WvHiCOff', run_tmax=1.0_wp)
  CALL CD_Run_Deck_Driver('deck_wk_wave.dat', 'deck_wk_wave', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'WaveKinMod 1 elevation-history deck converged: '//TRIM(em))
  CALL write_dynamic_connect_deck('deck_wk_wave_host_tmax.dat', option_row='wk_wave.dat WaterKin', &
                                  option_row2='none WvHiCOff', omit_tmax=.TRUE.)
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_wave_host_tmax.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.FALSE., run_tmax=1.0_wp)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'WaveKinMod 1') > 0 .AND. INDEX(em, 'standalone') > 0, &
                 'caller-driven WaveKinMod 1 fails closed instead of dropping its wave field')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  CALL write_dynamic_connect_deck('deck_wk_wave_inline.dat', &
                                  option_row='profile -10.0 0.30 0.05 0.0 0.0 0.10 0.02 0.0 current', &
                                  option_row2='airy 1.0 1.0 0.0 waves', run_tmax=1.0_wp)
  CALL CD_Run_Deck_Driver('deck_wk_wave_inline.dat', 'deck_wk_wave_inline', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'WaveKinMod 1 inline twin converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d, scale
    CALL read_dynamic_connect_out('deck_wk_wave.out', w1a, w1b, w1c, w1d, es)
    CALL read_dynamic_connect_out('deck_wk_wave_inline.out', w2a, w2b, w2c, w2d, es)
    scale = MAX(1.0_wp, ABS(w2a), ABS(w2b), ABS(w2c), ABS(w2d))
    CALL require(MAX(ABS(w1a - w2a), ABS(w1b - w2b), ABS(w1c - w2c), ABS(w1d - w2d)) &
                 <= 2.0e-10_wp*scale, 'WaveKinMod 1 pure harmonic matches inline Airy response')
  END BLOCK
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_wave.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'WaveKinMod 1') > 0 .AND. INDEX(em, 'standalone') > 0, &
                 'WaveKinMod 1 plus host SeaState fails closed at the aggregate boundary')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK

  ! WaveKinMod and CurrentMod are independent: a current-only hybrid file uses
  ! WaveKinMod 0 + CurrentMod 2 and consumes the coupled host field. It remains
  ! coupled-only, while mixing self-driven mode-1 waves with host current is
  ! rejected because the nodewise host field cannot separate wave/current parts.
  CALL write_waterkin_file('wk_current_hybrid.dat', wavekinmod='0', deepest_first=.FALSE., currentmod='2')
  CALL write_dynamic_connect_deck('deck_wk_current_hybrid.dat', option_row='wk_current_hybrid.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_current_hybrid.dat', 'deck_wk_current_hybrid', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'coupled-only') > 0, &
               'CurrentMod 2 current-only file fails closed standalone')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_current_hybrid.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'CurrentMod 2 accepts current-only coupled host field: '//TRIM(em))
    CALL require(.NOT. wkagg%host_wave_enabled .AND. wkagg%host_current_enabled, &
                 'current-only hybrid preserves independent host selectors')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  CALL write_waterkin_file('wk_mixed_hybrid.dat', wavekinmod='1', deepest_first=.FALSE., &
                           wave_file='wk_eta.dat', currentmod='2', dtwave=0.25_wp)
  CALL write_dynamic_connect_deck('deck_wk_mixed_hybrid.dat', option_row='wk_mixed_hybrid.dat WaterKin', &
                                  option_row2='none WvHiCOff')
  CALL CD_Run_Deck_Driver('deck_wk_mixed_hybrid.dat', 'deck_wk_mixed_hybrid', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'cannot separate') > 0, &
               'WaveKinMod 1 plus CurrentMod 2 fails closed by mixed-source contract')

  ! WaveKinMod 2 is a coupled SeaState hybrid. Standalone remains explicitly
  ! closed, while an aggregate initialized with external_fluid accepts it and
  ! uses the existing nodewise SeaState field contract.
  CALL write_waterkin_file('wk_hybrid.dat', wavekinmod='2', deepest_first=.FALSE., currentmod='2')
  CALL write_dynamic_connect_deck('deck_wk_hybrid.dat', option_row='wk_hybrid.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_hybrid.dat', 'deck_wk_hybrid', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'coupled-only') > 0, &
               'WaveKinMod 2 fails closed standalone by name')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_hybrid.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'WaveKinMod 2 accepts coupled SeaState field: '//TRIM(em))
    CALL require(wkagg%host_wave_enabled .AND. wkagg%host_current_enabled, &
                 'full hybrid enables both host selectors')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK

  CALL write_waterkin_file('wk_ss.dat', wavekinmod='SEASTATE', deepest_first=.FALSE.)
  CALL write_dynamic_connect_deck('deck_wk_ss.dat', option_row='wk_ss.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_ss.dat', 'deck_wk_ss', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'SEASTATE') > 0, 'SEASTATE fails closed standalone')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_ss.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'SEASTATE-in-file accepts coupled host field: '//TRIM(em))
    CALL require(wkagg%host_wave_enabled .AND. .NOT. wkagg%host_current_enabled, &
                 'SEASTATE waves preserve independent CurrentMod-1 selector')
    CALL require(ALLOCATED(wkagg%host_current_profile_z) .AND. &
                 ALLOCATED(wkagg%host_current_profile_velocity), &
                 'SEASTATE waves retain the file-driven CurrentMod-1 profile')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  ! stock quoted filenames ("file.dat") parse to the same run bit-for-bit --
  ! the dequoting covers every file-valued OPTION as a class
  CALL write_dynamic_connect_deck('deck_wk_quoted.dat', option_row='"wk_cur.dat" WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_quoted.dat', 'deck_wk_quoted', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'quoted WaterKin filename converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
    CALL read_dynamic_connect_out('deck_wk.out', w1a, w1b, w1c, w1d, es)
    CALL read_dynamic_connect_out('deck_wk_quoted.out', w2a, w2b, w2c, w2d, es)
    CALL require(ABS(w1a - w2a) <= 0.0_wp .AND. ABS(w1b - w2b) <= 0.0_wp .AND. &
                 ABS(w1c - w2c) <= 0.0_wp .AND. ABS(w1d - w2d) <= 0.0_wp, &
                 'the quoted filename runs bit-identical to the bare one')
  END BLOCK
  ! the documented coupled-only keyword fails closed AT THE OPTION, before any
  ! filename handling (a stray file named SEASTATE must never masquerade)
  CALL write_dynamic_connect_deck('deck_wk_sskw2.dat', option_row='"SEASTATE" WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_sskw2.dat', 'deck_wk_sskw2', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'coupled-only') > 0, &
               'the QUOTED SEASTATE keyword also fails closed (dequote before classify)')
  CALL write_dynamic_connect_deck('deck_wk_sskw.dat', option_row='SEASTATE WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_sskw.dat', 'deck_wk_sskw', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'coupled-only') > 0, &
               'the SEASTATE WaterKin keyword fails closed standalone')
  BLOCK
    TYPE(CD_DeckAggregateType) :: wkagg
    CALL CD_Init_Deck_Aggregate('deck_wk_sskw.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.TRUE.)
    CALL require(es == CD_DECKDRV_OK, 'SEASTATE WaterKin accepts coupled host field: '//TRIM(em))
    CALL require(wkagg%host_wave_enabled .AND. wkagg%host_current_enabled, &
                 'SEASTATE WaterKin keyword enables the complete host field')
    CALL CD_End_Deck_Aggregate(wkagg)
    CALL CD_Init_Deck_Aggregate('deck_wk_sskw.dat', 0.005_wp, wkagg, es, em, &
                                env_wtrdpth=70.0_wp, external_fluid=.FALSE.)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'external_fluid') > 0, &
                 'SEASTATE WaterKin requires an actual host field')
    CALL CD_End_Deck_Aggregate(wkagg)
  END BLOCK
  CALL write_dynamic_connect_deck('deck_wk_missing.dat', option_row='no_such_wk.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_missing.dat', 'deck_wk_missing', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK, 'missing WaterKin file fails closed')
  ! the NEW file format carries two extra info lines between CurrentMod and the
  ! table headers (MoorDyn probes up to four lines) -- same profile, bit-identical
  BLOCK
    INTEGER :: u4, ios4
    OPEN (NEWUNIT=u4, FILE='wk_newfmt.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios4)
    WRITE (u4, '(A)') 'hdr1'
    WRITE (u4, '(A)') 'hdr2'
    WRITE (u4, '(A)') '--- WAVES ---'
    WRITE (u4, '(A)') '0  WaveKinMod'
    WRITE (u4, '(A)') '""  WaveKinFile'
    WRITE (u4, '(A)') '0  dtWave'
    WRITE (u4, '(A)') '0  WaveDir'
    WRITE (u4, '(A)') '2  - X type'
    WRITE (u4, '(A)') '-1, 1, 2'
    WRITE (u4, '(A)') '2  - Y type'
    WRITE (u4, '(A)') '-1, 1, 2'
    WRITE (u4, '(A)') '2  - Z type'
    WRITE (u4, '(A)') '-1, 0, 2'
    WRITE (u4, '(A)') '--- CURRENT ---'
    WRITE (u4, '(A)') '1  CurrentMod'
    WRITE (u4, '(A)') '2  - Z current grid type # Ignored if CurrentMod = 1'
    WRITE (u4, '(A)') '-600, 0, 50  - Z current grid data # Ignored if CurrentMod = 1'
    WRITE (u4, '(A)') 'z-depth x-current y-current'
    WRITE (u4, '(A)') '(m) (m/s) (m/s)'
    WRITE (u4, '(A)') '0.0  0.10  0.02'
    WRITE (u4, '(A)') '-10.0  0.30  0.05'
    WRITE (u4, '(A)') '--------------------- need this line ------------------'
    CLOSE (u4)
  END BLOCK
  CALL write_dynamic_connect_deck('deck_wk_newfmt.dat', option_row='wk_newfmt.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_newfmt.dat', 'deck_wk_newfmt', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'new-format WaterKin deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
    CALL read_dynamic_connect_out('deck_wk.out', w1a, w1b, w1c, w1d, es)
    CALL read_dynamic_connect_out('deck_wk_newfmt.out', w2a, w2b, w2c, w2d, es)
    CALL require(ABS(w1a - w2a) <= 0.0_wp .AND. ABS(w1b - w2b) <= 0.0_wp .AND. &
                 ABS(w1c - w2c) <= 0.0_wp .AND. ABS(w1d - w2d) <= 0.0_wp, &
                 'the new file format parses to the identical profile')
  END BLOCK
  ! a positive-depth table (the documented-vs-code ambiguity) fails closed rather
  ! than silently clamping every submerged node to the surface row
  BLOCK
    INTEGER :: u3, ios3
    OPEN (NEWUNIT=u3, FILE='wk_posz.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios3)
    WRITE (u3, '(A)') 'hdr1'
    WRITE (u3, '(A)') 'hdr2'
    WRITE (u3, '(A)') '--- WAVES ---'
    WRITE (u3, '(A)') '0  WaveKinMod'
    WRITE (u3, '(A)') '""  WaveKinFile'
    WRITE (u3, '(A)') '0  dtWave'
    WRITE (u3, '(A)') '0  WaveDir'
    WRITE (u3, '(A)') '2  - X type'
    WRITE (u3, '(A)') '-1, 1, 2'
    WRITE (u3, '(A)') '2  - Y type'
    WRITE (u3, '(A)') '-1, 1, 2'
    WRITE (u3, '(A)') '2  - Z type'
    WRITE (u3, '(A)') '-1, 0, 2'
    WRITE (u3, '(A)') '--- CURRENT ---'
    WRITE (u3, '(A)') '1  CurrentMod'
    WRITE (u3, '(A)') 'z ux uy'
    WRITE (u3, '(A)') '(m) (m/s) (m/s)'
    WRITE (u3, '(A)') '0.0  0.10  0.02'
    WRITE (u3, '(A)') '150.0  0.30  0.05'
    CLOSE (u3)
  END BLOCK
  CALL write_dynamic_connect_deck('deck_wk_posz.dat', option_row='wk_posz.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_posz.dat', 'deck_wk_posz', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'documented positive-depth table converges: '//TRIM(em))
  ! the documented positive-down table {0, 10} must equal the elevation table
  ! {0, -10} bitwise (z = -depth conversion)
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d, w2a, w2b, w2c, w2d
    INTEGER :: u5, ios5
    OPEN (NEWUNIT=u5, FILE='wk_posz_tw.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios5)
    WRITE (u5, '(A)') 'hdr1'
    WRITE (u5, '(A)') 'hdr2'
    WRITE (u5, '(A)') '--- WAVES ---'
    WRITE (u5, '(A)') '0  WaveKinMod'
    WRITE (u5, '(A)') '""  WaveKinFile'
    WRITE (u5, '(A)') '0  dtWave'
    WRITE (u5, '(A)') '0  WaveDir'
    WRITE (u5, '(A)') '2  - X type'
    WRITE (u5, '(A)') '-1, 1, 2'
    WRITE (u5, '(A)') '2  - Y type'
    WRITE (u5, '(A)') '-1, 1, 2'
    WRITE (u5, '(A)') '2  - Z type'
    WRITE (u5, '(A)') '-1, 0, 2'
    WRITE (u5, '(A)') '--- CURRENT ---'
    WRITE (u5, '(A)') '1  CurrentMod'
    WRITE (u5, '(A)') 'z ux uy'
    WRITE (u5, '(A)') '(m) (m/s) (m/s)'
    WRITE (u5, '(A)') '0.0  0.10  0.02'
    WRITE (u5, '(A)') '10.0  0.30  0.05'
    CLOSE (u5)
    CALL write_dynamic_connect_deck('deck_wk_posz_tw.dat', option_row='wk_posz_tw.dat WaterKin')
    CALL CD_Run_Deck_Driver('deck_wk_posz_tw.dat', 'deck_wk_posz_tw', conv, es, em)
    CALL require(es == CD_DECKDRV_OK .AND. conv, 'positive-depth twin converged: '//TRIM(em))
    CALL read_dynamic_connect_out('deck_wk.out', w1a, w1b, w1c, w1d, es)
    CALL read_dynamic_connect_out('deck_wk_posz_tw.out', w2a, w2b, w2c, w2d, es)
    CALL require(ABS(w1a - w2a) <= 0.0_wp .AND. ABS(w1b - w2b) <= 0.0_wp .AND. &
                 ABS(w1c - w2c) <= 0.0_wp .AND. ABS(w1d - w2d) <= 0.0_wp, &
                 'the documented positive-depth table converts to the identical profile')
  END BLOCK
  ! mixed-sign depth columns are ambiguous between the two conventions
  BLOCK
    INTEGER :: u6, ios6
    OPEN (NEWUNIT=u6, FILE='wk_mixed.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios6)
    WRITE (u6, '(A)') 'hdr1'
    WRITE (u6, '(A)') 'hdr2'
    WRITE (u6, '(A)') '--- WAVES ---'
    WRITE (u6, '(A)') '0  WaveKinMod'
    WRITE (u6, '(A)') '""  WaveKinFile'
    WRITE (u6, '(A)') '0  dtWave'
    WRITE (u6, '(A)') '0  WaveDir'
    WRITE (u6, '(A)') '2  - X type'
    WRITE (u6, '(A)') '-1, 1, 2'
    WRITE (u6, '(A)') '2  - Y type'
    WRITE (u6, '(A)') '-1, 1, 2'
    WRITE (u6, '(A)') '2  - Z type'
    WRITE (u6, '(A)') '-1, 0, 2'
    WRITE (u6, '(A)') '--- CURRENT ---'
    WRITE (u6, '(A)') '1  CurrentMod'
    WRITE (u6, '(A)') 'z ux uy'
    WRITE (u6, '(A)') '(m) (m/s) (m/s)'
    WRITE (u6, '(A)') '-5.0  0.10  0.02'
    WRITE (u6, '(A)') '10.0  0.30  0.05'
    CLOSE (u6)
    CALL write_dynamic_connect_deck('deck_wk_mixed.dat', option_row='wk_mixed.dat WaterKin')
    CALL CD_Run_Deck_Driver('deck_wk_mixed.dat', 'deck_wk_mixed', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'mixes signs') > 0, &
                 'mixed-sign depth column fails closed')
  END BLOCK
  ! last option wins: `0 WaterKin` after a filename row disables the file --
  ! the run must be bit-identical to a deck with no WaterKin at all
  CALL write_dynamic_connect_deck('deck_wk_off.dat', option_row='wk_cur.dat WaterKin', &
                                  option_row2='0 WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_off.dat', 'deck_wk_off', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'overridden WaterKin deck converged: '//TRIM(em))
  BLOCK
    REAL(wp) :: w1a, w1b, w1c, w1d
    CALL read_dynamic_connect_out('deck_wk_off.out', w1a, w1b, w1c, w1d, es)
    CALL require(es == 0, 'read overridden WaterKin outputs')
    CALL require(ABS(w1a - connect_ten1) <= 0.0_wp .AND. ABS(w1b - connect_ten2) <= 0.0_wp .AND. &
                 ABS(w1c - connect_z) <= 0.0_wp .AND. ABS(w1d - connect_vz) <= 0.0_wp, &
                 '0 WaterKin after a filename disables the file (last option wins, bit-identical)')
  END BLOCK
  CALL write_dynamic_connect_deck('deck_wk_dup.dat', option_row='uniform 0.2 0.0 0.0 current', &
                                  option_row2='wk_cur.dat WaterKin')
  CALL CD_Run_Deck_Driver('deck_wk_dup.dat', 'deck_wk_dup', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'double-counting') > 0, &
               'inline current + WaterKin current fails closed (double-counting)')
  ! MoorDyn viscoelastic pipe syntax (EA = Es|Ed[|alpha]): both dynamic-
  ! stiffness forms now RUN through the static driver (statics see the
  ! composite Es; the SLS is a dynamic-path model), and the malformed
  ! parameter classes fail closed by name at parse.
  CALL write_visco_deck('deck_visco.dat', '1.424e+08|1.586e+08', '4E9|11E6')
  CALL CD_Run_Deck_Driver('deck_visco.dat', 'deck_visco', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'viscoelastic ElasticMod-2 deck solves')
  CALL write_visco_deck('deck_visco3.dat', '1.424e+08|1.586e+08|0.4', '4E9|11E6')
  CALL CD_Run_Deck_Driver('deck_visco3.dat', 'deck_visco3', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'viscoelastic ElasticMod-3 deck (r-test row) solves')
  CALL write_visco_deck('deck_visco_bad.dat', '1.424e+08|1.0e+08', '4E9|11E6')
  CALL CD_Run_Deck_Driver('deck_visco_bad.dat', 'deck_visco_bad', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'exceed') > 0, &
               'viscoelastic Ed below Es fails closed at parse')
  CALL write_visco_deck('deck_visco_bad3.dat', '1.424e+08|1.586e+08|-0.4', '4E9|11E6')
  CALL CD_Run_Deck_Driver('deck_visco_bad3.dat', 'deck_visco_bad3', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'load-dependent') > 0, &
               'negative vbeta fails closed at parse')
  CALL write_visco_deck('deck_visco_bad4.dat', '1.424e+08|1.586e+08', '4E9|-1E6')
  CALL CD_Run_Deck_Driver('deck_visco_bad4.dat', 'deck_visco_bad4', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'Bd') > 0, &
               'negative dynamic damping Bd fails closed at parse')
  ! a FOURTH bar-separated EA field is surplus: it must fail closed, never
  ! silently truncate to a valid 3-part token
  CALL write_visco_deck('deck_visco_bad5.dat', '1.424e+08|1.586e+08|0.4|9.9', '4E9|11E6')
  CALL CD_Run_Deck_Driver('deck_visco_bad5.dat', 'deck_visco_bad5', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'at most 3') > 0, &
               'a 4-part EA column fails closed (no silent truncation)')
  ! viscoelastic on a FINITE-EI (EI > 0) line type: the bending build path
  ! carries no SLS state, so it must fail closed by name rather than silently
  ! run on the composite Es alone
  CALL write_visco_deck('deck_visco_finite.dat', '1.424e+08|1.586e+08', '4E9|11E6', ei_col='5.0e3')
  CALL CD_Run_Deck_Driver('deck_visco_finite.dat', 'deck_visco_finite', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'finite-EI') > 0, &
               'viscoelastic on a finite-EI line type fails closed')
  ! Syrope working-curve dialect (EA = SYROPE:<file>|alpha|beta, BA = BA_s|BA_d):
  ! parses + validates, reads the settings/OWC files, and builds a single-
  ! section taut line; a flat WtrDpth seabed floor is supported (a taut line clears
  ! it), while bathymetry/hydro sub-cases fail closed by name.
  ! the settings + OWC files (used by the successful builds below and needed for
  ! the parse checks to reach past the settings read)
  CALL write_syrope_files('syrope.dat', 'owc_test.dat')
  ! a Syrope line with a flat WtrDpth seabed floor now BUILDS (2.5 % strain, within
  ! the OWC table): the taut line at z = 0 clears the floor, so the penalty contact
  ! stays inactive and the OWC-secant static IC is unchanged. This is the coupled-
  ! mooring path -- the host always supplies WtrDpth.
  CALL write_syrope_deck('deck_syrope.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5', wtrdpth=10.0_wp)
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
    CALL CD_Init_Deck_Models('deck_syrope.dat', smodels, es, em)
    CALL require(es == CD_DECKDRV_OK, 'Syrope with a flat seabed floor builds: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(SIZE(smodels) == 1, 'Syrope seabed deck yields exactly one model')
      CALL CD_End_Model(smodels(1), es, em)
    END IF
  END BLOCK
  CALL write_visco_deck('deck_syrope_bad1.dat', 'SYROPE:syrope.dat|1.53e8', '5.0e10|1.0e5')
  CALL CD_Run_Deck_Driver('deck_syrope_bad1.dat', 'deck_syrope_bad1', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'three parts') > 0, &
               'Syrope EA missing beta fails closed at parse')
  CALL write_visco_deck('deck_syrope_bad2.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10')
  CALL CD_Run_Deck_Driver('deck_syrope_bad2.dat', 'deck_syrope_bad2', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'two parts') > 0, &
               'Syrope BA missing c2 fails closed at parse')
  CALL write_visco_deck('deck_syrope_bad3.dat', 'SYROPE:|1.53e8|23.12', '5.0e10|1.0e5')
  CALL CD_Run_Deck_Driver('deck_syrope_bad3.dat', 'deck_syrope_bad3', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'no settings file') > 0, &
               'Syrope EA with no settings file fails closed at parse')
  ! settings-file rows: a malformed k1 is named (not "needs ... k1"), a repeated key is
  ! rejected, and a "Strain / Tension" header row of the OWC table is skipped as a header
  BLOCK
    INTEGER :: u, ios, i
    OPEN (NEWUNIT=u, FILE='syrope_badk1.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'owc_test.dat  OWC    Original working curve table path'
    WRITE (u, '(A)') 'LINEAR      WCType Working curve formula'
    WRITE (u, '(A)') '0,6         k1     shape parameter p1'
    WRITE (u, '(A)') '0.0         k2     shape parameter p2'
    CLOSE (u)
    CALL write_syrope_deck('deck_syrope_badk1.dat', 'SYROPE:syrope_badk1.dat|1.53e8|23.12', '5.0e10|1.0e5')
    CALL CD_Run_Deck_Driver('deck_syrope_badk1.dat', 'deck_syrope_badk1', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'Syrope k1 value "0,6" is not a plain number') > 0, &
                 'malformed Syrope k1 is named: '//TRIM(em))
    OPEN (NEWUNIT=u, FILE='syrope_dupk2.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'owc_test.dat  OWC    Original working curve table path'
    WRITE (u, '(A)') 'LINEAR      WCType Working curve formula'
    WRITE (u, '(A)') '0.6         k1     shape parameter p1'
    WRITE (u, '(A)') '0.0         k2     shape parameter p2'
    WRITE (u, '(A)') '0.1         k2     shape parameter p2'
    CLOSE (u)
    CALL write_syrope_deck('deck_syrope_dupk2.dat', 'SYROPE:syrope_dupk2.dat|1.53e8|23.12', '5.0e10|1.0e5')
    CALL CD_Run_Deck_Driver('deck_syrope_dupk2.dat', 'deck_syrope_dupk2', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'duplicate Syrope k2 row') > 0, &
                 'repeated Syrope k2 row fails closed: '//TRIM(em))
    ! the shipped OWC table with its two header rows replaced by one "Strain / Tension" row
    CALL write_syrope_files('syrope_slash.dat', 'owc_slash.dat')
    BLOCK
      CHARACTER(64) :: rows(32)
      OPEN (NEWUNIT=u, FILE='owc_slash.dat', STATUS='OLD', ACTION='READ', IOSTAT=ios)
      DO i = 1, 32
        READ (u, '(A)') rows(i)
      END DO
      CLOSE (u)
      OPEN (NEWUNIT=u, FILE='owc_slash.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
      WRITE (u, '(A)') 'Strain / Tension'
      DO i = 3, 32
        WRITE (u, '(A)') TRIM(rows(i))
      END DO
      CLOSE (u)
    END BLOCK
    CALL write_syrope_deck('deck_syrope_slash.dat', 'SYROPE:syrope_slash.dat|1.53e8|23.12', '5.0e10|1.0e5', &
                           wtrdpth=10.0_wp)
    BLOCK
      TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
      CALL CD_Init_Deck_Models('deck_syrope_slash.dat', smodels, es, em)
      CALL require(es == CD_DECKDRV_OK, 'OWC header "Strain / Tension" is skipped as a header: '//TRIM(em))
      IF (es == CD_DECKDRV_OK) CALL CD_End_Model(smodels(1), es, em)
    END BLOCK
  END BLOCK
  ! Unsupported Syrope combinations are rejected by their own feature name.
  ! These gates prevent a future dispatch change from silently falling back to
  ! the placeholder linear EA or to a load path that carries no Syrope state.
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
    ! a Syrope line split into two Syrope sections (the same mesh) is the same line: the
    ! composite build's mean-tension secant iteration lands on the single section's equilibrium
    BLOCK
      TYPE(CD_ModelType), ALLOCATABLE :: one(:)
      REAL(wp) :: t1(4), t2(4)
      CALL write_syrope_deck('deck_syrope_one.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5')
      CALL CD_Init_Deck_Models('deck_syrope_one.dat', one, es, em)
      CALL require(es == CD_DECKDRV_OK, 'single-section Syrope line builds: '//TRIM(em))
      CALL write_syrope_deck('deck_syrope_composite.dat', 'SYROPE:syrope.dat|1.53e8|23.12', &
                             '5.0e10|1.0e5', nsections=2)
      CALL CD_Init_Deck_Models('deck_syrope_composite.dat', smodels, es, em)
      CALL require(es == CD_DECKDRV_OK, 'a Syrope line of two Syrope sections builds: '//TRIM(em))
      IF (ALLOCATED(one) .AND. ALLOCATED(smodels)) THEN
        CALL CD_Get_Model_Tension(one(1), t1, es, em)
        CALL CD_Get_Model_Tension(smodels(1), t2, es, em)
        CALL require(MAXVAL(ABS(t2 - t1)) <= 1.0e-8_wp*MAXVAL(t1), &
                     'two Syrope sections reach the single section''s static tensions')
        CALL CD_End_Model(one(1), es, em)
        CALL CD_End_Model(smodels(1), es, em)
      END IF
    END BLOCK

    CALL write_syrope_deck('deck_syrope_finite_ei.dat', 'SYROPE:syrope.dat|1.53e8|23.12', &
                           '5.0e10|1.0e5', ei=5.0e3_wp)
    CALL CD_Init_Deck_Models('deck_syrope_finite_ei.dat', smodels, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'finite-EI') > 0, &
                 'finite-EI Syrope fails closed by name')

    CALL write_syrope_deck('deck_syrope_current.dat', 'SYROPE:syrope.dat|1.53e8|23.12', &
                           '5.0e10|1.0e5', option_row='uniform 1.0 0.0 0.0 current')
    ! a Syrope line takes the hydrodynamics of any EI = 0 line (MoorDyn's): current and waves
    CALL CD_Init_Deck_Models('deck_syrope_current.dat', smodels, es, em)
    CALL require(es == CD_DECKDRV_OK, 'current-loaded Syrope builds: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(smodels(1)%has_syrope .AND. smodels(1)%has_morison_drag, &
                   'current-loaded Syrope keeps its working curve and takes the Morison drag')
      CALL CD_End_Model(smodels(1), es, em)
    END IF

    CALL write_syrope_deck('deck_syrope_wave.dat', 'SYROPE:syrope.dat|1.53e8|23.12', &
                           '5.0e10|1.0e5', wtrdpth=10.0_wp, option_row='airy 1.0 8.0 0.0 waves')
    CALL CD_Init_Deck_Models('deck_syrope_wave.dat', smodels, es, em)
    CALL require(es == CD_DECKDRV_OK, 'wave-loaded Syrope builds: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(smodels(1)%has_syrope .AND. smodels(1)%has_morison_drag, &
                   'wave-loaded Syrope keeps its working curve and takes the Morison drag')
      CALL CD_End_Model(smodels(1), es, em)
    END IF
  END BLOCK
  ! end-to-end Syrope deck build: a single-section taut line (no seabed/hydro)
  ! builds the DYNAMIC model through the OWC-secant static solve, initializes
  ! near the working-curve fixed point, and steps with bounded, finite tension
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
    REAL(wp) :: syr_ten(4), t0
    INTEGER :: ne_s, kk, ni
    LOGICAL :: cvg, stl
    CALL write_syrope_deck('deck_syrope_build.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5')
    CALL CD_Init_Deck_Models('deck_syrope_build.dat', smodels, es, em)
    ! split the allocation check off the status check: Fortran does not short-circuit
    ! .AND., so SIZE(smodels) must not be evaluated when the (failed) init left it unallocated
    CALL require(es == CD_DECKDRV_OK, 'Syrope single-section deck builds the dynamic model: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(SIZE(smodels) == 1, 'Syrope single-section deck yields exactly one model')
      ne_s = CD_Model_NElem(smodels(1), es, em)
      CALL CD_Get_Model_Tension(smodels(1), syr_ten(1:ne_s), es, em)
      t0 = syr_ten(1)
      ! ~2.5 % strain on this OWC table is ~1.5 MN
      CALL require(es == CD_MODEL_OK .AND. t0 > 1.0e6_wp .AND. t0 < 2.0e6_wp, &
                   'Syrope deck IC tension is on the working curve')
      DO kk = 1, 6
        CALL CD_Step_Model(smodels(1), 0.02_wp, cvg, stl, ni, es, em)
        CALL require(es == CD_MODEL_OK, 'Syrope deck step status: '//TRIM(em))
        CALL require(cvg .AND. .NOT. stl, 'Syrope deck step converges without stalling')
        CALL CD_Get_Model_Tension(smodels(1), syr_ten(1:ne_s), es, em)
        CALL require(syr_ten(1) > 0.5e6_wp .AND. syr_ten(1) < 2.5e6_wp, 'Syrope deck tension bounded')
      END DO
      CALL CD_End_Model(smodels(1), es, em)
    END IF
  END BLOCK
  ! MoorDyn-F load-history section: Tmax0 sets the working curve (the running maximum
  ! survives into model state) and the slow strain is the equilibrium state at the geometry.
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
    REAL(wp) :: slow_ic(4), tmax_ic(4)
    CALL write_syrope_deck('deck_syrope_ic.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5', &
                           syrope_ic_row='1 2.0e6 1.0e6')
    CALL CD_Init_Deck_Models('deck_syrope_ic.dat', smodels, es, em)
    CALL require(es == CD_DECKDRV_OK, 'SYROPE IC deck builds: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL CD_Get_Model_Syrope_State(smodels(1), slow_ic, tmax_ic, es, em)
      CALL require(es == CD_MODEL_OK .AND. nan_max_abs(tmax_ic - 2.0e6_wp) <= &
                   EPSILON(1.0_wp)*2.0e6_wp, 'SYROPE IC preserves Tmax0')
      CALL require(ALL(slow_ic > 0.0_wp), 'SYROPE IC derives a positive slow strain')
      CALL CD_End_Model(smodels(1), es, em)
    END IF
    CALL write_syrope_deck('deck_syrope_bad_ic.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5', &
                           syrope_ic_row='1 1.0e6 2.0e6')
    CALL CD_Init_Deck_Models('deck_syrope_bad_ic.dat', smodels, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'Tmax0 >= Tmean0') > 0, &
                 'SYROPE IC rejects Tmax0 below Tmean0')
    ! a line pre-strained to 8 % on a 6 % OWC table fails closed at init (the table
    ! interpolation would otherwise clamp and run a silently mis-tensioned line)
    CALL write_syrope_deck('deck_syrope_beyond.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5', &
                           span=2.16_wp)
    CALL CD_Init_Deck_Models('deck_syrope_beyond.dat', smodels, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'outside its OWC table') > 0, &
                 'Syrope initial strain beyond the OWC table fails closed: '//TRIM(em))
    ! a pretension whose working curve is inadmissible names the slope condition
    CALL write_syrope_deck('deck_syrope_lowpre.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5', &
                           span=2.02_wp)
    CALL CD_Init_Deck_Models('deck_syrope_lowpre.dat', smodels, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'alpha + beta*T') > 0, &
                 'Syrope inadmissible pretension names the working-curve condition: '//TRIM(em))
  END BLOCK
  ! Regression (SYROPE IC equilibrium): a 472 m sagging taut rope with Tmax0 = 2 MN and a
  ! Tmean0 of 1.2 MN that its geometry cannot carry. Seeding the dynamic state from Tmean0
  ! against a static solve on the OWC secant would carry 0 N at t = 0 and snap. The
  ! rope must start in the static equilibrium of its Tmax0 working curve: a positive
  ! tension that the held line keeps (no initial transient).
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
    REAL(wp) :: ten0(50), ten(50), dev
    INTEGER :: u, ios, kk, ni
    LOGICAL :: cvg, stl
    ! the shipped EXP working curve (k1 = 0.2, k2 = 1.5) on the same OWC table
    OPEN (NEWUNIT=u, FILE='syrope_exp.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'owc_test.dat  OWC    Original working curve table path'
    WRITE (u, '(A)') 'EXP         WCType Working curve formula'
    WRITE (u, '(A)') '0.2         k1     shape parameter p1'
    WRITE (u, '(A)') '1.5         k2     shape parameter p2'
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE='deck_syrope_ic_eq.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Syrope IC equilibrium'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rope 0.1438 22.42 SYROPE:syrope_exp.dat|1.53e8|23.12 5.0e10|1.0e5 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 500.0 0.0 -200.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Vessel 58.0 0.0 -14.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SYROPE IC ---'
    WRITE (u, '(A)') 'Line(s) Tmax0 Tmean0'
    WRITE (u, '(A)') '(-) (N) (N)'
    WRITE (u, '(A)') '1 2.0e6 1.2e6'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rope 471.7 50'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '1.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL CD_Init_Deck_Models('deck_syrope_ic_eq.dat', smodels, es, em)
    CALL require(es == CD_DECKDRV_OK, 'SYROPE IC equilibrium deck builds: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL CD_Get_Model_Tension(smodels(1), ten0, es, em)
      ! the Tmax0 = 2 MN working curve at the ~1.7 % geometric strain carries ~0.41 MN
      CALL require(es == CD_MODEL_OK .AND. MINVAL(ten0) > 3.5e5_wp .AND. MAXVAL(ten0) < 4.5e5_wp, &
                   'SYROPE IC starts at the Tmax0 working-curve equilibrium tension')
      dev = 0.0_wp
      DO kk = 1, 20
        CALL CD_Step_Model(smodels(1), 0.05_wp, cvg, stl, ni, es, em)
        IF (es /= CD_MODEL_OK) EXIT
        CALL CD_Get_Model_Tension(smodels(1), ten, es, em)
        dev = MAX(dev, nan_max_abs((ten - ten0)/ten0))
      END DO
      WRITE (*, '(A,ES10.3)') 'SYROPE IC equilibrium: max relative element-tension change over 1 s = ', dev
      CALL require(es == CD_MODEL_OK .AND. dev < 1.0e-3_wp, &
                   'SYROPE IC t = 0 is a static equilibrium (no initial transient)')
      CALL CD_End_Model(smodels(1), es, em)
    END IF
  END BLOCK
  ! Regression: a Syrope deck WITHOUT dtM/TMax routes to the static EI=0 path,
  ! where types(...)%ea is only the placeholder alpha. That path must fail closed
  ! (no wrong static .out), pointing at the dynamic working-curve path.
  CALL write_syrope_deck('deck_syrope_static.dat', 'SYROPE:syrope.dat|1.53e8|23.12', '5.0e10|1.0e5')
  CALL CD_Run_Deck_Driver('deck_syrope_static.dat', 'deck_syrope_static', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'static output') > 0, &
               'Syrope without dtM/TMax fails closed on the static path (no placeholder-EA .out)')
  ! Regression: a plain LINE TYPE declared BEFORE the Syrope type -> the EA
  ! override must target the LINE-LOCAL type index, not the global one
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
    REAL(wp) :: syr_ten(4)
    INTEGER :: u, ios, ne_s
    OPEN (NEWUNIT=u, FILE='deck_syrope_2type.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Syrope with a leading plain type'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'plain 0.1 10.0 1.0e8 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') 'rope 0.1438 22.42 SYROPE:syrope.dat|1.53e8|23.12 5.0e10|1.0e5 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Vessel 2.05 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 rope 2.0 4'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL CD_Init_Deck_Models('deck_syrope_2type.dat', smodels, es, em)
    CALL require(es == CD_DECKDRV_OK, &
                 'Syrope with a leading plain type builds (line-local EA index): '//TRIM(em))
    IF (es == CD_DECKDRV_OK) THEN
      CALL require(SIZE(smodels) == 1, 'Syrope-after-plain-type deck yields exactly one model')
      ne_s = CD_Model_NElem(smodels(1), es, em)
      CALL CD_Get_Model_Tension(smodels(1), syr_ten(1:ne_s), es, em)
      CALL require(es == CD_MODEL_OK .AND. syr_ten(1) > 1.0e6_wp .AND. syr_ten(1) < 2.0e6_wp, &
                   'Syrope-after-plain-type IC tension is on the working curve')
      CALL CD_End_Model(smodels(1), es, em)
    END IF
  END BLOCK
  ! Regression: a SYROPE settings path longer than a deck identifier is resolved whole
  ! (the EA column has a path-length buffer), never truncated to a different file.
  CALL write_syrope_files('syrope_'//REPEAT('a', 90)//'.dat', 'owc_test.dat')
  CALL write_syrope_deck('deck_syrope_long.dat', 'SYROPE:syrope_'//REPEAT('a', 90)//'.dat|1.53e8|23.12', &
                         '5.0e10|1.0e5', wtrdpth=10.0_wp)
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
    CALL CD_Init_Deck_Models('deck_syrope_long.dat', smodels, es, em)
    CALL require(es == CD_DECKDRV_OK, 'Syrope settings path longer than 64 characters builds: '//TRIM(em))
    IF (es == CD_DECKDRV_OK) CALL end_test_models(smodels)
  END BLOCK
  CALL write_static_failure_deck('deck_fail_static.dat')
  CALL CD_Run_Deck_Driver('deck_fail_static.dat', 'deck_fail_static', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'FAILURE') > 0, 'static FAILURE deck fails closed')
  CALL write_dynamic_connect_deck('deck_fail_entry.dat', failure_row='1 P2 2 0.004 0.0')
  BLOCK
    TYPE(CD_ModelType), ALLOCATABLE :: fmodels(:)
    CALL CD_Init_Deck_Models('deck_fail_entry.dat', fmodels, es, em)
    CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'FAILURE') > 0, &
                 'FAILURE deck through a non-failure entry point fails closed')
  END BLOCK
  CALL write_dynamic_connect_added_mass_deck('deck_connect_added0.dat', 0.0_wp)
  CALL CD_Run_Deck_Driver('deck_connect_added0.dat', 'deck_connect_added0', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Connect still-water no-added-mass deck converged: '//TRIM(em))
  CALL read_dynamic_connect_out('deck_connect_added0.out', connect_nomass_ten1, connect_nomass_ten2, &
                                connect_nomass_z, connect_nomass_vz, es)
  CALL require(es == 0, 'read dynamic Connect no-added-mass state')
  CALL write_dynamic_connect_added_mass_deck('deck_connect_added1.dat', 5.0_wp)
  CALL CD_Run_Deck_Driver('deck_connect_added1.dat', 'deck_connect_added1', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Connect still-water added-mass deck converged: '//TRIM(em))
  CALL read_dynamic_connect_out('deck_connect_added1.out', connect_added_ten1, connect_added_ten2, &
                                connect_added_z, connect_added_vz, es)
  CALL require(es == 0, 'read dynamic Connect added-mass state')
  CALL require(ABS(connect_added_vz) < 0.5_wp*ABS(connect_nomass_vz), &
               'still-water point Ca adds inertia without declared current/wave')
  CALL write_dynamic_connect_current_deck('deck_connect_current.dat')
  CALL CD_Run_Deck_Driver('deck_connect_current.dat', 'deck_connect_current', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Connect-current deck converged: '//TRIM(em))
  CALL check_dynamic_connect_current_out('deck_connect_current.out')
  CALL write_dynamic_point3_body_deck('deck_point3_body.dat')
  CALL CD_Run_Deck_Driver('deck_point3_body.dat', 'deck_point3_body', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Point3 BODY deck converged: '//TRIM(em))
  CALL check_dynamic_point3_body_out('deck_point3_body.out')
  CALL write_dynamic_point3_wave_body_deck('deck_point3_wave_body.dat')
  CALL CD_Run_Deck_Driver('deck_point3_wave_body.dat', 'deck_point3_wave_body', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Point3 BODY wave deck converged: '//TRIM(em))
  CALL check_dynamic_body_wave_out('deck_point3_wave_body.out', 'dynamic Point3 BODY wave')
  CALL write_dynamic_rigid6_body_deck('deck_rigid6_body.dat')
  CALL CD_Run_Deck_Driver('deck_rigid6_body.dat', 'deck_rigid6_body', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 BODY deck converged: '//TRIM(em))
  CALL check_dynamic_rigid6_body_out('deck_rigid6_body.out')
  CALL write_dynamic_rigid6_body_deck('deck_rigid6_line_outputs.dat', line_outputs=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_rigid6_line_outputs.dat', 'deck_rigid6_line_outputs', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 LINE Outputs deck converged: '//TRIM(em))
  ! this rig's line (2.2 m over a 2.0 m drop) is genuinely slack: the gate asserts the
  ! TENSION-ONLY readout (clamped zero), the regression for the MoorDyn-convention fix
  CALL check_dynamic_object_line_output_files('deck_rigid6_line_outputs.Line1.p.out', &
                                              'deck_rigid6_line_outputs.Line1.t.out', slack=.TRUE.)
  CALL write_dynamic_rigid6_added_mass_deck('deck_rigid6_added0.dat', 0.0_wp)
  CALL CD_Run_Deck_Driver('deck_rigid6_added0.dat', 'deck_rigid6_added0', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 still-water no-added-mass deck converged: '//TRIM(em))
  CALL read_dynamic_rigid6_first_step_z('deck_rigid6_added0.out', rigid6_nomass_z, es)
  CALL require(es == 0, 'read dynamic Rigid6 no-added-mass z')
  CALL write_dynamic_rigid6_added_mass_deck('deck_rigid6_added1.dat', 20.0_wp)
  CALL CD_Run_Deck_Driver('deck_rigid6_added1.dat', 'deck_rigid6_added1', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 still-water added-mass deck converged: '//TRIM(em))
  CALL read_dynamic_rigid6_first_step_z('deck_rigid6_added1.out', rigid6_added_z, es)
  CALL require(es == 0, 'read dynamic Rigid6 added-mass z')
  CALL require(ABS(rigid6_added_z) < 0.98_wp*ABS(rigid6_nomass_z), &
               'still-water Rigid6 Ca adds inertia without declared current/wave')
  CALL write_dynamic_rigid6_body_deck('deck_rigid6_bathy.dat', 'deck_bathy.xyz')
  CALL CD_Run_Deck_Driver('deck_rigid6_bathy.dat', 'deck_rigid6_bathy', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 bathymetry deck converged: '//TRIM(em))
  CALL check_dynamic_rigid6_body_out('deck_rigid6_bathy.out')
  CALL write_bathymetry_file('deck_rigid6_contact.xyz', 0.5_wp)
  CALL write_dynamic_rigid6_contact_deck('deck_rigid6_contact_deep.dat', 'deck_bathy.xyz')
  CALL write_dynamic_rigid6_contact_deck('deck_rigid6_contact.dat', 'deck_rigid6_contact.xyz')
  CALL CD_Run_Deck_Driver('deck_rigid6_contact_deep.dat', 'deck_rigid6_contact_deep', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 deep-bathymetry contact deck converged: '//TRIM(em))
  CALL CD_Run_Deck_Driver('deck_rigid6_contact.dat', 'deck_rigid6_contact', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 active-bathymetry contact deck converged: '//TRIM(em))
  CALL read_dynamic_rigid6_point_z('deck_rigid6_contact_deep.out', rigid6_deep_z, es)
  CALL require(es == 0, 'read dynamic Rigid6 deep-contact z')
  CALL read_dynamic_rigid6_point_z('deck_rigid6_contact.out', rigid6_contact_z, es)
  CALL require(es == 0, 'read dynamic Rigid6 active-contact z')
  CALL require(rigid6_contact_z > rigid6_deep_z + 1.0e-4_wp, 'Rigid6 bathymetry contact lifts penetrated body')
  CALL write_dynamic_rigid6_rotation_deck('deck_rigid6_rotation.dat')
  CALL CD_Run_Deck_Driver('deck_rigid6_rotation.dat', 'deck_rigid6_rotation', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 rotation deck converged: '//TRIM(em))
  CALL check_dynamic_rigid6_rotation_out('deck_rigid6_rotation.out')
  CALL write_dynamic_rigid6_jonswap_body_deck('deck_rigid6_jonswap_body.dat')
  CALL CD_Run_Deck_Driver('deck_rigid6_jonswap_body.dat', 'deck_rigid6_jonswap_body', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6 BODY JONSWAP deck converged: '//TRIM(em))
  CALL check_dynamic_body_wave_out('deck_rigid6_jonswap_body.out', 'dynamic Rigid6 BODY JONSWAP')
  CALL write_dynamic_rigid6_current_deck('deck_rigid6_current.dat')
  CALL CD_Run_Deck_Driver('deck_rigid6_current.dat', 'deck_rigid6_current', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic Rigid6-current deck converged: '//TRIM(em))
  CALL check_dynamic_rigid6_current_out('deck_rigid6_current.out')
  CALL write_prescribed_rigid6_motion_file('deck_rigid6_motion.txt')
  CALL write_dynamic_rigid6_motion_deck('deck_rigid6_motion.dat', 'deck_rigid6_motion.txt')
  CALL CD_Run_Deck_Driver('deck_rigid6_motion.dat', 'deck_rigid6_motion', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic prescribed Rigid6 deck converged: '//TRIM(em))
  CALL check_dynamic_rigid6_motion_out('deck_rigid6_motion.out')
  CALL write_bad_rigid6_motion_file('deck_rigid6_bad_motion.txt')
  CALL write_dynamic_rigid6_bad_motion_deck('deck_rigid6_bad_motion.dat', 'deck_rigid6_bad_motion.txt')
  CALL CD_Run_Deck_Driver('deck_rigid6_bad_motion.dat', 'deck_rigid6_bad_motion', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'pure translation') > 0, &
               'inconsistent prescribed Rigid6 motion fails closed: '//TRIM(em))
  CALL write_turbine_vocab_deck('deck_turbine_vocab.dat')
  CALL CD_Run_Deck_Driver('deck_turbine_vocab.dat', 'deck_turbine_vocab', conv, es, em)
  CALL require(es == CD_DECKDRV_BADINPUT .AND. INDEX(em, 'CompMooring=5') > 0, &
               'FAST.Farm Turbine<J> deck fails closed outside the aggregate path: '//TRIM(em))
  CALL write_rotational_rigid6_motion_file('deck_rigid6_rotmotion.txt', non_rigid=.FALSE.)
  CALL write_dynamic_rigid6_rotmotion_deck('deck_rigid6_rotmotion.dat', 'deck_rigid6_rotmotion.txt')
  CALL CD_Run_Deck_Driver('deck_rigid6_rotmotion.dat', 'deck_rigid6_rotmotion', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'prescribed rotational Rigid6 deck converged: '//TRIM(em))
  CALL check_dynamic_rigid6_rotmotion_out('deck_rigid6_rotmotion.out')
  CALL write_rotational_rigid6_motion_file('deck_rigid6_nonrigid.txt', non_rigid=.TRUE.)
  CALL write_dynamic_rigid6_rotmotion_deck('deck_rigid6_nonrigid.dat', 'deck_rigid6_nonrigid.txt')
  CALL CD_Run_Deck_Driver('deck_rigid6_nonrigid.dat', 'deck_rigid6_nonrigid', conv, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'rigid motion') > 0, &
               'non-rigid prescribed Rigid6 rows fail closed: '//TRIM(em))
  CALL write_dynamic_rod_deck('deck_rod.dat')
  CALL CD_Run_Deck_Driver('deck_rod.dat', 'deck_rod', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic ROD deck converged: '//TRIM(em))
  CALL check_dynamic_rod_out('deck_rod.out')
  CALL write_dynamic_rod_deck('deck_rod_line_outputs.dat', line_outputs=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_rod_line_outputs.dat', 'deck_rod_line_outputs', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic ROD LINE Outputs deck converged: '//TRIM(em))
  CALL check_dynamic_object_line_output_files('deck_rod_line_outputs.Line1.p.out', &
                                              'deck_rod_line_outputs.Line1.t.out')
  CALL check_dynamic_object_line_output_files('deck_rod_line_outputs.Line2.p.out', &
                                              'deck_rod_line_outputs.Line2.t.out')
  CALL write_dynamic_rod_deck('deck_rod_outputs.dat', rod_outputs=.TRUE.)
  CALL CD_Run_Deck_Driver('deck_rod_outputs.dat', 'deck_rod_outputs', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic ROD endpoint Outputs deck converged: '//TRIM(em))
  CALL check_dynamic_rod_position_output_file('deck_rod_outputs.Rod1.p.out')
  CALL write_prescribed_rod_motion_file('deck_rod_motion.txt')
  CALL write_dynamic_prescribed_rod_deck('deck_rod_motion.dat', 'deck_rod_motion.txt')
  CALL CD_Run_Deck_Driver('deck_rod_motion.dat', 'deck_rod_motion', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic prescribed ROD deck converged: '//TRIM(em))
  CALL check_dynamic_prescribed_rod_position_output_file('deck_rod_motion.Rod1.p.out')
  CALL write_dynamic_bad_coupled_rod_deck('deck_bad_coupled_rod.dat')
  CALL CD_Run_Deck_Driver('deck_bad_coupled_rod.dat', 'deck_bad_coupled_rod', conv, es, em)
  CALL require(es == CD_DECKDRV_BADINPUT, 'Coupled ROD without motionFile fails closed')
  CALL write_mixed_rod_motion_file('deck_mixed_rod_motion.txt')
  CALL write_dynamic_mixed_rod_motion_deck('deck_mixed_rod_motion.dat', 'deck_mixed_rod_motion.txt')
  CALL CD_Run_Deck_Driver('deck_mixed_rod_motion.dat', 'deck_mixed_rod_motion', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'mixed prescribed/free ROD motion deck converged: '//TRIM(em))
  CALL check_dynamic_prescribed_rod_position_output_file('deck_mixed_rod_motion.Rod1.p.out')
  CALL check_dynamic_rod_position_output_file('deck_mixed_rod_motion.Rod2.p.out')
  CALL write_dynamic_rod_deck('deck_rod_bathy.dat', 'deck_bathy.xyz')
  CALL CD_Run_Deck_Driver('deck_rod_bathy.dat', 'deck_rod_bathy', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic ROD bathymetry deck converged: '//TRIM(em))
  CALL check_dynamic_rod_out('deck_rod_bathy.out')
  ! Active-contact pair: the same rod over a deep and a 1 m seabed, with anchor 1 resting
  ! on the 1 m bed in both (an anchor below the seabed is an input error).
  CALL write_dynamic_rod_deck('deck_rod_deep.dat', 'deck_bathy.xyz', anchor1_z=-1.0_wp)
  CALL CD_Run_Deck_Driver('deck_rod_deep.dat', 'deck_rod_deep', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic ROD deep-contact deck converged: '//TRIM(em))
  CALL write_bathymetry_file('deck_rod_contact.xyz', 1.0_wp)
  CALL write_dynamic_rod_deck('deck_rod_contact.dat', 'deck_rod_contact.xyz', anchor1_z=-1.0_wp)
  CALL CD_Run_Deck_Driver('deck_rod_contact.dat', 'deck_rod_contact', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic ROD active-bathymetry contact deck converged: '//TRIM(em))
  CALL read_dynamic_rod_z('deck_rod_deep.out', rod_deep_za, rod_deep_zb, es)
  CALL require(es == 0, 'read dynamic ROD deep-contact z')
  CALL read_dynamic_rod_z('deck_rod_contact.out', rod_contact_za, rod_contact_zb, es)
  CALL require(es == 0, 'read dynamic ROD active-contact z')
  CALL require(rod_contact_za > rod_deep_za + 1.0e-4_wp, 'ROD bathymetry contact lifts penetrated End A')
  CALL require(ABS(rod_contact_za) < 100.0_wp .AND. ABS(rod_contact_zb) < 100.0_wp, &
               'ROD active-contact output remains bounded')
  CALL check_light_rod_carried_inertia()
  CALL write_dynamic_fixed_rod_deck('deck_fixed_rod.dat')
  CALL CD_Run_Deck_Driver('deck_fixed_rod.dat', 'deck_fixed_rod', conv, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. conv, 'dynamic fixed ROD deck converged: '//TRIM(em))
  CALL check_dynamic_fixed_rod_out('deck_fixed_rod.out')

  ! --- (2g) the same supported deck initializes persistent lifecycle models ---
  IF (.NOT. ALLOCATED(models)) ALLOCATE (models(0))
  CALL CD_Init_Deck_Models('deck_single.dat', models, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. ALLOCATED(models), 'deck initializes persistent models: '//TRIM(em))
  IF (es == CD_DECKDRV_OK .AND. ALLOCATED(models)) THEN
    CALL require(SIZE(models) == 1, 'deck initializes one persistent model')
    CALL check_model_from_deck(models(1))
    CALL end_test_models(models)
  END IF
  CALL CD_Init_Deck_System('deck_single.dat', deck_system, dt_sys, g_sys, rho_sys, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. CD_System_Is_Initialized(deck_system), &
               'deck initializes persistent system: '//TRIM(em))
  n_sys = CD_System_NLines(deck_system, es, em)
  CALL require(es == CD_SYSTEM_OK .AND. n_sys == 1, 'deck-system nlines')
  CALL write_text_file('deck_system_bad_ei.dat', deck_with_finite_ei())
  CALL CD_Init_Deck_System('deck_system_bad_ei.dat', deck_system, dt_sys, g_sys, rho_sys, es, em)
  CALL require(es == CD_DECKDRV_BADINPUT .AND. CD_System_Is_Initialized(deck_system), &
               'bad deck reinit preserves persistent system')
  n_sys = CD_System_NCoupledDOF(deck_system, es, em)
  CALL require(es == CD_SYSTEM_OK .AND. n_sys == 6, 'bad deck reinit preserves coupled dof count')
  CALL CD_End_System(deck_system, es, em)
  CALL require(es == CD_SYSTEM_OK, 'deck-system end')

  ! --- coupled-host (caller-driven) deck contract: a stock coupled deck declares dtM
  ! without TMax because the host owns simulation length. The standalone entry keeps
  ! the dtM/TMax pairing; caller_driven relaxes it and returns the deck dtM. ---
  CALL write_stock_deck('deck_stock_dtm.dat', with_dtm=.TRUE., with_seabed=.TRUE., wavekin_val=0)
  CALL CD_Init_Deck_System('deck_stock_dtm.dat', deck_system, dt_sys, g_sys, rho_sys, es, em)
  CALL require(es == CD_DECKDRV_BADINPUT, 'standalone entry keeps the dtM/TMax pairing: '//TRIM(em))
  CALL CD_Init_Deck_System('deck_stock_dtm.dat', deck_system, dt_sys, g_sys, rho_sys, es, em, &
                           caller_driven=.TRUE.)
  CALL require(es == CD_DECKDRV_OK .AND. CD_System_Is_Initialized(deck_system), &
               'caller-driven entry accepts a dtM-only stock deck: '//TRIM(em))
  CALL require(ABS(dt_sys - 0.001_wp) < 1.0e-15_wp, 'caller-driven entry returns the deck dtM')
  CALL CD_End_System(deck_system, es, em)
  CALL require(es == CD_SYSTEM_OK, 'caller-driven deck-system end')

  ! --- caller-supplied environment: the host's gravity/density override the deck's,
  ! and the host's water depth grounds a slack line whose deck declares no seabed
  ! (stock coupled decks get depth from the host, not the deck). Without the host
  ! depth nothing supports the grounded-class chain: it solves as the fully suspended
  ! catenary (the documented no-seabed contract), sagging below its 50 m anchor. ---
  CALL write_stock_deck('deck_stock_nosb.dat', with_dtm=.FALSE., with_seabed=.FALSE., wavekin_val=0)
  CALL CD_Init_Deck_System('deck_stock_nosb.dat', deck_system, dt_sys, g_sys, rho_sys, es, em, &
                           caller_driven=.TRUE.)
  CALL require(es == CD_DECKDRV_OK, 'grounded-class stock deck without host depth solves suspended: '//TRIM(em))
  IF (es == CD_DECKDRV_OK) THEN
    BLOCK
      REAL(wp), ALLOCATABLE :: qs(:), vs(:), as(:)
      INTEGER :: nds
      nds = CD_System_Line_NDOF(deck_system, 1, es, em)
      ALLOCATE (qs(nds), vs(nds), as(nds))
      CALL CD_Get_System_Line_State(deck_system, 1, qs, vs, as, es, em)
      CALL require(es == CD_SYSTEM_OK .AND. MINVAL(qs(3:nds:3)) < -50.0_wp - 1.0e-3_wp, &
                   'suspended chain without a seabed sags below its anchor')
    END BLOCK
    CALL CD_End_System(deck_system, es, em)
  END IF
  CALL CD_Init_Deck_System('deck_stock_nosb.dat', deck_system, dt_sys, g_sys, rho_sys, es, em, &
                           caller_driven=.TRUE., env_gravity=9.81_wp, env_rho_water=1000.0_wp, &
                           env_wtrdpth=50.0_wp)
  CALL require(es == CD_DECKDRV_OK, 'caller environment injects depth + g + rho: '//TRIM(em))
  CALL require(ABS(g_sys - 9.81_wp) < 1.0e-12_wp .AND. ABS(rho_sys - 1000.0_wp) < 1.0e-12_wp, &
               'host g/rho override the deck values')
  stock_ndof = CD_System_Line_NDOF(deck_system, 1, es, em)
  CALL require(es == CD_SYSTEM_OK .AND. stock_ndof > 0, 'env-injected line ndof')
  ALLOCATE (stock_q(stock_ndof), stock_v(stock_ndof), stock_a(stock_ndof))
  CALL CD_Get_System_Line_State(deck_system, 1, stock_q, stock_v, stock_a, es, em)
  CALL require(es == CD_SYSTEM_OK, 'env-injected line state')
  stock_minz_env = MINVAL(stock_q(3:stock_ndof:3))
  DEALLOCATE (stock_q, stock_v, stock_a)
  CALL CD_End_System(deck_system, es, em)
  CALL require(es == CD_SYSTEM_OK, 'env-injected deck-system end')
  CALL require(stock_minz_env > -50.2_wp, 'host depth grounds the line at the injected seabed')

  ! --- (2h) a bathymetryFile deck honors bathymetry on the lifecycle init path too, not only
  ! the standalone CD_Run_Deck_Driver. deck_bathy.dat / .xyz were written earlier in this run.
  IF (.NOT. ALLOCATED(models)) ALLOCATE (models(0))
  CALL CD_Init_Deck_Models('deck_bathy.dat', models, es, em)
  CALL require(es == CD_DECKDRV_OK .AND. ALLOCATED(models), 'bathymetry deck initializes models: '//TRIM(em))
  IF (es == CD_DECKDRV_OK .AND. ALLOCATED(models)) THEN
    CALL require(SIZE(models) == 1, 'bathymetry deck initializes one model')
    CALL require(models(1)%has_bathymetry, 'CD_Init_Deck_Models loads + threads bathymetryFile (not flat seabed)')
    CALL end_test_models(models)
  END IF

  ! --- (3) fail-closed on unsupported features / invalid decks ---
  CALL expect_badinput('deck_negei.dat', deck_with_negative_ei(), 'negative EI')
  CALL expect_badinput('deck_duptype.dat', deck_with_duplicate_type(), 'duplicate LINE TYPE name')
  CALL expect_badinput('deck_badchan.dat', deck_with_bad_point_channel(), 'malformed Point channel')
  CALL expect_badinput('deck_ptload.dat', deck_with_held_point_load(), 'load columns on a held point')
  CALL expect_badinput('deck_buoy.dat', deck_with_buoyant_section(), 'net-buoyant section')
  CALL expect_badinput('deck_zeroid.dat', deck_with_zero_point_id(), 'non-positive POINT id')
  CALL expect_badinput('deck_badflag.dat', deck_with_bad_output_flag(), 'unsupported LINE Outputs flag')
  CALL expect_badinput('deck_baddynsolver.dat', deck_with_bad_dynamic_solver(), 'invalid dynamic_solver')
  CALL expect_badinput('deck_badmodnewton.dat', deck_with_bad_modified_newton(), 'invalid modified_newton')
  CALL expect_badinput('deck_badtensile.dat', deck_with_bad_tensile_mode(), 'invalid tensile_safety')
  CALL expect_badinput('deck_badtentol.dat', deck_with_bad_tensile_tolerance(), 'negative tensile tolerance')
  CALL expect_badinput('deck_badrecovery.dat', deck_with_bad_recovery_cap(), 'non-finite recovery cap')
  CALL expect_badinput('deck_fracrecovery.dat', deck_with_fractional_recovery_cap(), 'fractional recovery cap')
  ! the ei0 sub-stepping options take the Python deck reader's rules: ei0_substep_max is an integer
  ! to within 16 ulp whose nearest integer lies in [2, 1024]
  CALL expect_badinput('deck_ei0mode.dat', deck_with_ei0_option('on ei0_substeps'), 'invalid ei0_substeps')
  CALL expect_badinput('deck_ei0angle.dat', deck_with_ei0_option('0 ei0_substep_angle'), 'zero ei0_substep_angle')
  CALL expect_badinput('deck_ei0max.dat', deck_with_ei0_option('1025 ei0_substep_max'), 'ei0_substep_max above 1024')
  CALL expect_badinput('deck_ei0maxfr.dat', deck_with_ei0_option('2.5 ei0_substep_max'), 'fractional ei0_substep_max')
  CALL expect_badinput('deck_ei0maxbig.dat', deck_with_ei0_option('2048.5 ei0_substep_max'), 'large ei0_substep_max')
  CALL expect_badinput('deck_body.dat', deck_with_bodies(), 'Rigid6 BODY')
  CALL expect_badinput('deck_ei.dat', deck_with_finite_ei(), 'finite-EI section')
  CALL expect_badinput('deck_badgj.dat', deck_with_bad_native_finite_ei(), 'explicit finite-EI')
  CALL expect_badinput('deck_equiv_unknown.dat', deck_with_unknown_equivalent_buoyancy(), 'unknown LineType')
  CALL expect_badinput('deck_equiv_bad.dat', deck_with_bad_equivalent_buoyancy(), 'negative dry mass')
  CALL expect_badinput('deck_finite_connect.dat', deck_with_finite_ei_connect(), 'finite-EI dynamic')
  CALL expect_badinput('deck_endconn_two_moving.dat', deck_with_two_moving_end_connection(), &
                       'END CONNECTIONS with End B on a Free point', 'need End B on a Fixed, Coupled or Vessel point')
  CALL expect_badinput('deck_finite_body_mix.dat', deck_with_finite_ei_body_mix(), 'finite-EI dynamic deck')
  CALL expect_badinput('deck_finite_rod_mix.dat', deck_with_finite_ei_rod_mix(), 'finite-EI dynamic deck')
  CALL expect_badinput('deck_rigid6_connect.dat', deck_with_rigid6_connect(), 'Rigid6 dynamic deck')
  CALL expect_badinput('deck_connect.dat', deck_with_connect(), 'Connect point')
  CALL expect_badinput('deck_badkw.dat', deck_with_bad_keyword(), 'unknown OPTION keyword')
  CALL expect_badinput('deck_nanpt.dat', deck_with_nonfinite_point(), 'non-finite POINT position')
  CALL expect_badinput('deck_inftype.dat', deck_with_nonfinite_type(), 'non-finite LINE TYPE property')
  CALL expect_badinput('deck_zeroea.dat', deck_with_zero_ea(), 'non-positive EA')
  CALL write_text_file('deck_heterohydro.dat', deck_with_heterogeneous_hydro())
  CALL CD_Init_Deck_Models('deck_heterohydro.dat', models, es, em)
  CALL require(es == CD_DECKDRV_OK, 'heterogeneous hydro model init: '//TRIM(em))
  IF (es == CD_DECKDRV_OK) THEN
    CALL require(SIZE(models) == 1 .AND. CD_Model_Is_Initialized(models(1)), 'heterogeneous hydro initialized')
    CALL require(CD_Model_NDOF(models(1), es, em) == 126, 'heterogeneous hydro ndof')
    CALL CD_End_Model(models(1), es, em)
    DEALLOCATE (models)
  END IF

  ! --- (4) row parsing never reads a value partially, truncates a record, or wraps an id ---
  CALL check_parser_hardening()

  ! --- (5) a valid deck whose static equilibrium is numerically rejected is a solve failure ---
  CALL check_rejected_static_branch_status()

  ! --- (6) hang-off endpoint order, suspended seeds, and fine-mesh static convergence ---
  CALL check_hangoff_and_fine_mesh()

  ! --- (7) line FAILURE on a free Rigid6 body (the staggered body march) ---
  CALL check_rigid6_failure()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: cabledyn legacy-style deck driver (static + dynamic scored cases)'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', TRIM(label)
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE check_dynamic_completion_policy()
    !! Regression gate for the public dynamic completion contract: every nonlinear
    !! convergence miss is a solve failure, even when a finite output file exists.
    LOGICAL :: conv_l
    INTEGER :: es_l
    CHARACTER(256) :: em_l
    CHARACTER(8) :: em_short

    CALL CD_Classify_Dynamic_Completion('policy gate', 1200, 0, 0, 0.0_wp, 0.0_wp, conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l .AND. LEN_TRIM(em_l) == 0, &
                 'dynamic completion: zero misses converges cleanly')

    CALL CD_Classify_Dynamic_Completion('policy gate', 40, 1, 1, 0.1_wp, 0.1_wp, conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_SOLVEFAIL .AND. .NOT. conv_l, &
                 'dynamic completion: short run gets no free one-miss allowance')

    CALL CD_Classify_Dynamic_Completion('policy gate', 100, 1, 1, 0.1_wp, 0.1_wp, conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_SOLVEFAIL .AND. .NOT. conv_l .AND. &
                 INDEX(em_l, 'inspection only') > 0, &
                 'dynamic completion: one miss is a hard solve failure')

    CALL CD_Classify_Dynamic_Completion('policy gate', HUGE(0), HUGE(0), 1, 0.1_wp, 0.1_wp, conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_SOLVEFAIL .AND. .NOT. conv_l, &
                 'dynamic completion: oversized miss counts do not overflow into warning')

    CALL CD_Classify_Dynamic_Completion('policy gate', 100, 1, 1, 0.1_wp, 0.1_wp, conv_l, es_l, em_short)
    CALL require(es_l == CD_DECKDRV_SOLVEFAIL .AND. .NOT. conv_l .AND. LEN(em_short) == 8, &
                 'dynamic completion: short ErrMsg buffer is truncation-safe')
  END SUBROUTINE check_dynamic_completion_policy

  SUBROUTINE expect_badinput(path, body, what, message_fragment)
    !! Write `body` (newline-separated records in one string) to `path`, run the driver,
    !! and require a BADINPUT (fail-closed) result.
    CHARACTER(*), INTENT(IN) :: path, body, what
    CHARACTER(*), INTENT(IN), OPTIONAL :: message_fragment
    INTEGER :: u, ios, es_l, i0, i
    LOGICAL :: conv_l
    CHARACTER(256) :: em_l
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    i0 = 1
    DO i = 1, LEN_TRIM(body)
      IF (body(i:i) == NEW_LINE('a')) THEN
        WRITE (u, '(A)') body(i0:i - 1)
        i0 = i + 1
      END IF
    END DO
    IF (i0 <= LEN_TRIM(body)) WRITE (u, '(A)') body(i0:LEN_TRIM(body))
    CLOSE (u)
    ! a rejected deck may carry non-finite or overflowing values: must not halt a trapping build
    CALL IEEE_GET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, .FALSE.)
    CALL CD_Run_Deck_Driver(path, TRIM(path)//'.tmp', conv_l, es_l, em_l)
    CALL IEEE_SET_FLAG(IEEE_USUAL, .FALSE.)
    CALL IEEE_SET_HALTING_MODE(IEEE_USUAL, fp_halt)
    CALL require(es_l == CD_DECKDRV_BADINPUT, 'fail-closed on '//TRIM(what)//': '//TRIM(em_l))
    IF (PRESENT(message_fragment)) THEN
      CALL require(INDEX(em_l, TRIM(message_fragment)) > 0, &
                   'specific diagnostic for '//TRIM(what)//': '//TRIM(em_l))
    END IF
  END SUBROUTINE expect_badinput

  FUNCTION hardening_deck(point1, section1, extra_option, outputs, extra_point, flat_seabed) RESULT(body)
    !! The WD0050 single-section chain as an in-memory deck body with one replaceable
    !! anchor POINTS row (deck line 9), SECTIONS row (deck line 18), an optional
    !! extra OPTIONS row, the OUTPUTS row, and an optional second-to-last POINTS row.
    !! flat_seabed = .FALSE. omits the WtrDpth row (for a bathymetryFile option).
    CHARACTER(*), INTENT(IN) :: point1, section1, extra_option, outputs
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra_point
    LOGICAL, INTENT(IN), OPTIONAL :: flat_seabed
    CHARACTER(:), ALLOCATABLE :: body
    CHARACTER(1) :: nl
    nl = NEW_LINE('a')
    body = 'WD0050 parser-hardening deck'//nl//'--- LINE TYPES ---'//nl// &
           'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//nl// &
           '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//nl// &
           'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//nl// &
           '--- POINTS ---'//nl//'ID Type X Y Z'//nl//'(-) (-) (m) (m) (m)'//nl// &
           point1//nl//'2 Coupled 0.0 0.0 0.0'//nl
    IF (PRESENT(extra_point)) body = body//extra_point//nl
    body = body//'--- LINES ---'//nl//'ID NodeA NodeB Outputs'//nl//'(-) (-) (-) (-)'//nl// &
           '1 2 1 -'//nl//'--- SECTIONS ---'//nl//'LineID LineType Length NumSegs'//nl// &
           '(-) (-) (m) (-)'//nl//section1//nl//'--- OPTIONS ---'//nl//'9.80665 g'//nl// &
           '1025.0 rhoW'//nl
    IF (PRESENT(flat_seabed)) THEN
      IF (flat_seabed) body = body//'50.0 WtrDpth'//nl
    ELSE
      body = body//'50.0 WtrDpth'//nl
    END IF
    body = body//'1.0e5 kBot'//nl
    IF (LEN_TRIM(extra_option) > 0) body = body//extra_option//nl
    body = body//'--- OUTPUTS ---'//nl//outputs//nl//'--- need this line ---'
  END FUNCTION hardening_deck

  SUBROUTINE check_parser_hardening()
    !! List-directed READ treats an unquoted '/' as end of input (later items keep stale
    !! values), ',' as a separator and "n*" as a repeat count, and a '(A)' read into a
    !! fixed buffer truncates silently. Each malformed case below must fail closed
    !! naming the offending line rather than build a wrong model with a clean status,
    !! while the documented quoted / comma-list / long-comment forms keep working.
    CHARACTER(*), PARAMETER :: ANCHOR = '1 Fixed 400.0 0.0 -50.0', SECTION = '1 chain 410.0 41'
    CHARACTER(:), ALLOCATABLE :: long_row
    CHARACTER(512) :: em_l
    CHARACTER(1024) :: buf
    INTEGER :: es_l, u, ios, ntok_l, i
    LOGICAL :: conv_l
    REAL(wp) :: fair_l, anch_l, row_t, con_x, point_x

    CALL expect_badinput('deck_hard_slash_point.dat', hardening_deck('1 Fixed 500/2 0.0 -50.0', SECTION, '', &
                                                                     'FairTen1'), &
                         'slash inside a POINTS coordinate', 'deck line 9: column 3 value "500/2"')
    CALL expect_badinput('deck_hard_comma_point.dat', hardening_deck('1 Fixed 400,0 0.0 -50.0', SECTION, '', &
                                                                     'FairTen1'), &
                         'decimal comma in a POINTS coordinate', '"400,0"')
    CALL expect_badinput('deck_hard_repeat_point.dat', hardening_deck('1 Fixed 2*200.0 0.0 -50.0', SECTION, &
                                                                      '', 'FairTen1'), &
                         'repeat count in a POINTS row', '"2*200.0"')
    ! a sign inside the mantissa reads list-directed as an exponent ("500+2" = 500e2)
    CALL expect_badinput('deck_hard_signexp_point.dat', hardening_deck('1 Fixed 500+2 0.0 -50.0', SECTION, '', &
                                                                       'FairTen1'), &
                         'sign-exponent typo in a POINTS coordinate', 'value "500+2" is not a plain number')
    CALL expect_badinput('deck_hard_signexp_option.dat', hardening_deck(ANCHOR, SECTION, '10-5 cBot', 'FairTen1'), &
                         'sign-exponent typo in an OPTION value', 'malformed numeric OPTION value "10-5"')
    ! the in-process channel gate parses a TDP token's suffix like every other family
    BLOCK
      LOGICAL :: tok_ok(4)
      tok_ok = [CD_Channel_Token_Parses('TDP1s'), CD_Channel_Token_Parses('TDP01Lay'), &
                CD_Channel_Token_Parses('TDP1q'), CD_Channel_Token_Parses('TDP1')]
      CALL require(tok_ok(1) .AND. tok_ok(2), 'channel gate admits well-formed TDP tokens')
      CALL require(.NOT. tok_ok(3) .AND. .NOT. tok_ok(4), 'channel gate rejects a malformed TDP suffix')
    END BLOCK
    ! ... and the anchor uplift channels: AnchFz<L>, AnchFH<L>, TDP<L>Grd
    BLOCK
      LOGICAL :: tok_ok(7)
      tok_ok = [CD_Channel_Token_Parses('AnchFz1'), CD_Channel_Token_Parses('ANCHFH012'), &
                CD_Channel_Token_Parses('TDP3Grd'), CD_Channel_Token_Parses('AnchFz'), &
                CD_Channel_Token_Parses('AnchFz0'), CD_Channel_Token_Parses('AnchFz1x'), &
                CD_Channel_Token_Parses('TDP1Grdx')]
      CALL require(ALL(tok_ok(1:3)), 'channel gate admits AnchFz, AnchFH and TDP<L>Grd tokens')
      CALL require(.NOT. ANY(tok_ok(4:7)), 'channel gate rejects malformed anchor uplift tokens')
    END BLOCK
    ! the synthesised sea is bounded in total components, not only per factor
    BLOCK
      CHARACTER(1) :: nl
      nl = NEW_LINE('a')
      CALL expect_badinput('deck_hard_wave_count.dat', hardening_deck(ANCHOR, SECTION, &
                                                                      '1000 WaveComponents'//nl// &
                                                                      '101 WaveDirections', 'FairTen1'), &
                           'too many spread-sea components', 'WaveComponents x WaveDirections')
    END BLOCK
    ! MoorDyn numbers line nodes from N0; CableDyn from 1 = End A: named, not "bad syntax"
    CALL expect_badinput('deck_hard_node0.dat', hardening_deck(ANCHOR, SECTION, '', 'Ten1N0'), &
                         'node 0 channel', 'node numbers start at 1')
    ! every documented logical spelling and tensile_safety mode parses; anything else is named
    BLOCK
      CHARACTER(8), PARAMETER :: SPELL(12) = [CHARACTER(8) :: 'True', 'T', 'yes', 'y', 'on', '1', &
                                                                                    'False', 'F', 'no', 'n', 'off', '0']
      CHARACTER(8), PARAMETER :: TMODE(6) = [CHARACTER(8) :: 'error', 'monitor', 'warning', 'warn', 'True', &
                                                                                                    'False']
      CHARACTER(32), PARAMETER :: ALIAS(4) = [CHARACTER(32) :: '0.0 frictionCoefficient', &
                                                                        '8 recoverymaxsubsteps', 'False adaptivemesh', &
                                                                                          '0.01 tensilestraintolerance']
      REAL(wp) :: pz(3, 0), tz(0), ez(0), vz(3, 0), az(3, 0)
      INTEGER :: k
      DO k = 1, SIZE(SPELL)
        CALL write_text_file('deck_hard_logical.dat', hardening_deck(ANCHOR, SECTION, &
                                                                     TRIM(SPELL(k))//' modified_newton', 'FairTen1'))
        CALL CD_Deck_Fluid_Probe('deck_hard_logical.dat', pz, tz, ez, vz, az, es_l, em_l)
        CALL require(es_l == CD_DECKDRV_OK, 'logical OPTION spelling "'//TRIM(SPELL(k))//'" parses: '//TRIM(em_l))
      END DO
      DO k = 1, SIZE(TMODE)
        CALL write_text_file('deck_hard_tensile.dat', hardening_deck(ANCHOR, SECTION, &
                                                                     TRIM(TMODE(k))//' tensile_safety', 'FairTen1'))
        CALL CD_Deck_Fluid_Probe('deck_hard_tensile.dat', pz, tz, ez, vz, az, es_l, em_l)
        CALL require(es_l == CD_DECKDRV_OK, 'tensile_safety mode "'//TRIM(TMODE(k))//'" parses: '//TRIM(em_l))
      END DO
      ! documented OPTION aliases parse like their primary keywords
      DO k = 1, 4
        CALL write_text_file('deck_hard_alias.dat', hardening_deck(ANCHOR, SECTION, &
                                                                   TRIM(ALIAS(k)), 'FairTen1'))
        CALL CD_Deck_Fluid_Probe('deck_hard_alias.dat', pz, tz, ez, vz, az, es_l, em_l)
        CALL require(es_l == CD_DECKDRV_OK, 'OPTION alias row "'//TRIM(ALIAS(k))//'" parses: '//TRIM(em_l))
      END DO
    END BLOCK
    CALL expect_badinput('deck_hard_logical_bad.dat', hardening_deck(ANCHOR, SECTION, 'maybe modified_newton', &
                                                                     'FairTen1'), &
                         'malformed logical OPTION', 'malformed logical OPTION value "maybe"')
    CALL expect_badinput('deck_hard_tensile_bad.dat', hardening_deck(ANCHOR, SECTION, 'strict tensile_safety', &
                                                                     'FairTen1'), &
                         'malformed tensile_safety mode', 'malformed tensile_safety value "strict"')
    ! a positional waves row with undashed commentary is named, not "unknown keyword 2"
    CALL expect_badinput('deck_hard_wave_comment.dat', hardening_deck(ANCHOR, SECTION, 'airy 2 8 0 waves regular', &
                                                                      'FairTen1'), &
                         'positional waves row with trailing text', 'is a positional')
    ! MoorDyn seabed-friction keywords are named with their CableDyn equivalents
    CALL expect_badinput('deck_hard_mukt.dat', hardening_deck(ANCHOR, SECTION, '0.5 mu_kT', 'FairTen1'), &
                         'MoorDyn-F mu_kT', 'frictionMuLateral for mu_kT')
    CALL expect_badinput('deck_hard_fricdamp.dat', hardening_deck(ANCHOR, SECTION, '0.1 FricDamp', 'FairTen1'), &
                         'MoorDyn-C FricDamp', 'has no CableDyn equivalent')
    CALL expect_badinput('deck_hard_slash_nsegs.dat', hardening_deck(ANCHOR, '1 chain 410.0 45/2', '', &
                                                                     'FairTen1'), &
                         'slash inside SECTIONS NumSegs', 'deck line 18')
    ! the retired ICmode row fails closed with the delete-the-row diagnostic, whatever its value
    CALL expect_badinput('deck_hard_icmode_static.dat', hardening_deck(ANCHOR, SECTION, 'static ICmode', &
                                                                       'FairTen1'), &
                         'retired ICmode row', 'always solves the static equilibrium directly')
    CALL expect_badinput('deck_hard_icmode_dynamic.dat', hardening_deck(ANCHOR, SECTION, 'dynamic ICmode', &
                                                                        'FairTen1'), &
                         'retired ICmode row (dynamic)', 'delete the ICmode row')
    CALL expect_badinput('deck_hard_slash_dtm.dat', hardening_deck(ANCHOR, SECTION, '1/20 dtM'//NEW_LINE('a')// &
                                                                   '1.0 TMax', 'FairTen1'), &
                         'slash inside the dtM value', 'malformed numeric OPTION value "1/20"')
    CALL expect_badinput('deck_hard_comma_wave.dat', hardening_deck(ANCHOR, SECTION, '0.05 dtM'//NEW_LINE('a')// &
                                                                    '0.1 TMax'//NEW_LINE('a')// &
                                                                    'airy 2,5 8.0 0.0 waves', 'FairTen1'), &
                         'decimal comma inside a positional waves row', '"2,5"')
    CALL expect_badinput('deck_hard_huge_steps.dat', hardening_deck(ANCHOR, SECTION, '1.0e-12 dtM'// &
                                                                    NEW_LINE('a')//'1.0e6 TMax', 'FairTen1'), &
                         'TMax/dtM step count beyond INTEGER', 'time steps')
    CALL expect_badinput('deck_hard_wrap_channel.dat', hardening_deck(ANCHOR, SECTION, '', &
                                                                      'AnchTen4294967297'), &
                         'channel id that wraps to line 1', 'unknown line id')
    CALL expect_badinput('deck_hard_dup_point.dat', hardening_deck(ANCHOR, SECTION, '', 'FairTen1', &
                                                                   extra_point='2 Coupled 0.0 5.0 0.0'), &
                         'duplicate POINT id', 'duplicate POINT id 2')
    CALL expect_badinput('deck_hard_unknown_section.dat', hardening_deck(ANCHOR, SECTION, '', 'FairTen1')// &
                         NEW_LINE('a')//'--- SPRINGS ---', 'unknown section', 'deck line 27')

    ! A data row longer than the record buffer fails closed instead of losing its tail
    ! (here the second channel); the same length is harmless inside a # comment.
    long_row = 'FairTen1'//REPEAT(' ', 520)//'AnchTen1'
    CALL expect_badinput('deck_hard_long_outputs.dat', hardening_deck(ANCHOR, SECTION, '', long_row), &
                         'over-long OUTPUTS record', 'deck line 25 is longer than 512 characters')
    CALL write_text_file('deck_hard_long_comment.dat', hardening_deck(ANCHOR, SECTION, &
                                                                      '# '//REPEAT('x', 700), &
                                                                      'FairTen1,AnchTen1   # '//REPEAT('y', 600)))
    CALL CD_Run_Deck_Driver('deck_hard_long_comment.dat', 'deck_hard_long_comment', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'long # comments and a comma channel list parse: '// &
                 TRIM(em_l))
    CALL read_out('deck_hard_long_comment.out', fair_l, anch_l, es_l)
    CALL require(es_l == 0 .AND. ABS(fair_l - ORCA_FAIR)/ORCA_FAIR < RTOL .AND. &
                 ABS(anch_l - ORCA_ANCH)/ORCA_ANCH < RTOL, 'comma-separated OUTPUTS keep both channels')

    ! Con<P>p{x,y,z} is the MoorDyn v1 spelling of Point<P>p{x,y,z}: same value, and the
    ! header keeps the channel token as written.
    CALL write_text_file('deck_hard_con.dat', hardening_deck(ANCHOR, SECTION, '', 'FairTen1 Con1px Point1py'))
    CALL CD_Run_Deck_Driver('deck_hard_con.dat', 'deck_hard_con', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'Con<P>p channel alias parses: '//TRIM(em_l))
    OPEN (NEWUNIT=u, FILE='deck_hard_con.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open deck_hard_con.out')
    IF (ios == 0) THEN
      READ (u, '(A)', IOSTAT=ios) buf
      READ (u, '(A)', IOSTAT=ios) buf
      CALL require(INDEX(buf, 'Con1px') > 0, 'Con<P>p channel keeps its header token')
      READ (u, '(A)', IOSTAT=ios) buf
      CLOSE (u)
      IF (ios == 0) READ (buf, *, IOSTAT=ios) row_t, fair_l, con_x, point_x
      CALL require(ios == 0 .AND. ABS(con_x - 400.0_wp) < 1.0e-9_wp .AND. &
                   ABS(point_x) < 1.0e-9_wp, 'Con1px reads the anchor x = 400 m (Point1py = 0)')
    END IF

    ! Every OUTPUTS channel is one .out column: a channel requested twice -- the same name
    ! (case-insensitively, across rows or within a comma list) or an alias spelling of the
    ! same quantity (Con<P> = Point<P>, FairAngle<L> = FairDecl<L>) -- fails at parse time
    ! with the channel, the earlier spelling, and the deck line; nothing is solved.
    BLOCK
      CHARACTER(64), PARAMETER :: DUP_ROWS(5) = [CHARACTER(64) :: &
                                                 'FairTen1,AnchTen1'//NEW_LINE('a')//'AnchTen1', &
                                                 'FairTen1 fairten1', 'FairTen1 Con1px Point1px', &
                                                 'FairTen1 FairAngle1 FairDecl1', 'FairTen1 Ten1N2 TEN1N02']
      CHARACTER(16), PARAMETER :: DUP_NAMES(5) = [CHARACTER(16) :: &
                                                  '"AnchTen1"', '"fairten1"', '"Point1px"', &
                                                  '"FairDecl1"', '"TEN1N02"']
      INTEGER :: k
      DO k = 1, SIZE(DUP_ROWS)
        CALL write_text_file('deck_hard_dup.dat', hardening_deck(ANCHOR, SECTION, '', TRIM(DUP_ROWS(k))))
        CALL CD_Run_Deck_Driver('deck_hard_dup.dat', 'deck_hard_dup', conv_l, es_l, em_l)
        CALL require(es_l == CD_DECKDRV_BADINPUT .AND. .NOT. conv_l .AND. &
                     INDEX(em_l, 'OUTPUTS channel '//TRIM(DUP_NAMES(k))//' duplicates the earlier channel') > 0 &
                     .AND. INDEX(em_l, 'deck line ') > 0, &
                     'duplicate OUTPUTS channel rejected with its deck line: '//TRIM(em_l))
      END DO
    END BLOCK

    ! A Fixed point (anchor) below the seabed is an input error named at parse time, not a
    ! late "line did not converge": flat WtrDpth and bathymetry alike. An anchor exactly on
    ! the seabed (round-off tolerance 1e-6*max(1 m, depth)) stays valid.
    CALL expect_badinput('deck_hard_anchor_below.dat', hardening_deck('1 Fixed 400.0 0.0 -50.01', SECTION, '', &
                                                                      'FairTen1'), &
                         'anchor below the flat seabed', 'POINT 1 (Fixed) lies below the seabed')
    CALL write_text_file('deck_hard_anchor_on.dat', hardening_deck('1 Fixed 400.0 0.0 -50.00001', SECTION, '', &
                                                                   'FairTen1'))
    CALL CD_Run_Deck_Driver('deck_hard_anchor_on.dat', 'deck_hard_anchor_on', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'anchor on the seabed within round-off solves: '//TRIM(em_l))
    CALL write_bathymetry_file('deck_hard_anchor_bathy.xyz', 50.0_wp)
    CALL expect_badinput('deck_hard_anchor_bathy.dat', hardening_deck('1 Fixed 400.0 0.0 -51.0', SECTION, &
                                                                      'deck_hard_anchor_bathy.xyz bathymetryFile', &
                                                                      'FairTen1', flat_seabed=.FALSE.), &
                         'anchor below the bathymetry seabed', 'under the bathymetry seabed')

    ! The output time column carries 17 significant digits (a round-trip double).
    OPEN (NEWUNIT=u, FILE='deck_dynamic.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open deck_dynamic.out for the time-column check')
    IF (ios == 0) THEN
      DO i = 1, 4
        READ (u, '(A)', IOSTAT=ios) buf
      END DO
      CLOSE (u)
      buf = ADJUSTL(buf)
      ntok_l = INDEX(buf, CHAR(9)) - 1
      CALL require(ios == 0 .AND. ntok_l >= 23, 'time column is written at full double precision: '// &
                   TRIM(buf(1:MAX(ntok_l, 1))))
    END IF

    ! motionFile rows are parsed column by column: "0.01/2" is malformed, never 0.01.
    CALL write_dynamic_motion_deck('deck_hard_motion.dat', 'deck_hard_motion.txt')
    OPEN (NEWUNIT=u, FILE='deck_hard_motion.txt', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '0.00 2 0.0 0.0 0.000 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.01 2 0.0 0.0 0.005/2 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.02 2 0.0 0.0 0.010 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.03 2 0.0 0.0 0.015 0.0 0.0 0.5 0.0 0.0 0.0'
    CLOSE (u)
    CALL CD_Run_Deck_Driver('deck_hard_motion.dat', 'deck_hard_motion', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_BADINPUT .AND. INDEX(em_l, 'motionFile line 2') > 0, &
                 'slash inside a motionFile value fails closed naming the row: '//TRIM(em_l))

    ! Syrope: the SYROPE:<path> EA token and the settings-file OWC path may contain '/'
    ! without quoting (they are read as strings, never list-directed).
    CALL ensure_directory('syrope_nest')
    CALL write_syrope_files('syrope_nest/syr.dat', 'syrope_nest/owc_n.dat')
    OPEN (NEWUNIT=u, FILE='syrope_nest/syr.dat', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '../syrope_nest/owc_n.dat  OWC    Original working curve table path'
    WRITE (u, '(A)') 'LINEAR      WCType Working curve formula'
    WRITE (u, '(A)') '0.6         k1     shape parameter p1'
    WRITE (u, '(A)') '0.0         k2     shape parameter p2'
    CLOSE (u)
    CALL write_syrope_deck('deck_hard_syrope_path.dat', 'SYROPE:syrope_nest/syr.dat|1.53e8|23.12', &
                           '5.0e10|1.0e5', wtrdpth=10.0_wp, syrope_ic_row='1, 1 2.0e6 1.0e6')
    BLOCK
      TYPE(CD_ModelType), ALLOCATABLE :: smodels(:)
      CALL CD_Init_Deck_Models('deck_hard_syrope_path.dat', smodels, es_l, em_l)
      ! the IC list names line 1 twice: the comma list is parsed and the repeat is rejected
      CALL require(es_l == CD_DECKDRV_BADINPUT .AND. INDEX(em_l, 'duplicate SYROPE IC assignment for LINE 1') > 0, &
                   'SYROPE IC comma list "1, 1" is parsed as two ids: '//TRIM(em_l))
      CALL write_syrope_deck('deck_hard_syrope_path.dat', 'SYROPE:syrope_nest/syr.dat|1.53e8|23.12', &
                             '5.0e10|1.0e5', wtrdpth=10.0_wp, syrope_ic_row='1 2.0e6 1.0e6')
      CALL CD_Init_Deck_Models('deck_hard_syrope_path.dat', smodels, es_l, em_l)
      CALL require(es_l == CD_DECKDRV_OK, 'unquoted SYROPE:<dir>/<file> and OWC ../<dir>/<file> paths '// &
                   'build: '//TRIM(em_l))
      IF (es_l == CD_DECKDRV_OK) CALL end_test_models(smodels)
      CALL write_syrope_deck('deck_hard_syrope_ic_space.dat', 'SYROPE:syrope_nest/syr.dat|1.53e8|23.12', &
                             '5.0e10|1.0e5', wtrdpth=10.0_wp, syrope_ic_row='1 1 2.0e6 1.0e6')
      CALL CD_Init_Deck_Models('deck_hard_syrope_ic_space.dat', smodels, es_l, em_l)
      CALL require(es_l == CD_DECKDRV_BADINPUT .AND. INDEX(em_l, 'separated by commas') > 0, &
                   'SYROPE IC ids without a comma fail closed: '//TRIM(em_l))
    END BLOCK

    ! Bathymetry rows: a decimal comma is malformed, never a shifted grid.
    OPEN (NEWUNIT=u, FILE='deck_hard_bathy.xyz', STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '-100.0 -100.0 50.0'
    WRITE (u, '(A)') '600.0 -100.0 50,0'
    WRITE (u, '(A)') '-100.0 100.0 50.0'
    WRITE (u, '(A)') '600.0 100.0 50.0'
    CLOSE (u)
    CALL expect_badinput('deck_hard_bathy.dat', hardening_deck(ANCHOR, SECTION, 'deck_hard_bathy.xyz '// &
                                                               'bathymetryFile', 'FairTen1', flat_seabed=.FALSE.), &
                         'decimal comma in a bathymetry row', 'bathymetry file line 2')

    ! Names are stored in 64-character fields: a longer name fails closed naming the deck
    ! line, instead of being truncated (and possibly aliasing another name).
    CALL expect_badinput('deck_hard_long_section_type.dat', &
                         hardening_deck(ANCHOR, '1 '//REPEAT('c', 65)//' 410.0 41', '', 'FairTen1'), &
                         'over-long SECTIONS LineType', 'deck line 18: column 2 value "cccc')
    CALL expect_badinput('deck_hard_long_point_type.dat', &
                         hardening_deck('1 '//REPEAT('F', 65)//' 400.0 0.0 -50.0', SECTION, '', 'FairTen1'), &
                         'over-long POINTS type', 'is longer than 64 characters')
    ! A 64-character name is admitted by the reader and resolved as a name.
    CALL expect_badinput('deck_hard_max_section_type.dat', &
                         hardening_deck(ANCHOR, '1 '//REPEAT('c', 64)//' 410.0 41', '', 'FairTen1'), &
                         '64-character SECTIONS LineType', 'unknown LineType "'//REPEAT('c', 64)//'"')

    ! A stock 7-column LINES row already defines the line's only section.
    BLOCK
      CHARACTER(:), ALLOCATABLE :: stock_body
      INTEGER :: k
      stock_body = hardening_deck(ANCHOR, SECTION, '', 'FairTen1')
      k = INDEX(stock_body, NEW_LINE('a')//'1 2 1 -'//NEW_LINE('a'))
      CALL require(k > 0, 'stock-row fixture locates the LINES row')
      IF (k > 0) THEN
        stock_body = stock_body(1:k)//'1 chain 2 1 410.0 41 -'//stock_body(k + 8:)
        CALL expect_badinput('deck_hard_stock_plus_sections.dat', stock_body, &
                             '7-column LINES row plus SECTIONS rows', &
                             'LINE 1 is defined by a 7-column LINES row')
      END IF
    END BLOCK

    ! OPTION current needs dtM only on the standalone route; a caller-driven deck
    ! takes its clock from the host (as frictionMu does).
    CALL expect_badinput('deck_hard_current_no_dtm.dat', &
                         hardening_deck(ANCHOR, SECTION, 'uniform 0.2 0.0 0.0 current', 'FairTen1'), &
                         'standalone current without dtM', 'standalone OPTION current requires dtM')
    BLOCK
      TYPE(CD_DeckAggregateType) :: cagg
      CALL CD_Init_Deck_Aggregate('deck_hard_current_no_dtm.dat', 0.05_wp, cagg, es_l, em_l)
      CALL require(es_l == CD_DECKDRV_OK, 'caller-driven current deck needs no dtM: '//TRIM(em_l))
      IF (es_l == CD_DECKDRV_OK) CALL CD_End_Deck_Aggregate(cagg)
    END BLOCK

    ! A finite-EI line needs mass: a named input error, not a failure inside the model build.
    BLOCK
      CHARACTER(*), PARAMETER :: CHAIN_ROW = 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
      CHARACTER(*), PARAMETER :: STIFF_ROW = 'stiff 0.252 390.0 1.674e9 -1.0 1.0e4 1.37 0.64 1.0 0.0'
      CHARACTER(:), ALLOCATABLE :: body
      CHARACTER(1) :: nl
      CHARACTER(8), PARAMETER :: MASSES(2) = [CHARACTER(8) :: '0.0', '-1.0']
      INTEGER :: k, m
      nl = NEW_LINE('a')
      DO m = 1, SIZE(MASSES)
        body = hardening_deck(ANCHOR, SECTION, '0.1 dtM'//nl//'0.2 TMax', 'FairTen1')
        k = INDEX(body, CHAIN_ROW)
        CALL require(k > 0, 'finite-EI mass fixture locates the LINE TYPES row')
        IF (k == 0) CYCLE
        body = body(1:k - 1)//'chain 0.252 '//TRIM(MASSES(m))//' 1.674e9 -1.0 1.0e4 1.37 0.64 1.0 0.0'// &
               body(k + LEN(CHAIN_ROW):)
        CALL expect_badinput('deck_hard_finite_mass.dat', body, 'a finite-EI line type of mass '//TRIM(MASSES(m)), &
                             'LINE TYPE "chain": MassDenInAir must be > 0 on a finite-EI line')
      END DO
      body = hardening_deck(ANCHOR, '1 chain 200.0 20'//nl//'1 stiff 210.0 21', '0.1 dtM'//nl//'0.2 TMax', &
                            'FairTen1')
      k = INDEX(body, CHAIN_ROW)
      CALL require(k > 0, 'split-line fixture locates the LINE TYPES row')
      IF (k > 0) THEN
        ! a line of EI=0 and finite-EI sections is one finite-EI cable, as on the coupled aggregate
        body = body(1:k - 1)//CHAIN_ROW//nl//STIFF_ROW//body(k + LEN(CHAIN_ROW):)
        CALL write_text_file('deck_hard_split_line.dat', body)
        CALL CD_Run_Deck_Driver('deck_hard_split_line.dat', 'deck_hard_split_line', conv_l, es_l, em_l)
        CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'a line of EI=0 and finite-EI sections runs: '// &
                     TRIM(em_l))
      END IF
    END BLOCK

    ! The last waves or current row sets the sea: a row it overrides leaves nothing behind
    ! that the bounds of the effective row are checked against (a JONSWAP gamma under an
    ! Airy row, a uniform velocity under a profile row), while the effective row is checked.
    BLOCK
      CHARACTER(1) :: nl
      CHARACTER(*), PARAMETER :: CLOCK = '0.1 dtM'//NEW_LINE('a')//'0.2 TMax'
      CHARACTER(64), PARAMETER :: OVERRIDDEN(4) = [CHARACTER(64) :: &
                                                   'jonswap 3.0 10.0 2000.0 0.0 waves', &
                                                   'jonswap 3.0 10.0 2000.0 0.0 waves', &
                                                   'uniform 2000.0 0.0 0.0 current', &
                                                   'airy 2000.0 8.0 0.0 waves']
      CHARACTER(64), PARAMETER :: EFFECTIVE(4) = [CHARACTER(64) :: &
                                                  'airy 2.0 8.0 0.0 waves', 'stream 2.0 8.0 0.0 waves', &
                                                  'profile -30 0.2 0 0 0 0.5 0 0 current', 'none waves']
      INTEGER :: k
      nl = NEW_LINE('a')
      DO k = 1, SIZE(OVERRIDDEN)
        CALL write_text_file('deck_hard_overridden.dat', hardening_deck(ANCHOR, SECTION, CLOCK//nl// &
                                                                        TRIM(OVERRIDDEN(k))//nl//TRIM(EFFECTIVE(k)), &
                                                                        'FairTen1'))
        CALL CD_Run_Deck_Driver('deck_hard_overridden.dat', 'deck_hard_overridden', conv_l, es_l, em_l)
        CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, '"'//TRIM(OVERRIDDEN(k))//'" overridden by "'// &
                     TRIM(EFFECTIVE(k))//'" leaves no stale bound: '//TRIM(em_l))
      END DO
      CALL expect_badinput('deck_hard_effective_gamma.dat', hardening_deck(ANCHOR, SECTION, CLOCK//nl// &
                                                                           'airy 2.0 8.0 0.0 waves'//nl// &
                                                                           'jonswap 3.0 10.0 2000.0 0.0 waves', &
                                                                           'FairTen1'), &
                           'an out-of-range JONSWAP gamma on the effective row', 'gamma <= 1e3')
      CALL expect_badinput('deck_hard_effective_current.dat', hardening_deck(ANCHOR, SECTION, CLOCK//nl// &
                                                                             'profile -30 0.2 0 0 0 0.5 0 0 current'// &
                                                                             nl//'uniform 2000.0 0.0 0.0 current', &
                                                                             'FairTen1'), &
                           'an out-of-range uniform current on the effective row', 'at most 1e3 m/s')
    END BLOCK
  END SUBROUTINE check_parser_hardening

  FUNCTION rigid6_failure_deck(failure_rows, extra_point) RESULT(body)
    !! The submerged buoy of examples/rigid6_buoy.dat (three taut polyester legs, 0.6 m/s current)
    !! on the staggered body march, with optional FAILURE rows (newline-separated) and an optional
    !! extra POINTS row. Outputs: FairTen1-3, Body1Px/Py/Pz and the line-1 End A node height.
    CHARACTER(*), INTENT(IN) :: failure_rows
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra_point
    CHARACTER(:), ALLOCATABLE :: body
    CHARACTER(1) :: nl
    nl = NEW_LINE('a')
    body = 'Rigid6 buoy line-failure rig'//nl//'--- LINE TYPES ---'//nl// &
           'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//nl//'(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//nl// &
           'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'//nl//'--- BODIES ---'//nl// &
           'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'//nl// &
           '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'// &
           nl//'1 Rigid6 0.0 0.0 -20.0 0.0 0.0 0.0 2.0e4 40.0 0.0 0.0 0.0 8.0 0.5 3.5e4 3.5e4 3.5e4'//nl// &
           '--- POINTS ---'//nl//'ID Type X Y Z Mass Vol CdA Ca'//nl//'(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'//nl// &
           '1 Body1 1.5 0.0 -2.0 0 0 0 0'//nl//'2 Body1 -0.75 1.299 -2.0 0 0 0 0'//nl// &
           '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'//nl//'4 Fixed 40.0 0.0 -100.0 0 0 0 0'//nl// &
           '5 Fixed -20.0 34.641 -100.0 0 0 0 0'//nl//'6 Fixed -20.0 -34.641 -100.0 0 0 0 0'//nl
    IF (PRESENT(extra_point)) body = body//extra_point//nl
    body = body//'--- LINES ---'//nl//'ID NodeA NodeB Outputs'//nl//'(-) (-) (-) (-)'//nl// &
           '1 1 4 -'//nl//'2 2 5 -'//nl//'3 3 6 -'//nl//'--- SECTIONS ---'//nl// &
           'LineID LineType Length NumSegs'//nl//'(-) (-) (m) (-)'//nl//'1 poly 86.85 20'//nl// &
           '2 poly 86.85 20'//nl//'3 poly 86.85 20'//nl
    IF (LEN_TRIM(failure_rows) > 0) body = body//'--- FAILURE ---'//nl//'FailID Point Line(s) FailTime FailTen'// &
                                           nl//'(-) (-) (-) (s) (N)'//nl//failure_rows//nl
    body = body//'--- OPTIONS ---'//nl//'9.80665 g'//nl//'1025.0 rhoW'//nl//'100.0 WtrDpth'//nl// &
           '0.01 dtM'//nl//'3.0 TMax'//nl//'uniform 0.6 0.0 0.0 current'//nl//'staggered bodyScheme'//nl// &
           '--- OUTPUTS ---'//nl//'FairTen1 FairTen2 FairTen3 Body1Px Body1Py Body1Pz L1N1pz'//nl// &
           '--- need this line ---'
  END FUNCTION rigid6_failure_deck

  SUBROUTINE read_last_row(path, vals, ios)
    !! The last data row of a driver .out, without its time column.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: vals(:)
    INTEGER, INTENT(OUT) :: ios
    INTEGER :: u, rs
    REAL(wp) :: t
    CHARACTER(4096) :: buf, last
    vals = 0.0_wp
    last = ''
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    IF (ios == 0) READ (u, '(A)', IOSTAT=ios) buf
    DO WHILE (ios == 0)
      READ (u, '(A)', IOSTAT=rs) buf
      IF (rs /= 0) EXIT
      IF (LEN_TRIM(buf) > 0) last = buf
    END DO
    CLOSE (u)
    IF (ios == 0) READ (last, *, IOSTAT=ios) t, vals
  END SUBROUTINE read_last_row

  SUBROUTINE check_rigid6_failure()
    !! Line FAILURE on a free Rigid6 body. (a) A row that never fires leaves the staggered march
    !! bit-identical to the twin without FAILURE. (b) A time-triggered row detaches line 1 from
    !! its body attachment: the detached end falls freely, the line goes slack, and the body
    !! moves off its intact position. (c) A tension trigger that fires at the first step matches
    !! the time trigger at that step bit-for-bit. (d) The staggered body march takes no Connect/
    !! Free point beside a FAILURE; a rod deck stays rejected by name.
    REAL(wp) :: twin(7), never(7), timed(7), tens(7), first(7)
    INTEGER :: es_l, ios
    LOGICAL :: conv_l
    CHARACTER(512) :: em_l

    CALL write_text_file('deck_r6fail_twin.dat', rigid6_failure_deck(''))
    CALL CD_Run_Deck_Driver('deck_r6fail_twin.dat', 'deck_r6fail_twin', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'Rigid6 failure twin converged: '//TRIM(em_l))
    CALL read_last_row('deck_r6fail_twin.out', twin, ios)
    CALL require(ios == 0, 'read Rigid6 failure twin')
    CALL read_first_row('deck_r6fail_twin.out', first, ios)
    CALL require(ios == 0, 'read Rigid6 failure twin t = 0 row')

    CALL write_text_file('deck_r6fail_never.dat', rigid6_failure_deck('1 P1 1 50.0 0'))
    CALL CD_Run_Deck_Driver('deck_r6fail_never.dat', 'deck_r6fail_never', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'never-firing Rigid6 FAILURE converged: '//TRIM(em_l))
    CALL read_last_row('deck_r6fail_never.out', never, ios)
    CALL require(ios == 0 .AND. ALL(ABS(never - twin) <= 0.0_wp), &
                 'never-firing Rigid6 FAILURE is bit-identical to the twin without FAILURE')

    CALL write_text_file('deck_r6fail_time.dat', rigid6_failure_deck('1 P1 1 0.5 0'))
    CALL CD_Run_Deck_Driver('deck_r6fail_time.dat', 'deck_r6fail_time', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'time-triggered Rigid6 FAILURE converged: '//TRIM(em_l))
    CALL read_last_row('deck_r6fail_time.out', timed, ios)
    CALL require(ios == 0, 'read time-triggered Rigid6 FAILURE')
    CALL require(timed(1) < 0.05_wp*first(1), 'the detached line 1 goes slack at its free end')
    CALL require(timed(7) < twin(7) - 0.05_wp, 'the detached end of line 1 falls freely')
    CALL require(ABS(timed(4) - twin(4)) + ABS(timed(5) - twin(5)) > 1.0e-2_wp, &
                 'the body moves off its intact trajectory after the failure')
    CALL require(ALL(ABS(timed) < 1.0e9_wp), 'the Rigid6 FAILURE run stays finite')

    CALL write_text_file('deck_r6fail_step.dat', rigid6_failure_deck('1 P1 1 0.01 0'))
    CALL CD_Run_Deck_Driver('deck_r6fail_step.dat', 'deck_r6fail_step', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'first-step Rigid6 FAILURE converged: '//TRIM(em_l))
    CALL read_last_row('deck_r6fail_step.out', timed, ios)
    CALL require(ios == 0, 'read first-step Rigid6 FAILURE')
    CALL write_text_file('deck_r6fail_ten.dat', rigid6_failure_deck('1 P1 1 0 1.0'))
    CALL CD_Run_Deck_Driver('deck_r6fail_ten.dat', 'deck_r6fail_ten', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'tension-triggered Rigid6 FAILURE converged: '//TRIM(em_l))
    CALL read_last_row('deck_r6fail_ten.out', tens, ios)
    CALL require(ios == 0 .AND. ALL(ABS(tens - timed) <= 0.0_wp), &
                 'a tension trigger at the first step matches the first-step time trigger bit-for-bit')

    CALL expect_badinput('deck_r6fail_free.dat', rigid6_failure_deck('1 P1 1 0.5 0', &
                                                                     extra_point='7 Free 10.0 0.0 -50.0 0 0 0 0'), &
                         'Rigid6 FAILURE beside a Free point', 'Connect/Free')
  END SUBROUTINE check_rigid6_failure

  SUBROUTINE check_rejected_static_branch_status()
    !! A net-heavy 200 m finite-EI line anchored on a flat seabed 20 m from its fairlead and
    !! 10 m below it is longer than its span plus rise: it cannot hang as a catenary, and
    !! 170 m of excess length leaves no equilibrium held by its bending stiffness clear of
    !! the seabed either; the static solve names that geometry. The deck is valid input, so the
    !! driver reports SOLVEFAIL (exit 2), not BADINPUT (exit 1).
    CHARACTER(1) :: nl
    CHARACTER(512) :: em_l
    INTEGER :: es_l
    LOGICAL :: conv_l
    nl = NEW_LINE('a')
    CALL write_text_file('deck_coarse_fold.dat', 'coarse finite-EI fold'//nl// &
                         '--- LINE TYPES ---'//nl//'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//nl// &
                         '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//nl// &
                         'cab 0.10 100.0 1.0e9 0.0 1.0e4 1.2 0.1 1.0 0.0'//nl// &
                         '--- POINTS ---'//nl//'ID Type X Y Z'//nl//'(-) (-) (m) (m) (m)'//nl// &
                         '1 Fixed 0.0 0.0 -10.0'//nl//'2 Coupled 20.0 0.0 0.0'//nl// &
                         '--- LINES ---'//nl//'ID NodeA NodeB Outputs'//nl//'(-) (-) (-) (-)'//nl// &
                         '1 2 1 -'//nl//'--- SECTIONS ---'//nl//'LineID LineType Length NumSegs'//nl// &
                         '(-) (-) (m) (-)'//nl//'1 cab 200.0 3'//nl//'--- OPTIONS ---'//nl// &
                         '9.80665 g'//nl//'1025.0 rhoW'//nl//'10.0 WtrDpth'//nl//'0.05 dtM'//nl// &
                         '0.10 TMax'//nl//'--- OUTPUTS ---'//nl//'FairTen1'//nl//'--- need this line ---')
    CALL CD_Run_Deck_Driver('deck_coarse_fold.dat', 'deck_coarse_fold', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_SOLVEFAIL .AND. .NOT. conv_l, &
                 'rejected static branch reports SOLVEFAIL: '//TRIM(em_l))
    CALL require(INDEX(em_l, 'too long for its span') > 0, &
                 'rejected static branch names the geometric reason: '//TRIM(em_l))
  END SUBROUTINE check_rejected_static_branch_status

  SUBROUTINE check_hangoff_and_fine_mesh()
    !! (a) A weight hung from two ELEVATED Fixed attachments (Fixed NodeA above a Connect
    !! NodeB) is already in CableDyn order: End A is the upper attachment, so FairTen is the
    !! top line-end tension, and it must equal the independent static solve of the same
    !! leg (Coupled top, Fixed bottom). Treating the Fixed end as a bottom anchor seeded
    !! the leg as a compressed chord, and FairTen then read 0 for the whole run.
    !! (b) A stiff grounded chain converges statically at every mesh from 55 to 330
    !! segments (the round-off floor of the nodal residual grows as EA/l0 while the load
    !! scale shrinks) and the end tensions converge with the mesh.
    CHARACTER(*), PARAMETER :: CHAIN = 'chain 0.2791 480.93 2.058e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    INTEGER, PARAMETER :: NSEGS(5) = [55, 110, 165, 220, 330]
    CHARACTER(1) :: nl
    CHARACTER(:), ALLOCATABLE :: body
    CHARACTER(512) :: em_l
    CHARACTER(16) :: nseg_txt
    LOGICAL :: conv_l
    INTEGER :: es_l, k, ios
    REAL(wp) :: hang(8), stat(2), mesh(2, 5)
    CHARACTER(64) :: conn_txt

    nl = NEW_LINE('a')
    body = 'Weight hung from two elevated attachments'//nl//'--- LINE TYPES ---'//nl// &
           'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//nl//'(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//nl// &
           CHAIN//nl//'--- POINTS ---'//nl//'ID Type X Y Z Mass Vol CdA Ca'//nl// &
           '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'//nl//'1 Fixed -200.0 0.0 0.0 0 0 0 0'//nl// &
           '2 Connect 0.0 0.0 -100.0 50000.0 2.0 0 0'//nl//'3 Fixed 200.0 0.0 0.0 0 0 0 0'//nl// &
           '--- LINES ---'//nl//'ID NodeA NodeB Outputs'//nl//'(-) (-) (-) (-)'//nl//'1 1 2 -'//nl// &
           '2 3 2 -'//nl//'--- SECTIONS ---'//nl//'LineID LineType Length NumSegs'//nl// &
           '(-) (-) (m) (-)'//nl//'1 chain 240.0 30'//nl//'2 chain 240.0 30'//nl//'--- OPTIONS ---'//nl// &
           '9.80665 g'//nl//'1025.0 rhoW'//nl//'0.01 dtM'//nl//'0.01 TMax'//nl//'--- OUTPUTS ---'//nl// &
           'FairTen1 AnchTen1 Ten1N1 L1N1px L1N1pz FairTen2 Point2px Point2pz'//nl//'--- need this line ---'
    CALL write_text_file('deck_hangoff.dat', body)
    CALL CD_Run_Deck_Driver('deck_hangoff.dat', 'deck_hangoff', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'hang-off Connect deck runs: '//TRIM(em_l))
    CALL read_first_row('deck_hangoff.out', hang, ios)
    CALL require(ios == 0, 'read hang-off t=0 row')
    ! the static equivalent of leg 1: the same leg with the top end Coupled and the bottom
    ! held where the Connect settled (the point moves to its static force balance)
    WRITE (conn_txt, '(ES24.16,A,ES24.16)') hang(7), ' 0.0 ', hang(8)
    body = 'Hang-off leg, static equivalent'//nl//'--- LINE TYPES ---'//nl// &
           'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//nl//'(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//nl// &
           CHAIN//nl//'--- POINTS ---'//nl//'ID Type X Y Z'//nl//'(-) (-) (m) (m) (m)'//nl// &
           '1 Coupled -200.0 0.0 0.0'//nl//'2 Fixed '//TRIM(conn_txt)//nl//'--- LINES ---'//nl// &
           'ID NodeA NodeB Outputs'//nl//'(-) (-) (-) (-)'//nl//'1 1 2 -'//nl//'--- SECTIONS ---'//nl// &
           'LineID LineType Length NumSegs'//nl//'(-) (-) (m) (-)'//nl//'1 chain 240.0 30'//nl// &
           '--- OPTIONS ---'//nl//'9.80665 g'//nl//'1025.0 rhoW'//nl//'--- OUTPUTS ---'//nl// &
           'FairTen1 AnchTen1'//nl//'--- need this line ---'
    CALL write_text_file('deck_hangoff_static.dat', body)
    CALL CD_Run_Deck_Driver('deck_hangoff_static.dat', 'deck_hangoff_static', conv_l, es_l, em_l)
    CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'hang-off static equivalent converges: '//TRIM(em_l))
    CALL read_first_row('deck_hangoff_static.out', stat, ios)
    CALL require(ios == 0, 'read hang-off static row')
    CALL require(hang(1) > 5.0e5_wp .AND. hang(1) > hang(2) .AND. hang(2) > 0.0_wp, &
                 'hang-off FairTen1 is the (larger) top-end tension, AnchTen1 the Connect end')
    CALL require(ABS(hang(3) - hang(1)) <= 1.0e-9_wp*hang(1), 'hang-off FairTen1 = Ten1N1 (deck node 1 = End A)')
    CALL require(ABS(hang(4) + 200.0_wp) < 1.0e-9_wp .AND. ABS(hang(5)) < 1.0e-9_wp, &
                 'hang-off deck node 1 sits on the elevated Fixed attachment')
    ! (to the point-balance tolerance: the Connect position is a converged Newton iterate)
    CALL require(ABS(hang(1) - stat(1)) <= 1.0e-6_wp*stat(1) .AND. ABS(hang(2) - stat(2)) <= 1.0e-6_wp*stat(2), &
                 'hang-off FairTen1/AnchTen1 equal the static line-end tensions of the same leg')
    CALL require(ABS(hang(6) - hang(1)) <= 1.0e-8_wp*hang(1), 'symmetric hang-off legs carry equal FairTen')
    ! the Connect is at its static force balance: on the symmetry plane, below the seed depth
    ! only as far as the legs stretch, and the two legs' vertical pulls carry its net weight
    CALL require(ABS(hang(7)) < 1.0e-6_wp .AND. hang(8) < 0.0_wp, 'hang-off Connect settles on the symmetry plane')

    DO k = 1, SIZE(NSEGS)
      WRITE (nseg_txt, '(I0)') NSEGS(k)
      body = 'R3 chain catenary mesh sweep'//nl//'--- LINE TYPES ---'//nl// &
             'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//nl//'(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//nl// &
             'chainR3 0.2466 373.5 1.607e9 -1.0 0.0 1.37 0.64 1.0 0.0'//nl//'--- POINTS ---'//nl// &
             'ID Type X Y Z'//nl//'(-) (-) (m) (m) (m)'//nl//'1 Fixed 500.0 0.0 -100.0'//nl// &
             '2 Coupled 0.0 0.0 0.0'//nl//'--- LINES ---'//nl//'ID NodeA NodeB Outputs'//nl// &
             '(-) (-) (-) (-)'//nl//'1 2 1 -'//nl//'--- SECTIONS ---'//nl//'LineID LineType Length NumSegs'//nl// &
             '(-) (-) (m) (-)'//nl//'1 chainR3 550.0 '//TRIM(nseg_txt)//nl//'--- OPTIONS ---'//nl// &
             '9.80665 g'//nl//'1025.0 rhoW'//nl//'100.0 WtrDpth'//nl//'1.0e5 kBot'//nl//'--- OUTPUTS ---'//nl// &
             'FairTen1 AnchTen1'//nl//'--- need this line ---'
      CALL write_text_file('deck_mesh_sweep.dat', body)
      CALL CD_Run_Deck_Driver('deck_mesh_sweep.dat', 'deck_mesh_sweep', conv_l, es_l, em_l)
      CALL require(es_l == CD_DECKDRV_OK .AND. conv_l, 'R3 chain static converges at NumSegs '// &
                   TRIM(nseg_txt)//': '//TRIM(em_l))
      CALL read_first_row('deck_mesh_sweep.out', mesh(:, k), ios)
      CALL require(ios == 0, 'read R3 mesh-sweep row')
    END DO
    ! FairTen is the line-end force (end element tension plus the end node's lumped weight),
    ! the discrete end reaction: already mesh-converged at 55 segments (it no longer carries
    ! the w*l0/2 bias of the top-element tension); AnchTen sits on the grounded run.
    CALL require((MAXVAL(mesh(1, :)) - MINVAL(mesh(1, :)))/MAXVAL(mesh(1, :)) < 0.005_wp, &
                 'R3 FairTen (line-end force) is mesh-converged (within 0.5% from 55 to 330 segments)')
    CALL require(MAXVAL(mesh(2, :)) - MINVAL(mesh(2, :)) < 0.01_wp*MAXVAL(mesh(2, :)), &
                 'R3 AnchTen is mesh-insensitive (1%)')
  END SUBROUTINE check_hangoff_and_fine_mesh

  SUBROUTINE read_first_row(path, vals, ios)
    !! The t=0 data row (third record) of a driver .out, without its time column.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: vals(:)
    INTEGER, INTENT(OUT) :: ios
    INTEGER :: u
    REAL(wp) :: t
    CHARACTER(4096) :: buf
    vals = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    IF (ios == 0) READ (u, '(A)', IOSTAT=ios) buf
    IF (ios == 0) READ (u, '(A)', IOSTAT=ios) buf
    CLOSE (u)
    IF (ios == 0) READ (buf, *, IOSTAT=ios) t, vals
  END SUBROUTINE read_first_row

  SUBROUTINE write_text_file(path, body)
    !! Write a newline-separated in-memory deck body to disk.
    CHARACTER(*), INTENT(IN) :: path, body
    INTEGER :: u, ios, i0, i

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'open '//TRIM(path))
    i0 = 1
    DO i = 1, LEN_TRIM(body)
      IF (body(i:i) == NEW_LINE('a')) THEN
        WRITE (u, '(A)') body(i0:i - 1)
        i0 = i + 1
      END IF
    END DO
    IF (i0 <= LEN_TRIM(body)) WRITE (u, '(A)') body(i0:LEN_TRIM(body))
    CLOSE (u)
  END SUBROUTINE write_text_file

  SUBROUTINE ensure_directory(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: stat

    CALL EXECUTE_COMMAND_LINE('mkdir '//TRIM(path), EXITSTAT=stat)
  END SUBROUTINE ensure_directory

  SUBROUTINE check_model_from_deck(model)
    !! Basic lifecycle smoke check for deck-created models.
    !! INOUT: CD_Calc_Model_CoupledLoads writes the model's reusable query workspace.
    TYPE(CD_ModelType), INTENT(INOUT) :: model
    INTEGER :: es_l, ndof
    CHARACTER(256) :: em_l
    REAL(wp), ALLOCATABLE :: q(:), v(:), a(:), loads(:)

    CALL require(CD_Model_Is_Initialized(model), 'deck-model initialized')
    ndof = CD_Model_NDOF(model, es_l, em_l)
    CALL require(es_l == CD_MODEL_OK .AND. ndof == 126, 'deck-model ndof')
    ALLOCATE (q(ndof), v(ndof), a(ndof), loads(6))
    CALL CD_Get_Model_State(model, q, v, a, es_l, em_l)
    CALL require(es_l == CD_MODEL_OK, 'deck-model state query')
    CALL require(nan_max_abs(v) < 1.0e-12_wp, 'deck-model starts at rest')
    CALL CD_Calc_Model_CoupledLoads(model, loads, es_l, em_l)
    CALL require(es_l == CD_MODEL_OK, 'deck-model coupled loads')
    CALL require(nan_max_abs(loads) > 1.0_wp, 'deck-model nonzero endpoint loads')
  END SUBROUTINE check_model_from_deck

  SUBROUTINE end_test_models(local_models)
    TYPE(CD_ModelType), INTENT(INOUT) :: local_models(:)
    INTEGER :: i, es_l
    CHARACTER(80) :: em_l
    DO i = 1, SIZE(local_models)
      CALL CD_End_Model(local_models(i), es_l, em_l)
    END DO
  END SUBROUTINE end_test_models

  SUBROUTINE read_out(path, fairlead, anchor, ErrStat)
    !! Read FairTen1 (col 2) and AnchTen1 (col 3) from the t = 0 data row of a `.out`.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: fairlead, anchor
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t
    CHARACTER(512) :: buf
    ErrStat = 1; fairlead = 0.0_wp; anchor = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf      ! # comment
    READ (u, '(A)', IOSTAT=ios) buf      ! header
    READ (u, '(A)', IOSTAT=ios) buf      ! t = 0 data row (tab-separated)
    IF (ios == 0) READ (buf, *, IOSTAT=ios) t, fairlead, anchor   ! tabs are list-dir separators
    CLOSE (u)
    IF (ios == 0) ErrStat = 0
  END SUBROUTINE read_out

  SUBROUTINE read_out6(path, fair, anch, ErrStat)
    !! Read FairTen1..3 (cols 2-4) and AnchTen1..3 (cols 5-7) from the t = 0 data row of a `.out`.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: fair(3), anch(3)
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t
    CHARACTER(512) :: buf
    ErrStat = 1; fair = 0.0_wp; anch = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf      ! # comment
    READ (u, '(A)', IOSTAT=ios) buf      ! header
    READ (u, '(A)', IOSTAT=ios) buf      ! t = 0 data row (tab-separated)
    IF (ios == 0) READ (buf, *, IOSTAT=ios) t, fair(1), fair(2), fair(3), anch(1), anch(2), anch(3)
    CLOSE (u)
    IF (ios == 0) ErrStat = 0
  END SUBROUTINE read_out6

  SUBROUTINE write_volturnus_deck(path)
    !! IEA-15MW / UMaine VolturnUS-S catenary mooring: the three 120-deg all-chain lines at
    !! 200 m water depth, anchors Fixed on the seabed (radius 837.6 m), fairleads Coupled at
    !! the platform (radius 58 m, z = -14 m). R4 studless chain (volume-equivalent diameter
    !! 0.333 m, dry mass 685 kg/m, EA 3.270e9 N, 850 m). Mirrors, at three lines, the single
    !! line in examples/iea15mw_volturnus_mooring.dat.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'IEA-15MW VolturnUS-S mooring -- 3 catenary chains (120 deg), static IC'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.333 685.0 3.270e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 837.6 0.0 -200.0'
    WRITE (u, '(A)') '2 Fixed -418.8 725.36 -200.0'
    WRITE (u, '(A)') '3 Fixed -418.8 -725.36 -200.0'
    WRITE (u, '(A)') '4 Coupled 58.0 0.0 -14.0'
    WRITE (u, '(A)') '5 Coupled -29.0 50.229 -14.0'
    WRITE (u, '(A)') '6 Coupled -29.0 -50.229 -14.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 4 1 -'
    WRITE (u, '(A)') '2 5 2 -'
    WRITE (u, '(A)') '3 6 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 850.0 50'
    WRITE (u, '(A)') '2 chain 850.0 50'
    WRITE (u, '(A)') '3 chain 850.0 50'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '3.0e5 cBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2 FairTen3 AnchTen1 AnchTen2 AnchTen3'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_volturnus_deck

  SUBROUTINE read_dynamic_tensions(path, fairlead, anchor, ErrStat)
    !! Read the final FairTen1 / AnchTen1 row from the held-end dynamic `.out`.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: fairlead, anchor
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t, node1x, node_end_z, node_end_vz, node_end_ten
    CHARACTER(512) :: buf

    ErrStat = 1
    fairlead = 0.0_wp
    anchor = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
      READ (buf, *, IOSTAT=ios) t, fairlead, anchor, node1x, node_end_z, node_end_vz, node_end_ten
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ErrStat = 0
  END SUBROUTINE read_dynamic_tensions

  SUBROUTINE check_dynamic_out(path)
    !! Dynamic held-end smoke: header + t=0 plus three rows for dtM=0.01/TMax=0.03.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, fair0, anch0, fair_last, anch_last, node1x, node_end_z, node_end_vz, node_end_ten
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    fair0 = 0.0_wp
    anch0 = 0.0_wp
    fair_last = 0.0_wp
    anch_last = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair_last, anch_last, node1x, node_end_z, node_end_vz, node_end_ten
      CALL require(ios == 0, 'parse dynamic row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        fair0 = fair_last
        anch0 = anch_last
        CALL require(ABS(t) < 1.0e-12_wp, 'dynamic first row at t=0')
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == 4, 'dynamic .out has t=0 plus three time steps')
    CALL require(fair_last > 0.0_wp .AND. anch_last > 0.0_wp, 'dynamic tensions finite positive')
    CALL require(ABS(fair_last - fair0)/fair0 < 1.0e-3_wp, 'held dynamic fairlead remains near IC')
    CALL require(ABS(anch_last - anch0)/anch0 < 1.0e-3_wp, 'held dynamic anchor remains near IC')
    CALL require(ABS(node1x) < 1.0e-8_wp, 'line-node fairlead position channel L1N1px')
    CALL require(ABS(node_end_z + 50.0_wp) < 1.0e-8_wp, 'line-node anchor position channel L1N42pz')
    CALL require(ABS(node_end_vz) < 1.0e-8_wp, 'line-node anchor velocity channel L1N42vz')
    CALL require(ABS(node_end_ten - anch_last)/anch_last < 1.0e-10_wp, 'line-node tension channel Ten1N42')
  END SUBROUTINE check_dynamic_out

  SUBROUTINE check_dynamic_current_out(path, fair_still)
    !! The steady current is part of the static initial condition: the held line starts
    !! from the current-loaded equilibrium (FairTen differs from the still-water value
    !! fair_still at t = 0) and stays there.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: fair_still
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, fair0, anch0, fair_last, anch_last
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open uniform-current .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    fair0 = 0.0_wp
    anch0 = 0.0_wp
    fair_last = 0.0_wp
    anch_last = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read uniform-current row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair_last, anch_last
      CALL require(ios == 0, 'parse uniform-current row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        fair0 = fair_last
        anch0 = anch_last
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == 4, 'uniform-current .out has t=0 plus three time steps')
    CALL require(fair_last > 0.0_wp .AND. anch_last > 0.0_wp, 'uniform-current tensions positive')
    CALL require(ABS(fair0 - fair_still)/fair_still > 1.0e-6_wp, 'current enters the static IC fairlead tension')
    CALL require(ABS(fair_last - fair0)/fair0 < 1.0e-3_wp, 'current-loaded held line starts at equilibrium')
  END SUBROUTINE check_dynamic_current_out

  SUBROUTINE check_dynamic_wave_out(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, fair0, anch0, fair_last, anch_last
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open Airy-wave .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    fair0 = 0.0_wp
    anch0 = 0.0_wp
    fair_last = 0.0_wp
    anch_last = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read Airy-wave row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair_last, anch_last
      CALL require(ios == 0, 'parse Airy-wave row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        fair0 = fair_last
        anch0 = anch_last
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == 4, 'Airy-wave .out has t=0 plus three time steps')
    CALL require(fair_last > 0.0_wp .AND. anch_last > 0.0_wp, 'Airy-wave tensions positive')
    CALL require(ABS(fair_last - fair0)/fair0 > 1.0e-8_wp, 'Airy wave changes fairlead tension')
  END SUBROUTINE check_dynamic_wave_out

  SUBROUTINE check_l3_wave_deck_out(path)
    !! End-to-end L3-2 deck validation: the standalone `.dat` driver path must
    !! reproduce the existing WD0050 regular-wave OrcaFlex reference over the
    !! steady last two of six periods.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow, nsteady
    REAL(wp) :: t, fair, anch, mean_n, fmin, fmax, swing_n, mean_err, swing_err
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open L3-2 dynamic deck .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    CALL require(ios == 0, 'read L3-2 dynamic deck status')
    READ (u, '(A)', IOSTAT=ios) buf
    CALL require(ios == 0, 'read L3-2 dynamic deck header')
    nrow = 0
    nsteady = 0
    mean_n = 0.0_wp
    fmin = HUGE(1.0_wp)
    fmax = -HUGE(1.0_wp)
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read L3-2 dynamic deck row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair, anch
      CALL require(ios == 0, 'parse L3-2 dynamic deck row')
      IF (ios /= 0) EXIT
      nrow = nrow + 1
      IF (t >= 32.0_wp - 1.0e-12_wp) THEN
        mean_n = mean_n + fair
        fmin = MIN(fmin, fair)
        fmax = MAX(fmax, fair)
        nsteady = nsteady + 1
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == 961, 'L3-2 deck .out has t=0 plus 960 time steps')
    CALL require(nsteady >= 320, 'L3-2 deck steady window has two periods')
    IF (nsteady <= 0) RETURN
    mean_n = mean_n/REAL(nsteady, wp)
    swing_n = fmax - fmin
    mean_err = ABS(mean_n - ORCA_WAVE_MEAN)/ORCA_WAVE_MEAN
    swing_err = ABS(swing_n - ORCA_WAVE_SWING)/ORCA_WAVE_SWING
    WRITE (*, '(A,F9.3,A,F9.3,A,F7.3,A)') 'Deck L3-2 vs OrcaFlex: mean=', mean_n/1.0e3_wp, &
      ' kN (ref ', ORCA_WAVE_MEAN/1.0e3_wp, ', err ', 100.0_wp*mean_err, '%)'
    WRITE (*, '(A,F9.3,A,F9.3,A,F7.3,A)') '                         swing=', swing_n/1.0e3_wp, &
      ' kN (ref ', ORCA_WAVE_SWING/1.0e3_wp, ', err ', 100.0_wp*swing_err, '%)'
    CALL require(swing_n > 1.0e3_wp, 'L3-2 deck kN-scale wave swing')
    CALL require(mean_err < RTOL, 'L3-2 deck mean within 2% OrcaFlex gate')
    CALL require(swing_err < 0.15_wp, 'L3-2 deck swing within 15% OrcaFlex gate')
  END SUBROUTINE check_l3_wave_deck_out

  SUBROUTINE check_dynamic_motion_out(path)
    !! Prescribed fairlead motion should write all rows and perturb fairlead tension.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, fair0, anch0, fair_last, anch_last, point_z0, point_z_last
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open prescribed-motion .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    fair0 = 0.0_wp
    anch0 = 0.0_wp
    fair_last = 0.0_wp
    anch_last = 0.0_wp
    point_z0 = 0.0_wp
    point_z_last = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read prescribed-motion row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair_last, anch_last, point_z_last
      CALL require(ios == 0, 'parse prescribed-motion row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        fair0 = fair_last
        anch0 = anch_last
        point_z0 = point_z_last
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == 4, 'prescribed-motion .out has t=0 plus three time steps')
    CALL require(fair_last > 0.0_wp .AND. anch_last > 0.0_wp, 'prescribed-motion tensions positive')
    CALL require(ABS(fair_last - fair0)/fair0 > 1.0e-6_wp, 'prescribed motion changes fairlead tension')
    CALL require(ABS(point_z0) < 1.0e-12_wp, 'prescribed Point2pz starts at deck z')
    CALL require(ABS(point_z_last - 0.015_wp) < 1.0e-12_wp, 'prescribed Point2pz follows motionFile state')
  END SUBROUTINE check_dynamic_motion_out

  SUBROUTINE check_dynamic_failure_out(path)
    !! A failed first step leaves only the converged initial state in the
    !! inspection output; the rejected Newton iterate must never be committed.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, fair, anch, point_z
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open non-convergent inspection .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    t = -1.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read non-convergent inspection row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair, anch, point_z
      CALL require(ios == 0, 'parse non-convergent inspection row')
      IF (ios /= 0) EXIT
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 1 .AND. ABS(t) < 1.0e-12_wp, &
                 'non-convergent inspection .out contains only the converged initial state')
  END SUBROUTINE check_dynamic_failure_out

  SUBROUTINE read_motion_last_fair(path, fair_last, ErrStat)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: fair_last
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t, anch, point_z
    CHARACTER(512) :: buf

    fair_last = 0.0_wp
    ErrStat = 1
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
      READ (buf, *, IOSTAT=ios) t, fair_last, anch, point_z
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ErrStat = 0
  END SUBROUTINE read_motion_last_fair

  SUBROUTINE check_dynamic_finite_ei_out(path)
    !! Finite-EI held-end smoke: header + t=0 plus two rows for dtM=0.005/TMax=0.01.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, fair_last, anch_last, node1x, node_end_z, node_end_vz, node_end_ten
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open finite-EI dynamic .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    fair_last = 0.0_wp
    anch_last = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read finite-EI dynamic row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair_last, anch_last, node1x, node_end_z, node_end_vz, node_end_ten
      CALL require(ios == 0, 'parse finite-EI dynamic row')
      nrow = nrow + 1
      IF (nrow == 1) CALL require(ABS(t) < 1.0e-12_wp, 'finite-EI first row at t=0')
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'finite-EI .out has t=0 plus two time steps')
    CALL require(fair_last > 0.0_wp .AND. anch_last > 0.0_wp, 'finite-EI tensions finite positive')
    CALL require(ABS(node1x - 40.0_wp) < 1.0e-10_wp, 'finite-EI fairlead position channel L1N1px')
    CALL require(ABS(node_end_z + 80.0_wp) < 1.0e-8_wp, 'finite-EI anchor position channel L1N6pz')
    CALL require(ABS(node_end_vz) < 1.0e-8_wp, 'finite-EI anchor velocity channel L1N6vz')
    CALL require(ABS(node_end_ten - anch_last)/anch_last < 1.0e-10_wp, 'finite-EI node tension channel Ten1N6')
  END SUBROUTINE check_dynamic_finite_ei_out

  SUBROUTINE check_finite_current_seed_out(path)
    !! The suspended current deck starts from the static equilibrium IN the current (the static
    !! solve carries the steady drag of the line at rest), so the march starts at rest and stays
    !! there: the free interior node (L1N3) neither moves nor accelerates and the line-end
    !! tensions keep their static values over the three steps. A still-water IC would instead
    !! accelerate the node downstream from the first step.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, vx, px, fair, anch, fair0, anch0, vmax
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open finite-EI current-seed .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    CALL require(INDEX(buf, 'production cubic-Hermite route') > 0, &
                 'suspended finite-EI deck selects the production Hermite lifecycle')
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    vmax = 0.0_wp
    fair0 = 0.0_wp
    anch0 = 0.0_wp
    fair = 0.0_wp
    anch = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read finite-EI current-seed row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, vx, px, fair, anch
      CALL require(ios == 0, 'parse finite-EI current-seed row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        CALL require(ABS(t) < 1.0e-12_wp .AND. ABS(vx) < 1.0e-12_wp, &
                     'finite-EI current-seed first row at rest (t=0, vx=0)')
        fair0 = fair
        anch0 = anch
      END IF
      vmax = MAX(vmax, ABS(vx))
    END DO
    CLOSE (u)
    CALL require(nrow == 4, 'finite-EI current-seed .out has t=0 plus three time steps')
    CALL require(fair0 > 0.0_wp .AND. anch0 > 0.0_wp, 'finite-EI current-seed tensions positive')
    CALL require(vmax < 1.0e-6_wp, 'finite-EI line starts at rest in its current (static IC includes the drag)')
    CALL require(ABS(fair - fair0) < 1.0e-6_wp*fair0 .AND. ABS(anch - anch0) < 1.0e-6_wp*anch0, &
                 'finite-EI line-end tensions keep their static values in the current')
  END SUBROUTINE check_finite_current_seed_out

  SUBROUTINE compare_finite_current_seed_out(path_ref, path_mod)
    !! The finite-EI current deck is small enough that full Newton and modified Newton should
    !! converge to the same state. This gates the live current-load tangent used when a finite-EI
    !! environmental load is present; stale or missing tangent terms show up as response drift.
    CHARACTER(*), INTENT(IN) :: path_ref, path_mod
    REAL(wp) :: ref(4), modn(4), scale
    INTEGER :: es

    CALL read_finite_current_seed_last(path_ref, ref, es)
    CALL require(es == 0, 'read finite-EI current-seed full-Newton final row')
    CALL read_finite_current_seed_last(path_mod, modn, es)
    CALL require(es == 0, 'read finite-EI current-seed modified-Newton final row')
    scale = MAX(1.0_wp, nan_max_abs(ref))
    CALL require(nan_max_abs(ref - modn)/scale < 5.0e-9_wp, &
                 'finite-EI current modified-Newton response matches full Newton')
  END SUBROUTINE compare_finite_current_seed_out

  SUBROUTINE read_finite_current_seed_last(path, values, ErrStat)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: values(4)
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t
    CHARACTER(512) :: buf

    ErrStat = 1
    values = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    IF (ios /= 0) THEN
      CLOSE (u)
      RETURN
    END IF
    READ (u, '(A)', IOSTAT=ios) buf
    IF (ios /= 0) THEN
      CLOSE (u)
      RETURN
    END IF
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
      READ (buf, *, IOSTAT=ios) t, values(1), values(2), values(3), values(4)
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ErrStat = 0
  END SUBROUTINE read_finite_current_seed_last

  SUBROUTINE check_dynamic_finite_motion_out(path)
    !! Finite-EI prescribed-motion smoke: Point and fairlead node follow motionFile.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, point_z, node_z, node_vz, node_az, fair_last, anch_last
    REAL(wp) :: point_z0, node_z0, node_vz0, node_az0, fair0
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open finite-EI prescribed-motion .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    point_z0 = 0.0_wp
    node_z0 = 0.0_wp
    node_vz0 = 0.0_wp
    node_az0 = 0.0_wp
    fair0 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read finite-EI prescribed-motion row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, point_z, node_z, node_vz, node_az, fair_last, anch_last
      CALL require(ios == 0, 'parse finite-EI prescribed-motion row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        point_z0 = point_z
        node_z0 = node_z
        node_vz0 = node_vz
        node_az0 = node_az
        fair0 = fair_last
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == 4, 'finite-EI prescribed-motion .out has t=0 plus three time steps')
    CALL require(ABS(point_z0 + 19.999_wp) < 1.0e-12_wp, 'finite-EI prescribed Point2pz starts at motion row 1')
    CALL require(ABS(node_z0 - point_z0) < 1.0e-12_wp, 'finite-EI initial fairlead position follows motion row 1')
    CALL require(ABS(node_vz0 - 0.1_wp) < 1.0e-12_wp, 'finite-EI initial fairlead velocity follows motion row 1')
    CALL require(ABS(node_az0 - 0.05_wp) < 1.0e-12_wp, 'finite-EI initial fairlead acceleration follows motion row 1')
    CALL require(ABS(point_z + 19.985_wp) < 1.0e-12_wp, 'finite-EI prescribed Point2pz follows motionFile')
    CALL require(ABS(node_z - point_z) < 1.0e-12_wp, 'finite-EI fairlead node follows motionFile position')
    CALL require(ABS(node_vz - 0.5_wp) < 1.0e-12_wp, 'finite-EI fairlead node follows motionFile velocity')
    CALL require(fair_last > 0.0_wp .AND. anch_last > 0.0_wp, 'finite-EI prescribed tensions positive')
    CALL require(ABS(fair_last - fair0)/fair0 > 1.0e-8_wp, 'finite-EI prescribed motion changes tension')
  END SUBROUTINE check_dynamic_finite_motion_out

  SUBROUTINE read_finite_friction_out(path, point_x, node_x, fair_last, anch_last)
    !! Read the final row of the finite-EI touchdown-friction deck.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: point_x, node_x, fair_last, anch_last
    INTEGER :: u, ios, nrow
    REAL(wp) :: t
    CHARACTER(512) :: buf

    point_x = 0.0_wp
    node_x = 0.0_wp
    fair_last = 0.0_wp
    anch_last = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open finite-EI friction .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read finite-EI friction row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, point_x, node_x, fair_last, anch_last
      CALL require(ios == 0, 'parse finite-EI friction row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 4, 'finite-EI friction .out has t=0 plus three time steps')
  END SUBROUTINE read_finite_friction_out

  SUBROUTINE check_dynamic_finite_ei_lazy_wave_out(path, end_node, mid_lift_min, expected_rows)
    !! Lazy-wave finite-EI smoke: midpoint is lifted by the Hermite arch seed.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN), OPTIONAL :: end_node
    REAL(wp), INTENT(IN), OPTIONAL :: mid_lift_min
    INTEGER, INTENT(IN), OPTIONAL :: expected_rows
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, fair_last, anch_last, node1x, mid_z, node_end_z, node_end_vz, node_end_ten
    REAL(wp) :: mid_z0, lift_min
    INTEGER :: last_node, nrow_expected
    CHARACTER(512) :: buf

    last_node = 6
    IF (PRESENT(end_node)) last_node = end_node
    lift_min = -52.0_wp
    IF (PRESENT(mid_lift_min)) lift_min = mid_lift_min
    nrow_expected = 3
    IF (PRESENT(expected_rows)) nrow_expected = expected_rows
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open finite-EI lazy-wave dynamic .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    fair_last = 0.0_wp
    anch_last = 0.0_wp
    mid_z0 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read finite-EI lazy-wave dynamic row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, fair_last, anch_last, node1x, mid_z, node_end_z, node_end_vz, node_end_ten
      CALL require(ios == 0, 'parse finite-EI lazy-wave dynamic row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        mid_z0 = mid_z
        CALL require(ABS(t) < 1.0e-12_wp, 'finite-EI lazy-wave first row at t=0')
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == nrow_expected, 'finite-EI lazy-wave .out has expected row count')
    CALL require(fair_last > 0.0_wp .AND. anch_last > 0.0_wp, 'finite-EI lazy-wave tensions finite positive')
    CALL require(ABS(node1x - 40.0_wp) < 1.0e-10_wp, 'finite-EI lazy-wave fairlead position channel L1N1px')
    CALL require(ABS(node_end_z + 80.0_wp) < 1.0e-8_wp, 'finite-EI lazy-wave anchor position channel')
    CALL require(mid_z0 > lift_min, 'finite-EI lazy-wave midpoint starts on a lifted arch')
    CALL require(ABS(node_end_vz) < 1.0e-8_wp, 'finite-EI lazy-wave anchor velocity channel')
    CALL require(ABS(node_end_ten - anch_last)/anch_last < 1.0e-10_wp, &
                 'finite-EI lazy-wave node tension channel')
  END SUBROUTINE check_dynamic_finite_ei_lazy_wave_out

  SUBROUTINE check_static_line_output_files(pos_path, ten_path)
    !! Static LINE Outputs p/t files follow public EndA -> EndB order.
    CHARACTER(*), INTENT(IN) :: pos_path, ten_path
    INTEGER :: u, ios, nrow, idx
    REAL(wp) :: x, y, z, ten, ten_first, ten_last
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=pos_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open static line position output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read static line position row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) idx, x, y, z
      CALL require(ios == 0, 'parse static line position row')
      nrow = nrow + 1
      IF (nrow == 1) THEN
        CALL require(idx == 1 .AND. ABS(x) < 1.0e-12_wp .AND. ABS(y) < 1.0e-12_wp .AND. &
                     ABS(z) < 1.0e-12_wp, 'line position file starts at End A fairlead')
      END IF
    END DO
    CLOSE (u)
    CALL require(nrow == 42, 'static line position file has NumSegs+1 rows')
    CALL require(idx == 42 .AND. ABS(x - 400.0_wp) < 1.0e-12_wp .AND. ABS(y) < 1.0e-12_wp .AND. &
                 ABS(z + 50.0_wp) < 1.0e-12_wp, 'line position file ends at End B anchor')

    OPEN (NEWUNIT=u, FILE=ten_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open static line tension output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    ten_first = 0.0_wp
    ten_last = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read static line tension row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) idx, ten
      CALL require(ios == 0, 'parse static line tension row')
      nrow = nrow + 1
      IF (nrow == 1) ten_first = ten
      ten_last = ten
    END DO
    CLOSE (u)
    CALL require(nrow == 41, 'static line tension file has NumSegs rows')
    CALL require(ten_first > ten_last .AND. ten_last > 0.0_wp, 'line tension file follows EndA-to-EndB order')
  END SUBROUTINE check_static_line_output_files

  SUBROUTINE check_dynamic_line_output_files(pos_path, ten_path)
    !! Dynamic LINE Outputs p/t files are time-series rows in public EndA -> EndB order.
    CHARACTER(*), INTENT(IN) :: pos_path, ten_path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, x1, y1, z1, x42, y42, z42
    REAL(wp) :: ten1, ten41, first_t, last_t
    REAL(wp) :: pos(126), ten(41)
    CHARACTER(8192) :: buf

    x1 = 0.0_wp; y1 = 0.0_wp; z1 = 0.0_wp
    x42 = 0.0_wp; y42 = 0.0_wp; z42 = 0.0_wp
    ten1 = 0.0_wp; ten41 = 0.0_wp
    pos = 0.0_wp
    ten = 0.0_wp
    OPEN (NEWUNIT=u, FILE=pos_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic line position output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    first_t = 0.0_wp
    last_t = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic line position row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, pos
      CALL require(ios == 0, 'parse dynamic line position row')
      nrow = nrow + 1
      x1 = pos(1); y1 = pos(2); z1 = pos(3)
      x42 = pos(124); y42 = pos(125); z42 = pos(126)
      IF (nrow == 1) first_t = t
      last_t = t
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic line position file has t=0 plus two time steps')
    CALL require(ABS(first_t) < 1.0e-12_wp .AND. ABS(last_t - 0.02_wp) < 1.0e-12_wp, &
                 'dynamic line position file time span')
    CALL require(ABS(x1) < 1.0e-10_wp .AND. ABS(y1) < 1.0e-10_wp .AND. ABS(z1) < 1.0e-10_wp, &
                 'dynamic line position row starts at End A fairlead')
    CALL require(ABS(x42 - 400.0_wp) < 1.0e-8_wp .AND. ABS(y42) < 1.0e-10_wp .AND. &
                 ABS(z42 + 50.0_wp) < 1.0e-8_wp, 'dynamic line position row ends at End B anchor')

    OPEN (NEWUNIT=u, FILE=ten_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic line tension output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    ten1 = 0.0_wp
    ten41 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic line tension row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, ten
      CALL require(ios == 0, 'parse dynamic line tension row')
      nrow = nrow + 1
      ten1 = ten(1)
      ten41 = ten(41)
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic line tension file has t=0 plus two time steps')
    CALL require(ten1 > ten41 .AND. ten41 > 0.0_wp, 'dynamic line tension file follows EndA-to-EndB order')
  END SUBROUTINE check_dynamic_line_output_files

  SUBROUTINE check_dynamic_finite_line_output_files(pos_path, ten_path, expected_rows, &
                                                    expected_end_time, expected_end_a_z)
    !! Finite-EI dynamic LINE Outputs p/t files are time-series rows in public EndA -> EndB order.
    CHARACTER(*), INTENT(IN) :: pos_path, ten_path
    INTEGER, INTENT(IN), OPTIONAL :: expected_rows
    REAL(wp), INTENT(IN), OPTIONAL :: expected_end_time, expected_end_a_z
    INTEGER :: u, ios, nrow
    INTEGER :: nrow_expected
    REAL(wp) :: t, x1, y1, z1, x6, y6, z6
    REAL(wp) :: first_t, last_t, end_time_expected, end_a_z_expected
    REAL(wp) :: pos(18), ten(5)
    CHARACTER(1024) :: buf

    nrow_expected = 3
    end_time_expected = 0.01_wp
    end_a_z_expected = -20.0_wp
    IF (PRESENT(expected_rows)) nrow_expected = expected_rows
    IF (PRESENT(expected_end_time)) end_time_expected = expected_end_time
    IF (PRESENT(expected_end_a_z)) end_a_z_expected = expected_end_a_z
    x1 = 0.0_wp; y1 = 0.0_wp; z1 = 0.0_wp
    x6 = 0.0_wp; y6 = 0.0_wp; z6 = 0.0_wp
    pos = 0.0_wp
    ten = 0.0_wp
    OPEN (NEWUNIT=u, FILE=pos_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open finite-EI dynamic line position output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    first_t = 0.0_wp
    last_t = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read finite-EI dynamic line position row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, pos
      CALL require(ios == 0, 'parse finite-EI dynamic line position row')
      nrow = nrow + 1
      x1 = pos(1); y1 = pos(2); z1 = pos(3)
      x6 = pos(16); y6 = pos(17); z6 = pos(18)
      IF (nrow == 1) first_t = t
      last_t = t
    END DO
    CLOSE (u)
    CALL require(nrow == nrow_expected, 'finite-EI dynamic line position file row count')
    CALL require(ABS(first_t) < 1.0e-12_wp .AND. ABS(last_t - end_time_expected) < 1.0e-12_wp, &
                 'finite-EI dynamic line position file time span')
    CALL require(ABS(x1 - 40.0_wp) < 1.0e-8_wp .AND. ABS(y1) < 1.0e-10_wp .AND. &
                 ABS(z1 - end_a_z_expected) < 1.0e-8_wp, &
                 'finite-EI dynamic line position starts at current End A fairlead')
    CALL require(ABS(x6) < 1.0e-8_wp .AND. ABS(y6) < 1.0e-10_wp .AND. ABS(z6 + 80.0_wp) < 1.0e-8_wp, &
                 'finite-EI dynamic line position ends at End B anchor')

    OPEN (NEWUNIT=u, FILE=ten_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open finite-EI dynamic line tension output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read finite-EI dynamic line tension row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, ten
      CALL require(ios == 0, 'parse finite-EI dynamic line tension row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == nrow_expected, 'finite-EI dynamic line tension file row count')
    CALL require(nan_max_abs(ten) > 1.0_wp, 'finite-EI dynamic line tension file contains active segment tensions')
  END SUBROUTINE check_dynamic_finite_line_output_files

  SUBROUTINE check_dynamic_connect_line_output_files(pos_path, ten_path)
    !! Dynamic point-system LINE Outputs p/t files expose the current system-owned line state.
    CHARACTER(*), INTENT(IN) :: pos_path, ten_path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, x1, y1, z1, x2, y2, z2, ten1, first_t, last_t
    REAL(wp) :: pos(6), ten(1)
    CHARACTER(512) :: buf

    x1 = 0.0_wp; y1 = 0.0_wp; z1 = 0.0_wp
    x2 = 0.0_wp; y2 = 0.0_wp; z2 = 0.0_wp
    ten1 = 0.0_wp
    pos = 0.0_wp
    ten = 0.0_wp
    OPEN (NEWUNIT=u, FILE=pos_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Connect line position output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    first_t = 0.0_wp
    last_t = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Connect line position row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, pos
      CALL require(ios == 0, 'parse dynamic Connect line position row')
      nrow = nrow + 1
      x1 = pos(1); y1 = pos(2); z1 = pos(3)
      x2 = pos(4); y2 = pos(5); z2 = pos(6)
      IF (nrow == 1) first_t = t
      last_t = t
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic Connect line position file has t=0 plus two time steps')
    CALL require(ABS(first_t) < 1.0e-12_wp .AND. ABS(last_t - 0.01_wp) < 1.0e-12_wp, &
                 'dynamic Connect line position file time span')
    CALL require(ABS(x1 - 1.0_wp) < 1.0e-10_wp .AND. ABS(y1) < 1.0e-10_wp .AND. z1 < 0.0_wp, &
                 'dynamic Connect line position row starts at moving End A point')
    CALL require(ABS(x2) < 1.0e-10_wp .AND. ABS(y2) < 1.0e-10_wp .AND. ABS(z2) < 1.0e-10_wp, &
                 'dynamic Connect line position row ends at fixed End B point')

    OPEN (NEWUNIT=u, FILE=ten_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Connect line tension output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Connect line tension row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, ten
      CALL require(ios == 0, 'parse dynamic Connect line tension row')
      nrow = nrow + 1
      ten1 = ten(1)
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic Connect line tension file has t=0 plus two time steps')
    CALL require(ten1 > 0.0_wp, 'dynamic Connect line tension output is positive')
  END SUBROUTINE check_dynamic_connect_line_output_files

  SUBROUTINE check_dynamic_object_line_output_files(pos_path, ten_path, slack)
    !! Dynamic object-graph LINE Outputs p/t files expose live system-owned one-segment line states.
    !! slack: the rig's line is genuinely slack, so the tension gate asserts the TENSION-ONLY
    !! readout (clamped zero, never compression) instead of nonzero activity.
    CHARACTER(*), INTENT(IN) :: pos_path, ten_path
    LOGICAL, INTENT(IN), OPTIONAL :: slack
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, first_t, last_t, sep2, ten1
    REAL(wp) :: pos(6), ten(1)
    LOGICAL :: is_slack
    CHARACTER(512) :: buf

    pos = 0.0_wp
    ten = 0.0_wp
    OPEN (NEWUNIT=u, FILE=pos_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic object-graph line position output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    first_t = 0.0_wp
    last_t = 0.0_wp
    sep2 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic object-graph line position row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, pos
      CALL require(ios == 0, 'parse dynamic object-graph line position row')
      nrow = nrow + 1
      IF (nrow == 1) first_t = t
      last_t = t
      sep2 = (pos(1) - pos(4))**2 + (pos(2) - pos(5))**2 + (pos(3) - pos(6))**2
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic object-graph line position file has t=0 plus two time steps')
    CALL require(ABS(first_t) < 1.0e-12_wp .AND. ABS(last_t - 0.01_wp) < 1.0e-12_wp, &
                 'dynamic object-graph line position file time span')
    CALL require(sep2 > 1.0e-8_wp, 'dynamic object-graph line output keeps distinct EndA/EndB nodes')

    OPEN (NEWUNIT=u, FILE=ten_path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic object-graph line tension output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    ten1 = 0.0_wp
    is_slack = .FALSE.
    IF (PRESENT(slack)) is_slack = slack
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic object-graph line tension row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, ten
      CALL require(ios == 0, 'parse dynamic object-graph line tension row')
      nrow = nrow + 1
      ten1 = ten(1)
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic object-graph line tension file has t=0 plus two time steps')
    IF (is_slack) THEN
      ! a slack line under TENSION-ONLY dynamics reports exactly zero, never a compression
      ! (a +/-EA readout would print one); the tension-only readout check on the one slack
      ! rig in the deck battery
      CALL require(ten1 >= 0.0_wp .AND. ten1 <= 1.0e-6_wp, &
                   'slack object-graph line reports clamped (tension-only) zero, not compression')
    ELSE
      CALL require(ABS(ten1) > 1.0_wp, 'dynamic object-graph line tension output is active')
    END IF
  END SUBROUTINE check_dynamic_object_line_output_files

  SUBROUTINE check_dynamic_connect_out(path)
    !! Dynamic Connect smoke: two lines share a massive internal point.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, ten1, ten2, z_shared, vz_shared
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Connect .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    z_shared = 0.0_wp
    vz_shared = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Connect row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, ten1, ten2, z_shared, vz_shared
      CALL require(ios == 0, 'parse dynamic Connect row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic Connect .out has t=0 plus two time steps')
    CALL require(ten1 > 0.0_wp .AND. ten2 > 0.0_wp, 'dynamic Connect tensions positive')
    ! a Connect point that starts at its static balance stays at rest in the monolithic step (the
    ! staggered explicit point update set it moving); the row only needs a finite dynamic state
    CALL require(z_shared < 0.0_wp .AND. ABS(vz_shared) < HUGE(1.0_wp), 'dynamic Connect point state is finite')
  END SUBROUTINE check_dynamic_connect_out

  SUBROUTINE read_dynamic_connect_out(path, ten1, ten2, z_shared, vz_shared, ErrStat)
    !! Read the final row of the dynamic Connect deck.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: ten1, ten2, z_shared, vz_shared
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t
    CHARACTER(512) :: buf

    ErrStat = 1
    ten1 = 0.0_wp
    ten2 = 0.0_wp
    z_shared = 0.0_wp
    vz_shared = 0.0_wp
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
      READ (buf, *, IOSTAT=ios) t, ten1, ten2, z_shared, vz_shared
      IF (ios /= 0) THEN
        CLOSE (u)
        RETURN
      END IF
    END DO
    CLOSE (u)
    ErrStat = 0
  END SUBROUTINE read_dynamic_connect_out

  SUBROUTINE check_dynamic_connect_current_out(path)
    !! Dynamic Connect point with lumped current drag moves in the current direction.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, x_shared, vx_shared
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Connect-current .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    x_shared = 0.0_wp
    vx_shared = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Connect-current row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, x_shared, vx_shared
      CALL require(ios == 0, 'parse dynamic Connect-current row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic Connect-current .out has t=0 plus two time steps')
    ! The current drag is in the static initial condition: the point starts displaced
    ! downstream of its symmetric no-current position x = 1 m (by drag/stiffness, ~6.6 mm)
    ! and stays at rest there.
    CALL require(x_shared > 1.001_wp .AND. ABS(vx_shared) < 1.0e-3_wp, &
                 'Connect current drag displaces the static point in +x and it starts at rest')
  END SUBROUTINE check_dynamic_connect_current_out

  SUBROUTINE check_dynamic_point3_body_out(path)
    !! Dynamic Point3 body maps through the point-system deck path.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, x_body, vx_body, x_point
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Point3 BODY .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    x_body = 0.0_wp
    vx_body = 0.0_wp
    x_point = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Point3 BODY row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, x_body, vx_body, x_point
      CALL require(ios == 0, 'parse dynamic Point3 BODY row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic Point3 BODY .out has t=0 plus two time steps')
    CALL require(x_body > 1.0_wp .AND. vx_body > 0.0_wp, 'dynamic Point3 BODY moves under current drag')
    CALL require(ABS(x_point - x_body) < 1.0e-12_wp, 'dynamic Point channel reports live system point state')
  END SUBROUTINE check_dynamic_point3_body_out

  SUBROUTINE check_dynamic_body_wave_out(path, label)
    !! Body wave coupling moves the body-owned line endpoint and keeps Point output live.
    CHARACTER(*), INTENT(IN) :: path, label
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, x_body, vx_body, x_point
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open '//TRIM(label)//' .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    x_body = 1.0_wp
    vx_body = 0.0_wp
    x_point = 1.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read '//TRIM(label)//' row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, x_body, vx_body, x_point
      CALL require(ios == 0, 'parse '//TRIM(label)//' row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 3, TRIM(label)//' .out has t=0 plus two time steps')
    CALL require(ABS(x_body - 1.0_wp) > 1.0e-10_wp .OR. ABS(vx_body) > 1.0e-10_wp, &
                 TRIM(label)//' moves under wave load')
    CALL require(ABS(x_point - x_body) < 1.0e-12_wp, TRIM(label)//' Point channel is live')
  END SUBROUTINE check_dynamic_body_wave_out

  SUBROUTINE check_dynamic_rigid6_body_out(path)
    !! Dynamic Rigid6 body maps offset attachment motion into the system point output.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, z_line, z_point
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Rigid6 BODY .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    z_line = 0.0_wp
    z_point = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Rigid6 BODY row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, z_line, z_point
      CALL require(ios == 0, 'parse dynamic Rigid6 BODY row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic Rigid6 BODY .out has t=0 plus two time steps')
    CALL require(ABS(z_line) > 1.0e-10_wp, 'dynamic Rigid6 BODY attachment moves under line load')
    CALL require(ABS(z_point - z_line) < 1.0e-12_wp, 'dynamic Rigid6 Point channel reports live state')
  END SUBROUTINE check_dynamic_rigid6_body_out

  SUBROUTINE read_dynamic_rigid6_point_z(path, point_z, ErrStat)
    !! Read the last Rigid6 Point<N>z channel from a two-column Rigid6 body deck.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: point_z
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t, z_line
    CHARACTER(512) :: buf

    point_z = 0.0_wp
    ErrStat = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      ErrStat = ios
      RETURN
    END IF
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        ErrStat = ios
        EXIT
      END IF
      READ (buf, *, IOSTAT=ios) t, z_line, point_z
      IF (ios /= 0) THEN
        ErrStat = ios
        EXIT
      END IF
    END DO
    CLOSE (u)
  END SUBROUTINE read_dynamic_rigid6_point_z

  SUBROUTINE read_dynamic_rigid6_first_step_z(path, point_z, ErrStat)
    !! Read the first post-initial Rigid6 Point<N>z value from a two-column deck.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: point_z
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    REAL(wp) :: t, z_line
    CHARACTER(512) :: buf

    point_z = 0.0_wp
    ErrStat = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      ErrStat = ios
      RETURN
    END IF
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    IF (ios == 0) READ (u, '(A)', IOSTAT=ios) buf
    IF (ios == 0) READ (buf, *, IOSTAT=ios) t, z_line, point_z
    IF (ios /= 0) ErrStat = ios
    CLOSE (u)
  END SUBROUTINE read_dynamic_rigid6_first_step_z

  SUBROUTINE check_dynamic_rigid6_rotation_out(path)
    !! Two offset Body<N> attachments stay rigid while asymmetric line loads rotate the body.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, p3(3), p4(3), rel(3), length
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Rigid6 rotation .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    p3 = [0.0_wp, 1.0_wp, 0.0_wp]
    p4 = [0.0_wp, -1.0_wp, 0.0_wp]
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Rigid6 rotation row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, p3(1), p3(2), p3(3), p4(1), p4(2), p4(3)
      CALL require(ios == 0, 'parse dynamic Rigid6 rotation row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    rel = p3 - p4
    length = SQRT(SUM(rel*rel))
    CALL require(nrow == 3, 'dynamic Rigid6 rotation .out has t=0 plus two time steps')
    CALL require(ABS(length - 2.0_wp) < 1.0e-8_wp, 'dynamic Rigid6 attachment distance remains rigid')
    CALL require(ABS(rel(1)) > 1.0e-10_wp .OR. ABS(rel(3)) > 1.0e-10_wp, &
                 'dynamic Rigid6 asymmetric line loads rotate body')
  END SUBROUTINE check_dynamic_rigid6_rotation_out

  SUBROUTINE check_dynamic_rigid6_current_out(path)
    !! Rigid6 body accepts uniform-current lumped body drag.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    REAL(wp) :: t, x_body, vx_body, x_point
    CHARACTER(512) :: buf

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic Rigid6-current .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    x_body = 0.0_wp
    vx_body = 0.0_wp
    x_point = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic Rigid6-current row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, x_body, vx_body, x_point
      CALL require(ios == 0, 'parse dynamic Rigid6-current row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic Rigid6-current .out has t=0 plus two time steps')
    CALL require(x_body > 1.0_wp .AND. vx_body > 0.0_wp, 'dynamic Rigid6 current drag moves body in +x')
    CALL require(ABS(x_point - x_body) < 1.0e-12_wp, 'dynamic Rigid6-current Point channel is live')
  END SUBROUTINE check_dynamic_rigid6_current_out

  SUBROUTINE check_dynamic_rigid6_motion_out(path)
    !! Prescribed Rigid6 translational motion updates Body<N> point channels exactly.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    CHARACTER(512) :: buf
    REAL(wp) :: t, x_line, x_point, z_point

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic prescribed Rigid6 .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    t = 0.0_wp
    x_line = 0.0_wp
    x_point = 0.0_wp
    z_point = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic prescribed Rigid6 row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, x_line, x_point, z_point
      CALL require(ios == 0, 'parse dynamic prescribed Rigid6 row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 3, 'dynamic prescribed Rigid6 .out has t=0 plus two time steps')
    CALL require(ABS(t - 0.01_wp) < 1.0e-12_wp, 'dynamic prescribed Rigid6 final time')
    CALL require(ABS(x_point - 0.02_wp) < 1.0e-12_wp, 'dynamic prescribed Rigid6 Point channel follows motionFile')
    CALL require(ABS(z_point) < 1.0e-12_wp, 'dynamic prescribed Rigid6 fixed-offset z remains exact')
    CALL require(ABS(x_line - x_point) < 1.0e-12_wp, 'dynamic prescribed Rigid6 line endpoint follows Body point')
  END SUBROUTINE check_dynamic_rigid6_motion_out

  SUBROUTINE check_dynamic_rod_out(path)
    !! Rod<N>A/B attachments move as a rigid pair under endpoint line loads.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    CHARACTER(256) :: buf
    REAL(wp) :: t, xa, za, xb, zb, length

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic ROD .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    xa = 0.0_wp
    za = -2.0_wp
    xb = 0.0_wp
    zb = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic ROD row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, xa, za, xb, zb
      CALL require(ios == 0, 'parse dynamic ROD row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    length = SQRT((xb - xa)**2 + (zb - za)**2)
    CALL require(nrow == 3, 'dynamic ROD .out has t=0 plus two time steps')
    CALL require(ABS(xa) > 1.0e-10_wp .OR. ABS(xb) > 1.0e-10_wp .OR. &
                 ABS(za + 2.0_wp) > 1.0e-10_wp .OR. ABS(zb) > 1.0e-10_wp, &
                 'dynamic ROD moves under line/body/hydro loads')
    CALL require(ABS(xb - xa) > 1.0e-10_wp, 'dynamic ROD distributed hydro creates rotation')
    ! the .out carries 8 significant digits (5e-8 m on a 2 m coordinate), which bounds how
    ! tightly a length rebuilt from printed endpoints can match the rigid 2 m
    CALL require(ABS(length - 2.0_wp) < 5.0e-7_wp, 'dynamic ROD endpoint distance remains rigid')
  END SUBROUTINE check_dynamic_rod_out

  SUBROUTINE check_dynamic_rod_position_output_file(path)
    !! Dynamic ROD Outputs p writes live EndA/EndB endpoint positions.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    CHARACTER(512) :: buf
    REAL(wp) :: t, first_t, last_t, xa, ya, za, xb, yb, zb, length

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic ROD position output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    first_t = 0.0_wp
    last_t = 0.0_wp
    t = 0.0_wp
    xa = 0.0_wp; ya = 0.0_wp; za = -2.0_wp
    xb = 0.0_wp; yb = 0.0_wp; zb = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic ROD position row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, xa, ya, za, xb, yb, zb
      CALL require(ios == 0, 'parse dynamic ROD position row')
      nrow = nrow + 1
      IF (nrow == 1) first_t = t
      last_t = t
    END DO
    CLOSE (u)
    length = SQRT((xb - xa)**2 + (yb - ya)**2 + (zb - za)**2)
    CALL require(nrow == 3, 'dynamic ROD position output has t=0 plus two time steps')
    CALL require(ABS(first_t) < 1.0e-12_wp .AND. ABS(last_t - 0.01_wp) < 1.0e-12_wp, &
                 'dynamic ROD position output time span')
    ! printed endpoints carry 8 significant digits (see the .out rigid-length check)
    CALL require(ABS(length - 2.0_wp) < 5.0e-7_wp, 'dynamic ROD position output keeps rigid length')
    CALL require(ABS(xa) > 1.0e-10_wp .OR. ABS(xb) > 1.0e-10_wp .OR. &
                 ABS(za + 2.0_wp) > 1.0e-10_wp .OR. ABS(zb) > 1.0e-10_wp, &
                 'dynamic ROD position output follows live rod state')
  END SUBROUTINE check_dynamic_rod_position_output_file

  SUBROUTINE check_dynamic_prescribed_rod_position_output_file(path)
    !! A prescribed ROD position file follows the motion-file endpoints exactly.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    CHARACTER(512) :: buf
    REAL(wp) :: t, xa, ya, za, xb, yb, zb, length

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic prescribed ROD position output')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    xa = 0.0_wp; ya = 0.0_wp; za = -2.0_wp
    xb = 0.0_wp; yb = 0.0_wp; zb = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic prescribed ROD position row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, xa, ya, za, xb, yb, zb
      CALL require(ios == 0, 'parse dynamic prescribed ROD position row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    length = SQRT((xb - xa)**2 + (yb - ya)**2 + (zb - za)**2)
    CALL require(nrow == 3, 'dynamic prescribed ROD position output has t=0 plus two time steps')
    CALL require(ABS(t - 0.01_wp) < 1.0e-12_wp, 'dynamic prescribed ROD final time')
    CALL require(ABS(xa - 0.02_wp) < 1.0e-12_wp .AND. ABS(xb - 0.02_wp) < 1.0e-12_wp, &
                 'dynamic prescribed ROD final translation follows motionFile')
    CALL require(ABS(za + 2.0_wp) < 1.0e-12_wp .AND. ABS(zb) < 1.0e-12_wp, &
                 'dynamic prescribed ROD final vertical endpoints follow motionFile')
    CALL require(ABS(length - 2.0_wp) < 1.0e-12_wp, 'dynamic prescribed ROD output preserves rigid length')
  END SUBROUTINE check_dynamic_prescribed_rod_position_output_file

  SUBROUTINE read_dynamic_rod_z(path, za, zb, ErrStat)
    !! Read the last Rod<N>A/B z coordinates from the standard rod deck output.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: za, zb
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    CHARACTER(256) :: buf
    REAL(wp) :: t, xa, xb

    za = 0.0_wp
    zb = 0.0_wp
    ErrStat = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      ErrStat = ios
      RETURN
    END IF
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      IF (ios /= 0) THEN
        ErrStat = ios
        EXIT
      END IF
      READ (buf, *, IOSTAT=ios) t, xa, za, xb, zb
      IF (ios /= 0) THEN
        ErrStat = ios
        EXIT
      END IF
    END DO
    CLOSE (u)
  END SUBROUTINE read_dynamic_rod_z

  SUBROUTINE check_dynamic_fixed_rod_out(path)
    !! Fixed Rod<N>A/B attachments stay held while the attached lines march.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow
    CHARACTER(256) :: buf
    REAL(wp) :: t, xa, za, xb, zb, length

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open dynamic fixed ROD .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    xa = 0.0_wp
    za = -2.0_wp
    xb = 0.0_wp
    zb = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read dynamic fixed ROD row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, xa, za, xb, zb
      CALL require(ios == 0, 'parse dynamic fixed ROD row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    length = SQRT((xb - xa)**2 + (zb - za)**2)
    CALL require(nrow == 3, 'dynamic fixed ROD .out has t=0 plus two time steps')
    CALL require(ABS(xa) < 1.0e-12_wp .AND. ABS(za + 2.0_wp) < 1.0e-12_wp, &
                 'fixed ROD End A remains held')
    CALL require(ABS(xb) < 1.0e-12_wp .AND. ABS(zb) < 1.0e-12_wp, 'fixed ROD End B remains held')
    CALL require(ABS(length - 2.0_wp) < 1.0e-12_wp, 'fixed ROD endpoint distance remains rigid')
  END SUBROUTINE check_dynamic_fixed_rod_out

  SUBROUTINE write_single_deck(path, motion_selector, prior_motion_selector)
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(IN), OPTIONAL :: motion_selector
    CHARACTER(*), INTENT(IN), OPTIONAL :: prior_motion_selector
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 single-section chain'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    IF (PRESENT(prior_motion_selector)) WRITE (u, '(A)') TRIM(prior_motion_selector)//' motionFile'
    IF (PRESENT(motion_selector)) WRITE (u, '(A)') TRIM(motion_selector)//' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    ! OpenFAST-style output lists use one quoted channel per row. List-directed
    ! character input removes the quotes; this production-facing form must stay
    ! bit-identical to the legacy unquoted/multi-channel rows used by other gates.
    WRITE (u, '(A)') '"FairTen1"'
    WRITE (u, '(A)') '"AnchTen1"'
    WRITE (u, '(A)') '"L1N1px"'
    WRITE (u, '(A)') '"L1N42pz"'
    WRITE (u, '(A)') '"Ten1N42"'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_single_deck

  SUBROUTINE write_line_outputs_deck(path)
    !! WD0050 static deck with LINE Outputs "pt" for dedicated line files.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create static line-output deck')
    WRITE (u, '(A)') 'WD0050 static line-output chain'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 pt'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_line_outputs_deck

  SUBROUTINE write_dynamic_line_outputs_deck(path)
    !! Dynamic EI=0 per-line files write time-series rows.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic line-output deck')
    WRITE (u, '(A)') 'WD0050 dynamic line-output deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 pt'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.02 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_line_outputs_deck

  SUBROUTINE write_bathymetry_file(path, depth)
    !! Minimal complete 2x2 structured bathymetry grid: rows are x y positive-depth.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: depth
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create bathymetry file')
    WRITE (u, '(3(ES22.14,1X))') - 10.0_wp, -10.0_wp, depth
    WRITE (u, '(3(ES22.14,1X))') 410.0_wp, -10.0_wp, depth
    WRITE (u, '(3(ES22.14,1X))') - 10.0_wp, 10.0_wp, depth
    WRITE (u, '(3(ES22.14,1X))') 410.0_wp, 10.0_wp, depth
    CLOSE (u)
  END SUBROUTINE write_bathymetry_file

  SUBROUTINE write_sloped_bathymetry_file(path, depth_left, depth_right)
    !! A planar x-slope exercises the bathymetry-gradient chain in the Hermite contact tangent.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: depth_left, depth_right
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create sloped bathymetry file')
    WRITE (u, '(3(ES22.14,1X))') - 10.0_wp, -10.0_wp, depth_left
    WRITE (u, '(3(ES22.14,1X))') 410.0_wp, -10.0_wp, depth_right
    WRITE (u, '(3(ES22.14,1X))') - 10.0_wp, 10.0_wp, depth_left
    WRITE (u, '(3(ES22.14,1X))') 410.0_wp, 10.0_wp, depth_right
    CLOSE (u)
  END SUBROUTINE write_sloped_bathymetry_file

  SUBROUTINE write_bathymetry_deck(path, bathy_path)
    !! Same physical WD0050 deck as write_single_deck, but the seabed is provided by
    !! bathymetryFile instead of WtrDpth. Constant depth must match the flat solve.
    CHARACTER(*), INTENT(IN) :: path, bathy_path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create bathymetry deck')
    WRITE (u, '(A)') 'WD0050 static structured-bathymetry chain'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(bathy_path)//' bathymetryFile'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_bathymetry_deck

  SUBROUTINE write_dynamic_bathymetry_deck(path, bathy_path)
    !! Same held-end dynamic deck as write_dynamic_held_deck, but the seabed is a
    !! constant structured bathymetry grid instead of flat WtrDpth.
    CHARACTER(*), INTENT(IN) :: path, bathy_path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic bathymetry deck')
    WRITE (u, '(A)') 'WD0050 dynamic structured-bathymetry chain'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(bathy_path)//' bathymetryFile'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 L1N1px L1N42pz L1N42vz Ten1N42'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_bathymetry_deck

  SUBROUTINE write_dynamic_held_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 held dynamic smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A)') 'dynamic_solver 1.0e-8 1.0e-14 30 8 0.4'
    WRITE (u, '(A)') 'true modified_newton'
    WRITE (u, '(A)') '0.1 frictionMu'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 L1N1px L1N42pz L1N42vz Ten1N42'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_held_deck

  SUBROUTINE write_dynamic_finite_ei_deck(path, line_outputs)
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN), OPTIONAL :: line_outputs
    INTEGER :: u, ios
    LOGICAL :: request_outputs

    request_outputs = .FALSE.
    IF (PRESENT(line_outputs)) request_outputs = line_outputs
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Finite-EI held dynamic smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 250.0 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -80.0'
    WRITE (u, '(A)') '2 Coupled 40.0 0.0 -20.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (request_outputs) THEN
      WRITE (u, '(A)') '1 2 1 pt'
    ELSE
      WRITE (u, '(A)') '1 2 1 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 70.0 5'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '80.0 WtrDpth'
    WRITE (u, '(A)') '2.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 L1N1px L1N6pz L1N6vz Ten1N6'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_finite_ei_deck

  SUBROUTINE write_dynamic_finite_above_bed_deck(path)
    !! Both endpoints are above z=-80, but L=125 exceeds the shortest bed-touching
    !! path sqrt(100^2 + (10+60)^2): the production Hermite builder needs a
    !! two-touchdown seed rather than rejecting the valid grounded span.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create finite-EI above-bed contact deck')
    WRITE (u, '(A)') 'finite-EI two-touchdown Hermite contact regression'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'cable 0.35 120 7.0e8 -1.0 1.2e5 1.2 0.05 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 100 0 -70'
    WRITE (u, '(A)') '2 Coupled 0 0 -20'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cable 125 10'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025 rhoW'
    WRITE (u, '(A)') '80 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.005 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_finite_above_bed_deck

  SUBROUTINE write_dynamic_mixed_finite_ei_deck(path)
    !! Suspended mixed deck for the standalone route boundary: the aggregate can
    !! partition EI=0 and EI>0 objects, but the standalone all-lines march must
    !! reject this topology before its Hermite builder sees the EI=0 line.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create mixed finite-EI route deck')
    WRITE (u, '(A)') 'mixed EI=0 and finite-EI suspended dynamic rejection'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 250.0 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') 'rope   0.10 100.0 1.0e7 0.0 0.0    1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed   0.0  0.0 -80.0'
    WRITE (u, '(A)') '2 Coupled 40.0 0.0 -20.0'
    WRITE (u, '(A)') '3 Fixed   0.0 20.0 -80.0'
    WRITE (u, '(A)') '4 Coupled 40.0 20.0 -20.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 4 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 70.0 5'
    WRITE (u, '(A)') '2 rope   70.0 5'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.010 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_mixed_finite_ei_deck

  SUBROUTINE write_waterkin_file(path, wavekinmod, deepest_first, wave_file, currentmod, dtwave, wavekin_suffix)
    !! A MoorDyn v2 water-kinematics file: header x2, waves header, WaveKinMod,
    !! WaveKinFile/dtWave/WaveDir, three grid-axis PAIRS, current header,
    !! CurrentMod 1, header row, then two `z ux uy` depth rows.
    CHARACTER(*), INTENT(IN) :: path, wavekinmod
    LOGICAL, INTENT(IN) :: deepest_first
    CHARACTER(*), INTENT(IN), OPTIONAL :: wave_file, currentmod
    REAL(wp), INTENT(IN), OPTIONAL :: dtwave
    CHARACTER(*), INTENT(IN), OPTIONAL :: wavekin_suffix
    INTEGER :: u, ios
    CHARACTER(512) :: wf
    CHARACTER(16) :: cm
    CHARACTER(128) :: wm_suffix
    REAL(wp) :: dw
    wf = '""'
    IF (PRESENT(wave_file)) wf = '"'//TRIM(wave_file)//'"'
    cm = '1'
    IF (PRESENT(currentmod)) cm = currentmod
    dw = 0.0_wp
    IF (PRESENT(dtwave)) dw = dtwave
    wm_suffix = '  WaveKinMod  - type of wave input'
    IF (PRESENT(wavekin_suffix)) wm_suffix = wavekin_suffix
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'MoorDyn v2 water kinematics test file'
    WRITE (u, '(A)') '(header line 2)'
    WRITE (u, '(A)') '--------------------------- WAVES -------------------------------------'
    WRITE (u, '(A)') TRIM(wavekinmod)//'                    '//TRIM(wm_suffix)
    WRITE (u, '(A)') TRIM(wf)//'                   WaveKinFile - file containing wave elevation time series'
    WRITE (u, '(ES14.6,A)') dw, '  dtWave      - time step to use in setting up wave kinematics grid (s)'
    WRITE (u, '(A)') '0                    WaveDir     - wave heading (deg)'
    WRITE (u, '(A)') '2                                - X wave input type'
    WRITE (u, '(A)') '-24, 150, 100                    - X wave grid point data'
    WRITE (u, '(A)') '2                                - Y wave input type'
    WRITE (u, '(A)') '-100, 100, 5                     - Y wave grid point data'
    WRITE (u, '(A)') '2                                - Z wave input type'
    WRITE (u, '(A)') '-600, 0, 60                      - Z wave grid point data'
    WRITE (u, '(A)') '--------------------------- CURRENT -------------------------------------'
    WRITE (u, '(A)') TRIM(cm)//'                    CurrentMod  - type of current input'
    WRITE (u, '(A)') 'z-depth     x-current      y-current  # Ignored if CurrentMod = 2'
    WRITE (u, '(A)') '(m)           (m/s)         (m/s)     # Ignored if CurrentMod = 2'
    IF (deepest_first) THEN
      WRITE (u, '(A)') '-10.0  0.30  0.05'
      WRITE (u, '(A)') '0.0  0.10  0.02'
    ELSE
      WRITE (u, '(A)') '0.0  0.10  0.02'
      WRITE (u, '(A)') '-10.0  0.30  0.05'
    END IF
    WRITE (u, '(A)') '--------------------- need this line ------------------'
    CLOSE (u)
  END SUBROUTINE write_waterkin_file

  SUBROUTINE write_wave_elevation_file(path, height, period, mean_eta, nperiods, tail_bias, nrows, row_dt, &
                                       zero_after_index)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: height, period, mean_eta
    INTEGER, INTENT(IN), OPTIONAL :: nperiods
    REAL(wp), INTENT(IN), OPTIONAL :: tail_bias
    INTEGER, INTENT(IN), OPTIONAL :: nrows
    REAL(wp), INTENT(IN), OPTIONAL :: row_dt
    INTEGER, INTENT(IN), OPTIONAL :: zero_after_index
    INTEGER :: u, ios, j, np, nr, izero
    REAL(wp) :: t, eta, bias, input_dt
    np = 1
    IF (PRESENT(nperiods)) np = nperiods
    bias = 0.0_wp
    IF (PRESENT(tail_bias)) bias = tail_bias
    nr = 32*np
    IF (PRESENT(nrows)) nr = nrows
    input_dt = period/32.0_wp
    IF (PRESENT(row_dt)) input_dt = row_dt
    izero = HUGE(izero)
    IF (PRESENT(zero_after_index)) izero = zero_after_index
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'time elevation'
    DO j = 0, nr - 1
      t = input_dt*REAL(j, wp)
      eta = mean_eta + 0.5_wp*height*COS(8.0_wp*ATAN(1.0_wp)*t/period)
      IF (j > izero) eta = 0.0_wp
      IF (j >= 32) eta = eta + bias
      WRITE (u, '(2ES24.15)') t, eta
    END DO
    CLOSE (u)
  END SUBROUTINE write_wave_elevation_file

  SUBROUTINE write_static_failure_deck(path)
    !! A held static deck that declares a FAILURE row: must fail closed (FAILURE
    !! requires a dynamic deck).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Static deck with FAILURE (must fail closed)'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Vessel 2.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.4 4'
    WRITE (u, '(A)') '--- FAILURE ---'
    WRITE (u, '(A)') 'FailID Point Lines FailTime FailTen'
    WRITE (u, '(A)') '(-) (-) (-) (s) (N)'
    WRITE (u, '(A)') '1 P2 1 1.0 0.0'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_static_failure_deck

  SUBROUTINE write_visco_deck(path, ea_col, ba_col, ei_col)
    !! The md_viscoelastic-style rope deck with a caller-chosen EA/BA column
    !! (pipe syntax under test). ei_col defaults to '0.0' (EI=0 line); a
    !! caller passing EI > 0 exercises the finite-EI fail-closed.
    CHARACTER(*), INTENT(IN) :: path, ea_col, ba_col
    CHARACTER(*), INTENT(IN), OPTIONAL :: ei_col
    CHARACTER(32) :: ei_str
    INTEGER :: u, ios
    ei_str = '0.0'
    IF (PRESENT(ei_col)) ei_str = ei_col
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'viscoelastic pipe-syntax deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rope 0.1438 22.42 '//ea_col//' '//ba_col//' '//TRIM(ei_str)//' 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Vessel 2.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    ! TAUT (span ~2.236 m > 2.0 m natural): the huge polyester EA on a slack
    ! catenary is a conditioning stress the static continuation does not owe
    ! this gate; taut statics converge from the straight seed
    WRITE (u, '(A)') '1 rope 2.0 4'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_visco_deck

  SUBROUTINE write_syrope_files(syrope_path, owc_path)
    !! Write a Syrope settings file (referencing the OWC table) and the OWC
    !! strain-tension table (the shipped owc.dat values), for the end-to-end
    !! Syrope deck build gate.
    CHARACTER(*), INTENT(IN) :: syrope_path, owc_path
    INTEGER :: u, ios, i
    REAL(wp) :: eps(30), ten(30)
    eps = [0.00000e+00_wp, 2.06897e-03_wp, 4.13793e-03_wp, 6.20690e-03_wp, 8.27586e-03_wp, &
           1.03448e-02_wp, 1.24138e-02_wp, 1.44828e-02_wp, 1.65517e-02_wp, 1.86207e-02_wp, &
           2.06897e-02_wp, 2.27586e-02_wp, 2.48276e-02_wp, 2.68966e-02_wp, 2.89655e-02_wp, &
           3.10345e-02_wp, 3.31034e-02_wp, 3.51724e-02_wp, 3.72414e-02_wp, 3.93103e-02_wp, &
           4.13793e-02_wp, 4.34483e-02_wp, 4.55172e-02_wp, 4.75862e-02_wp, 4.96552e-02_wp, &
           5.17241e-02_wp, 5.37931e-02_wp, 5.58621e-02_wp, 5.79310e-02_wp, 6.00000e-02_wp]
    ten = [0.00000e+00_wp, 1.71768e+05_wp, 3.30952e+05_wp, 4.78788e+05_wp, 6.16510e+05_wp, &
           7.45355e+05_wp, 8.66556e+05_wp, 9.81351e+05_wp, 1.09097e+06_wp, 1.19666e+06_wp, &
           1.29964e+06_wp, 1.40116e+06_wp, 1.50245e+06_wp, 1.60474e+06_wp, 1.70927e+06_wp, &
           1.81728e+06_wp, 1.93000e+06_wp, 2.04866e+06_wp, 2.17450e+06_wp, 2.30876e+06_wp, &
           2.45267e+06_wp, 2.60747e+06_wp, 2.77439e+06_wp, 2.95467e+06_wp, 3.14954e+06_wp, &
           3.36024e+06_wp, 3.58800e+06_wp, 3.83406e+06_wp, 4.09965e+06_wp, 4.38601e+06_wp]
    OPEN (NEWUNIT=u, FILE=syrope_path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') TRIM(owc_path)//'  OWC    Original working curve table path'
    WRITE (u, '(A)') 'LINEAR      WCType Working curve formula'
    WRITE (u, '(A)') '0.6         k1     shape parameter p1'
    WRITE (u, '(A)') '0.0         k2     shape parameter p2'
    CLOSE (u)
    OPEN (NEWUNIT=u, FILE=owc_path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Strain      Tension'
    WRITE (u, '(A)') '(-)         (N)'
    DO i = 1, 30
      WRITE (u, '(ES14.6,1X,ES14.6)') eps(i), ten(i)
    END DO
    CLOSE (u)
  END SUBROUTINE write_syrope_files

  SUBROUTINE write_syrope_deck(path, ea_col, ba_col, wtrdpth, ei, nsections, option_row, syrope_ic_row, span)
    !! A single-section taut Syrope line: span 2.05 m (or the given span) over a
    !! 2.0 m unstretched length (~2.5 % strain, within the OWC table). With wtrdpth
    !! present, a flat seabed floor is declared (the taut line at z = 0 clears it).
    CHARACTER(*), INTENT(IN) :: path, ea_col, ba_col
    REAL(wp), INTENT(IN), OPTIONAL :: span
    REAL(wp), INTENT(IN), OPTIONAL :: wtrdpth
    REAL(wp), INTENT(IN), OPTIONAL :: ei
    INTEGER, INTENT(IN), OPTIONAL :: nsections
    CHARACTER(*), INTENT(IN), OPTIONAL :: option_row
    CHARACTER(*), INTENT(IN), OPTIONAL :: syrope_ic_row
    INTEGER :: u, ios
    INTEGER :: ns
    REAL(wp) :: line_ei
    CHARACTER(32) :: ei_text
    line_ei = 0.0_wp
    IF (PRESENT(ei)) line_ei = ei
    ns = 1
    IF (PRESENT(nsections)) ns = nsections
    WRITE (ei_text, '(ES14.6)') line_ei
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Syrope single-section taut deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rope 0.1438 22.42 '//ea_col//' '//ba_col//' '//TRIM(ADJUSTL(ei_text))//' 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    IF (PRESENT(span)) THEN
      WRITE (u, '(A,F8.4,A)') '2 Vessel ', span, ' 0.0 0.0 0.0 0.0 0.0 0.0'
    ELSE
      WRITE (u, '(A)') '2 Vessel 2.05 0.0 0.0 0.0 0.0 0.0 0.0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    IF (PRESENT(syrope_ic_row)) THEN
      WRITE (u, '(A)') '--- SYROPE IC ---'
      WRITE (u, '(A)') 'Line(s) Tmax0 Tmean0'
      WRITE (u, '(A)') '(-) (N) (N)'
      WRITE (u, '(A)') TRIM(syrope_ic_row)
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    IF (ns == 1) THEN
      WRITE (u, '(A)') '1 rope 2.0 4'
    ELSE
      WRITE (u, '(A)') '1 rope 1.0 2'
      WRITE (u, '(A)') '1 rope 1.0 2'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    IF (PRESENT(wtrdpth)) THEN
      WRITE (u, '(ES14.6,1X,A)') wtrdpth, 'WtrDpth'
      WRITE (u, '(A)') '1.0e5 kBot'
    END IF
    IF (PRESENT(option_row)) THEN
      WRITE (u, '(A)') '0.01 dtM'
      WRITE (u, '(A)') '0.02 TMax'
      WRITE (u, '(A)') TRIM(option_row)
    END IF
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_syrope_deck

  SUBROUTINE write_dynamic_connect_deck(path, line_outputs, connect_mass, failure_row, failure_row2, &
                                        option_row, option_row2, run_tmax, omit_tmax, outputs)
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN), OPTIONAL :: line_outputs
    REAL(wp), INTENT(IN), OPTIONAL :: connect_mass, run_tmax
    LOGICAL, INTENT(IN), OPTIONAL :: omit_tmax
    CHARACTER(*), INTENT(IN), OPTIONAL :: failure_row, failure_row2, option_row, option_row2
    CHARACTER(*), INTENT(IN), OPTIONAL :: outputs   ! replaces the default OUTPUTS row
    INTEGER :: u, ios
    LOGICAL :: request_outputs, skip_tmax
    REAL(wp) :: cmass, deck_tmax
    CHARACTER(64) :: crow

    request_outputs = .FALSE.
    IF (PRESENT(line_outputs)) request_outputs = line_outputs
    cmass = 20.0_wp
    IF (PRESENT(connect_mass)) cmass = connect_mass
    deck_tmax = 0.01_wp
    IF (PRESENT(run_tmax)) deck_tmax = run_tmax
    skip_tmax = .FALSE.
    IF (PRESENT(omit_tmax)) skip_tmax = omit_tmax
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Two-line dynamic Connect smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (crow, '(A,F0.1,A)') '2 Connect 1.0 0.0 0.0 ', cmass, ' 0.0 0.0 0.0'
    WRITE (u, '(A)') TRIM(crow)
    WRITE (u, '(A)') '3 Fixed 2.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (request_outputs) THEN
      WRITE (u, '(A)') '1 2 1 pt'
    ELSE
      WRITE (u, '(A)') '1 2 1 -'
    END IF
    WRITE (u, '(A)') '2 2 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 0.98 1'
    WRITE (u, '(A)') '2 line 0.98 1'
    IF (PRESENT(failure_row)) THEN
      WRITE (u, '(A)') '--- FAILURE ---'
      WRITE (u, '(A)') 'FailID Point Lines FailTime FailTen'
      WRITE (u, '(A)') '(-) (-) (-) (s) (N)'
      WRITE (u, '(A)') TRIM(failure_row)
      IF (PRESENT(failure_row2)) WRITE (u, '(A)') TRIM(failure_row2)
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.005 dtM'
    IF (.NOT. skip_tmax) WRITE (u, '(ES14.6,1X,A)') deck_tmax, 'TMax'
    IF (PRESENT(option_row)) WRITE (u, '(A)') TRIM(option_row)
    IF (PRESENT(option_row2)) WRITE (u, '(A)') TRIM(option_row2)
    WRITE (u, '(A)') '--- OUTPUTS ---'
    IF (PRESENT(outputs)) THEN
      WRITE (u, '(A)') TRIM(outputs)
    ELSE
      WRITE (u, '(A)') 'FairTen1 FairTen2 L1N1pz L1N1vz'
    END IF
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_connect_deck

  SUBROUTINE write_dynamic_connect_added_mass_deck(path, ca)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: ca
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Connect added-mass deck')
    WRITE (u, '(A)') 'Two-line dynamic Connect still-water added-mass smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A,ES14.6)') '2 Connect 1.0 0.0 0.0 20.0 0.05 0.0 ', ca
    WRITE (u, '(A)') '3 Fixed 2.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 2 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 0.98 1'
    WRITE (u, '(A)') '2 line 0.98 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    ! the explicit point update of the staggered scheme sets the point moving from its static
    ! balance, which this smoke test weighs; the monolithic step keeps it at rest
    WRITE (u, '(A)') 'staggered bodyScheme'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2 L1N1pz L1N1vz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_connect_added_mass_deck

  SUBROUTINE write_dynamic_connect_bathymetry_deck(path, bathy_path)
    !! Same two-line Connect deck as write_dynamic_connect_deck, with a structured
    !! bathymetry file far below the line so contact is inactive and the trajectory
    !! must match the no-bottom reference.
    CHARACTER(*), INTENT(IN) :: path, bathy_path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Connect bathymetry deck')
    WRITE (u, '(A)') 'Two-line dynamic Connect bathymetry smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Connect 1.0 0.0 0.0 20.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Fixed 2.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 2 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 0.98 1'
    WRITE (u, '(A)') '2 line 0.98 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(bathy_path)//' bathymetryFile'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 FairTen2 L1N1pz L1N1vz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_connect_bathymetry_deck

  SUBROUTINE write_dynamic_connect_current_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Connect-current deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Two-line dynamic Connect current smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Connect 1.0 0.0 -0.5 20.0 0.0195121951 2.0 1.0'
    WRITE (u, '(A)') '3 Fixed 2.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 2 3 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '2 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') 'uniform 0.8 0.0 0.0 current'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1px L1N1vx'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_connect_current_deck

  SUBROUTINE write_dynamic_point3_body_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Point3 BODY deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic Point3 BODY smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-)'
    WRITE (u, '(A)') '1 Point3 1.0 0.0 -0.5 0.0 0.0 0.0 20.0 0.0195121951 0.0 0.0 0.0 2.0 1.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') 'uniform 0.8 0.0 0.0 current'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1px L1N1vx Point2px'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_point3_body_deck

  SUBROUTINE write_dynamic_point3_wave_body_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Point3 BODY wave deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic Point3 BODY wave smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-)'
    WRITE (u, '(A)') '1 Point3 1.0 0.0 -0.5 0.0 0.0 0.0 20.0 0.0195121951 0.0 0.0 0.0 2.0 1.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '5.0 WtrDpth'
    WRITE (u, '(A)') 'airy 1.0 1.5 0.0 waves'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1px L1N1vx Point2px'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_point3_wave_body_deck

  SUBROUTINE write_dynamic_rigid6_body_deck(path, bathy_path, line_outputs)
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(IN), OPTIONAL :: bathy_path
    LOGICAL, INTENT(IN), OPTIONAL :: line_outputs
    INTEGER :: u, ios
    LOGICAL :: request_outputs

    request_outputs = .FALSE.
    IF (PRESENT(line_outputs)) request_outputs = line_outputs
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Rigid6 BODY deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic Rigid6 BODY smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 0.0 0.0 0.0 0.0 100.0 0.0975609756 0.0 0.0 0.0 0.0 0.0 20.0 20.0 20.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 1.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Fixed 5.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Body1 0.0 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (request_outputs) THEN
      WRITE (u, '(A)') '1 3 1 pt'
    ELSE
      WRITE (u, '(A)') '1 3 1 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.2 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    IF (PRESENT(bathy_path)) WRITE (u, '(A)') TRIM(bathy_path)//' bathymetryFile'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1pz Point3pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_body_deck

  SUBROUTINE write_dynamic_rigid6_added_mass_deck(path, ca_body)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: ca_body
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Rigid6 added-mass deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic Rigid6 calm-water added-mass smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A,F8.3,A)') '1 Rigid6 0.0 0.0 0.0 0.0 0.0 0.0 400.0 0.2 0.0 0.0 0.0 0.0 ', &
      ca_body, ' 20.0 20.0 20.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 1.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Body1 0.0 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.2 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '5.0 WtrDpth'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1pz Point2pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_added_mass_deck

  SUBROUTINE write_dynamic_rigid6_contact_deck(path, bathy_path)
    !! Rigid6 body starts below a shallow bathymetry floor; active contact must lift it
    !! relative to the same deck on a deep structured floor.
    CHARACTER(*), INTENT(IN) :: path, bathy_path
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Rigid6 contact deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic Rigid6 bathymetry contact smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 -1.0 0.0 0.0 0.0 100.0 0.0975609756 0.0 0.0 0.0 0.0 0.0 20.0 20.0 20.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    ! The anchor rests on the shallow (0.5 m) contact seabed; the body attachment (z = -1)
    ! lies below it, so contact is active on the body side of the line.
    WRITE (u, '(A)') '1 Fixed 0.0 2.2 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Body1 0.0 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 3 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.6 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(bathy_path)//' bathymetryFile'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.002 dtM'
    WRITE (u, '(A)') '0.004 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1pz Point3pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_contact_deck

  SUBROUTINE write_dynamic_rigid6_rotation_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Rigid6 rotation deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Two-line dynamic Rigid6 rotation smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 0.0 0.0 0.0 0.0 100.0 0.0975609756 0.0 0.0 0.0 0.0 0.0 1.0 1.0 1.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 1.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Fixed 2.0 -1.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Body1 0.0 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Body1 0.0 -1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 3 1 -'
    WRITE (u, '(A)') '2 4 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.2 1'
    WRITE (u, '(A)') '2 line 3.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point3px Point3py Point3pz Point4px Point4py Point4pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_rotation_deck

  SUBROUTINE write_dynamic_rigid6_jonswap_body_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Rigid6 BODY JONSWAP deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic Rigid6 BODY JONSWAP smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 1.0 0.0 -0.5 0.0 0.0 0.0 20.0 0.0195121951 0.0 0.0 0.0 2.0 1.0 5.0 5.0 5.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '5.0 WtrDpth'
    WRITE (u, '(A)') 'jonswap 1.0 1.5 3.3 0.0 waves'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1px L1N1vx Point2px'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_jonswap_body_deck

  SUBROUTINE write_dynamic_rigid6_current_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic Rigid6-current deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic Rigid6 current smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 1.0 0.0 -0.5 0.0 0.0 0.0 20.0 0.0195121951 0.0 0.0 0.0 2.0 1.0 5.0 5.0 5.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -0.5 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Body1 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.0 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') 'uniform 0.8 0.0 0.0 current'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1px L1N1vx Point2px'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_current_deck

  SUBROUTINE write_dynamic_rigid6_motion_deck(path, motion_path)
    CHARACTER(*), INTENT(IN) :: path, motion_path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic prescribed Rigid6 deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Single-line dynamic prescribed Rigid6 BODY smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 0.0 0.0 0.0 0.0 100.0 0.0975609756 0.0 0.0 0.0 0.0 0.0 20.0 20.0 20.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 1.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Body1 0.0 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 3 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.2 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(motion_path)//' motionFile'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1px Point3px Point3pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_motion_deck

  SUBROUTINE write_prescribed_rigid6_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, i
    REAL(wp), PARAMETER :: tvals(3) = [0.0_wp, 0.005_wp, 0.01_wp]
    REAL(wp), PARAMETER :: xvals(3) = [0.0_wp, 0.01_wp, 0.02_wp]

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create prescribed Rigid6 motion file')
    IF (ios /= 0) RETURN
    DO i = 1, 3
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 3, xvals(i), 1.0_wp, 0.0_wp, &
        2.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
    END DO
    CLOSE (u)
  END SUBROUTINE write_prescribed_rigid6_motion_file

  SUBROUTINE write_dynamic_rigid6_bad_motion_deck(path, motion_path)
    CHARACTER(*), INTENT(IN) :: path, motion_path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create bad prescribed Rigid6 deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Two-point inconsistent prescribed Rigid6 BODY smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 0.0 0.0 0.0 0.0 100.0 0.0975609756 0.0 0.0 0.0 0.0 0.0 20.0 20.0 20.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 0.0 1.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Fixed 0.0 -1.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Body1 0.0 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Body1 0.0 -1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 3 1 -'
    WRITE (u, '(A)') '2 4 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.2 1'
    WRITE (u, '(A)') '2 line 2.2 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(motion_path)//' motionFile'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N1px Point3px'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_bad_motion_deck

  SUBROUTINE rigid6_rot_reference(t, offs, qv, vv, av)
    !! Analytic rigid trajectory shared by the rotational-motion writer and the
    !! .out checker: fixed-axis rotation theta(t) = THETA0 sin(OMG t) about UHAT
    !! composed with a two-axis translation. offs = body-frame attachment offset.
    REAL(wp), INTENT(IN) :: t, offs(3)
    REAL(wp), INTENT(OUT) :: qv(3), vv(3), av(3)
    REAL(wp), PARAMETER :: THETA0 = 0.3_wp, OMG = 40.0_wp
    REAL(wp), PARAMETER :: AX = 0.1_wp, WX = 30.0_wp, AZ = 0.05_wp, WZ = 20.0_wp
    REAL(wp) :: uhat(3), th, thd, thdd, rrel(3, 3), dref(3), arm(3), om(3), al(3)
    REAL(wp) :: rt(3), vt(3), at(3)

    uhat = [1.0_wp, 2.0_wp, 3.0_wp]/SQRT(14.0_wp)
    th = THETA0*SIN(OMG*t)
    thd = THETA0*OMG*COS(OMG*t)
    thdd = -THETA0*OMG*OMG*SIN(OMG*t)
    rrel = CD_Exp_SO3(th*uhat)
    om = thd*uhat
    al = thdd*uhat
    rt = [AX*SIN(WX*t), 0.0_wp, -0.5_wp + AZ*SIN(WZ*t)]
    vt = [AX*WX*COS(WX*t), 0.0_wp, AZ*WZ*COS(WZ*t)]
    at = [-AX*WX*WX*SIN(WX*t), 0.0_wp, -AZ*WZ*WZ*SIN(WZ*t)]
    dref = MATMUL(CD_Body_Rotation(0.0_wp, 0.0_wp, 30.0_wp), offs)
    arm = MATMUL(rrel, dref)
    qv = rt + arm
    vv = vt + xprod(om, arm)
    av = at + xprod(al, arm) + xprod(om, xprod(om, arm))
  END SUBROUTINE rigid6_rot_reference

  PURE FUNCTION xprod(a, b) RESULT(c)
    REAL(wp), INTENT(IN) :: a(3), b(3)
    REAL(wp) :: c(3)
    c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
  END FUNCTION xprod

  SUBROUTINE rigid6_rot_offsets(offs)
    !! The three non-collinear body-frame attachment offsets of the rotational deck.
    REAL(wp), INTENT(OUT) :: offs(3, 3)
    offs(:, 1) = [1.0_wp, 0.0_wp, 0.2_wp]
    offs(:, 2) = [-0.4_wp, 0.9_wp, 0.1_wp]
    offs(:, 3) = [0.1_wp, -0.3_wp, 0.4_wp]
  END SUBROUTINE rigid6_rot_offsets

  SUBROUTINE write_turbine_vocab_deck(path)
    !! A FAST.Farm-vocabulary deck: its coupled coordinates are TURBINE-LOCAL, so every
    !! non-aggregate entry point must fail closed rather than solve them as global.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create turbine-vocab deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Farm-vocabulary deck through the standalone driver (must fail closed)'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.333 685.0 3.27e9 -1.0 0.0 2.0 0.4 0.82 0.27'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Turbine1  0.0 0.0 -10.0'
    WRITE (u, '(A)') '2 Fixed  -500.0 0.0 -200.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 560.0 10'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_turbine_vocab_deck

  SUBROUTINE write_rotational_rigid6_motion_file(path, non_rigid)
    !! Body<N> point rows generated from one analytic rigid 6-DOF trajectory.
    !! non_rigid=.TRUE. scales the third point's position rows so the set no
    !! longer describes a rigid motion (the recovery must fail closed).
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: non_rigid
    INTEGER :: u, ios, it, ip
    REAL(wp) :: t, offs(3, 3), qv(3), vv(3), av(3)

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create rotational Rigid6 motion file')
    IF (ios /= 0) RETURN
    CALL rigid6_rot_offsets(offs)
    DO it = 0, 4
      t = REAL(it, wp)*0.005_wp
      DO ip = 1, 3
        CALL rigid6_rot_reference(t, offs(:, ip), qv, vv, av)
        IF (non_rigid .AND. ip == 3) qv = 1.5_wp*qv
        WRITE (u, '(ES25.16,1X,I0,9(1X,ES25.16))') t, ip + 2, qv, vv, av
      END DO
    END DO
    CLOSE (u)
  END SUBROUTINE write_rotational_rigid6_motion_file

  SUBROUTINE write_dynamic_rigid6_rotmotion_deck(path, motion_path)
    !! Three slack lines hang from three non-collinear Body1 attachment points; the
    !! motionFile prescribes the full rotational body trajectory. The deck BODY row
    !! carries a 30 deg yaw so the recovery must compose rot_mat = R_rel * rot_ref.
    CHARACTER(*), INTENT(IN) :: path, motion_path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create rotational prescribed Rigid6 deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Three-line prescribed rotational Rigid6 BODY gate'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) '// &
      '(Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Rigid6 0.0 0.0 -0.5 0.0 0.0 30.0 100.0 0.0975609756 0.0 0.0 0.0 0.0 0.0 20.0 20.0 20.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '3 Body1 1.0 0.0 0.2 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Body1 -0.4 0.9 0.1 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '5 Body1 0.1 -0.3 0.4 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '11 Fixed 1.2 0.6 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '12 Fixed -0.9 0.7 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '13 Fixed -0.2 -0.4 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 3 11 -'
    WRITE (u, '(A)') '2 4 12 -'
    WRITE (u, '(A)') '3 5 13 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 2.0 2'
    WRITE (u, '(A)') '2 line 1.9 2'
    WRITE (u, '(A)') '3 line 2.2 2'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(motion_path)//' motionFile'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.02 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point3px Point3py Point3pz Point4px Point4py Point4pz Point5px Point5py Point5pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rigid6_rotmotion_deck

  SUBROUTINE check_dynamic_rigid6_rotmotion_out(path)
    !! Every prescribed attachment point tracks the analytic rigid trajectory at the
    !! final time: full pose + angular-rate recovery flows through the marched system.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, nrow, ip
    CHARACTER(1024) :: buf
    REAL(wp) :: t, pos(9), offs(3, 3), qv(3), vv(3), av(3), err

    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    CALL require(ios == 0, 'open rotational prescribed Rigid6 .out')
    IF (ios /= 0) RETURN
    READ (u, '(A)', IOSTAT=ios) buf
    READ (u, '(A)', IOSTAT=ios) buf
    nrow = 0
    t = 0.0_wp
    pos = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios < 0) EXIT
      CALL require(ios == 0, 'read rotational prescribed Rigid6 row')
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, pos
      CALL require(ios == 0, 'parse rotational prescribed Rigid6 row')
      nrow = nrow + 1
    END DO
    CLOSE (u)
    CALL require(nrow == 5, 'rotational prescribed Rigid6 .out has t=0 plus four time steps')
    CALL require(ABS(t - 0.02_wp) < 1.0e-12_wp, 'rotational prescribed Rigid6 final time')
    CALL rigid6_rot_offsets(offs)
    DO ip = 1, 3
      CALL rigid6_rot_reference(t, offs(:, ip), qv, vv, av)
      err = SQRT(SUM((pos(3*ip - 2:3*ip) - qv)**2))
      CALL require(err < 1.0e-6_wp, 'rotational prescribed Rigid6 attachment tracks the analytic rigid pose')
    END DO
  END SUBROUTINE check_dynamic_rigid6_rotmotion_out

  SUBROUTINE write_bad_rigid6_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, i
    REAL(wp), PARAMETER :: tvals(3) = [0.0_wp, 0.005_wp, 0.01_wp]
    REAL(wp), PARAMETER :: x3(3) = [0.0_wp, 0.01_wp, 0.02_wp]
    REAL(wp), PARAMETER :: x4(3) = [0.0_wp, 0.02_wp, 0.04_wp]

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create bad prescribed Rigid6 motion file')
    IF (ios /= 0) RETURN
    DO i = 1, 3
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 3, x3(i), 1.0_wp, 0.0_wp, &
        2.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 4, x4(i), -1.0_wp, 0.0_wp, &
        4.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
    END DO
    CLOSE (u)
  END SUBROUTINE write_bad_rigid6_motion_file

  SUBROUTINE write_dynamic_rod_deck(path, bathy_path, line_outputs, rod_outputs, anchor1_z)
    !! anchor1_z moves anchor POINT 1 vertically (default -3.0 m); the active-contact pair
    !! sets it on the shallow contact seabed, where an anchor may not lie below the bed.
    CHARACTER(*), INTENT(IN) :: path
    CHARACTER(*), INTENT(IN), OPTIONAL :: bathy_path
    LOGICAL, INTENT(IN), OPTIONAL :: line_outputs
    LOGICAL, INTENT(IN), OPTIONAL :: rod_outputs
    REAL(wp), INTENT(IN), OPTIONAL :: anchor1_z
    INTEGER :: u, ios
    REAL(wp) :: za
    LOGICAL :: request_line_outputs, request_rod_outputs

    za = -3.0_wp
    IF (PRESENT(anchor1_z)) za = anchor1_z
    request_line_outputs = .FALSE.
    request_rod_outputs = .FALSE.
    IF (PRESENT(line_outputs)) request_line_outputs = line_outputs
    IF (PRESENT(rod_outputs)) request_rod_outputs = rod_outputs
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic ROD deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Two-line dynamic ROD smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rodmat 0.20 50.0 1.0 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    IF (request_rod_outputs) THEN
      WRITE (u, '(A)') '1 rodmat Free 0.0 0.0 -2.0 0.0 0.0 0.0 1 p'
    ELSE
      WRITE (u, '(A)') '1 rodmat Free 0.0 0.0 -2.0 0.0 0.0 0.0 1 -'
    END IF
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A,F0.3,A)') '1 Fixed -0.5 0.0 ', za, ' 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Rod1B 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Fixed 0.5 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (request_line_outputs) THEN
      WRITE (u, '(A)') '1 2 1 pt'
      WRITE (u, '(A)') '2 3 4 pt'
    ELSE
      WRITE (u, '(A)') '1 2 1 -'
      WRITE (u, '(A)') '2 3 4 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.1 1'
    WRITE (u, '(A)') '2 line 1.1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    IF (PRESENT(bathy_path)) WRITE (u, '(A)') TRIM(bathy_path)//' bathymetryFile'
    WRITE (u, '(A)') 'profile -2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 current'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px Point2pz Point3px Point3pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_rod_deck

  SUBROUTINE write_light_rod_deck(path, rod_mass, dtm)
    !! A free rod hanging between a 3.5 m line (~280 kg) to a low anchor and a 1.2 m line to a
    !! fixed upper point. With rod_mass <= 50 kg/m the rod (<= 100 kg) carries more line inertia
    !! than its own mass: the regime in which an explicit partitioned rod update diverges.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: rod_mass, dtm
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create light ROD deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Light rod carrying heavier line inertia'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 -0.5 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A,F0.3,A)') 'rodmat 0.20 ', rod_mass, ' 1.0 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 rodmat Free 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 2.0 0.0 -5.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -4.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Rod1B 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Fixed 0.0 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 3.5 3'
    WRITE (u, '(A)') '2 line 1.2 2'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '10.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(ES12.5,A)') dtm, ' dtM'
    WRITE (u, '(A)') '20.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Ten2N2 Point2px Point2pz Point3px Point3pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_light_rod_deck

  SUBROUTINE read_last_output_row(path, row, ErrStat)
    !! Read the last data row (time + SIZE(row) channels) of a deck .out file.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(OUT) :: row(:)
    INTEGER, INTENT(OUT) :: ErrStat
    INTEGER :: u, ios
    CHARACTER(512) :: buf
    REAL(wp) :: t, vals(SIZE(row))

    row = 0.0_wp
    ErrStat = 1
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, vals
      IF (ios == 0) THEN
        row = vals
        ErrStat = 0
      END IF
    END DO
    CLOSE (u)
  END SUBROUTINE read_last_output_row

  SUBROUTINE check_light_rod_carried_inertia()
    !! Regression for the partitioned rod/line added-mass instability: a free rod lighter than
    !! the line inertia it carries (10 and 50 kg/m) must march stably from dtM = 0.005 s to
    !! 0.1 s. Averaged over the second half of the 0.02 s run (the rod then oscillates about
    !! its equilibrium: the static initial condition leaves the short upper line slack, as a
    !! tension-only line between points closer than its length must be), the upper-line
    !! tension (its interior node, free of the end-node lumped weight) must differ between
    !! the two rod masses by the extra rod weight 2 m * 40 kg/m * g (buoyancy is unchanged),
    !! i.e. the correct equilibrium.
    REAL(wp), PARAMETER :: MASSES(2) = [10.0_wp, 50.0_wp], DTS(3) = [0.005_wp, 0.02_wp, 0.1_wp]
    REAL(wp) :: row(5), ten_coarse(2)
    INTEGER :: im, idt, es
    LOGICAL :: conv
    CHARACTER(512) :: em
    CHARACTER(64) :: root

    ten_coarse = 0.0_wp
    DO im = 1, SIZE(MASSES)
      DO idt = 1, SIZE(DTS)
        WRITE (root, '(A,I0,A,I0)') 'deck_light_rod_m', NINT(MASSES(im)), '_dt', NINT(1000.0_wp*DTS(idt))
        CALL write_light_rod_deck(TRIM(root)//'.dat', MASSES(im), DTS(idt))
        CALL CD_Run_Deck_Driver(TRIM(root)//'.dat', TRIM(root), conv, es, em)
        CALL require(es == CD_DECKDRV_OK .AND. conv, 'light ROD carrying heavier line inertia is stable ('// &
                     TRIM(root)//'): '//TRIM(em))
        CALL read_last_output_row(TRIM(root)//'.out', row, es)
        CALL require(es == 0, 'read light ROD output '//TRIM(root))
        CALL require(ALL(ABS(row(2:5)) < 10.0_wp), 'light ROD stays near its moorings '//TRIM(root))
        IF (idt == 2) ten_coarse(im) = mean_first_channel(TRIM(root)//'.out', 10.0_wp)
      END DO
    END DO
    CALL require(ABS((ten_coarse(2) - ten_coarse(1)) - 2.0_wp*40.0_wp*9.80665_wp) < 0.01_wp*784.532_wp, &
                 'light ROD equilibrium tension scales with the rod weight')
  END SUBROUTINE check_light_rod_carried_inertia

  REAL(wp) FUNCTION mean_first_channel(path, t_from) RESULT(mean)
    !! Time average of the first output channel over the rows with t >= t_from.
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: t_from
    INTEGER :: u, ios, n
    REAL(wp) :: t, v
    CHARACTER(512) :: buf
    mean = 0.0_wp
    n = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) EXIT
      READ (buf, *, IOSTAT=ios) t, v
      IF (ios /= 0 .OR. t < t_from) CYCLE
      mean = mean + v
      n = n + 1
    END DO
    CLOSE (u)
    IF (n > 0) mean = mean/REAL(n, wp)
  END FUNCTION mean_first_channel

  SUBROUTINE write_dynamic_prescribed_rod_deck(path, motion_path)
    CHARACTER(*), INTENT(IN) :: path, motion_path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic prescribed ROD deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Two-line dynamic prescribed ROD smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rodmat 0.20 50.0 1.0 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 rodmat Coupled 0.0 0.0 -2.0 0.0 0.0 0.0 1 p'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed -0.5 0.0 -3.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Rod1B 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Fixed 0.5 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.1 1'
    WRITE (u, '(A)') '2 line 1.1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(motion_path)//' motionFile'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px Point2pz Point3px Point3pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_prescribed_rod_deck

  SUBROUTINE write_prescribed_rod_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, i
    REAL(wp), PARAMETER :: tvals(3) = [0.0_wp, 0.005_wp, 0.01_wp]
    REAL(wp), PARAMETER :: xvals(3) = [0.0_wp, 0.01_wp, 0.02_wp]

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create prescribed ROD motion file')
    IF (ios /= 0) RETURN
    DO i = 1, 3
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 2, xvals(i), 0.0_wp, -2.0_wp, &
        2.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 3, xvals(i), 0.0_wp, 0.0_wp, &
        2.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
    END DO
    CLOSE (u)
  END SUBROUTINE write_prescribed_rod_motion_file

  SUBROUTINE write_dynamic_mixed_rod_motion_deck(path, motion_path)
    CHARACTER(*), INTENT(IN) :: path, motion_path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create mixed prescribed/free ROD motion deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Mixed prescribed/free ROD motion smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rodmat 0.20 50.0 1.0 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 rodmat Coupled 0.0 0.0 -2.0 0.0 0.0 0.0 1 p'
    WRITE (u, '(A)') '2 rodmat Free 2.0 0.0 -2.0 2.0 0.0 0.0 1 p'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed -0.5 0.0 -3.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Rod1B 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Fixed 0.5 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '5 Rod2A 2.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '6 Rod2B 2.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '7 Fixed 1.5 0.0 -3.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '8 Fixed 2.5 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '3 5 7 -'
    WRITE (u, '(A)') '4 6 8 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.1 1'
    WRITE (u, '(A)') '2 line 1.1 1'
    WRITE (u, '(A)') '3 line 1.1 1'
    WRITE (u, '(A)') '4 line 1.1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    ! released from the deck pose: these rigs exercise the dynamics, not the static IC
    WRITE (u, '(A)') 'deck bodyIC'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(motion_path)//' motionFile'
    WRITE (u, '(A)') 'profile -2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 current'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px Point2pz Point3px Point3pz Point5px Point5pz Point6px Point6pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_mixed_rod_motion_deck

  SUBROUTINE write_mixed_rod_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios, i
    REAL(wp), PARAMETER :: tvals(3) = [0.0_wp, 0.005_wp, 0.01_wp]
    REAL(wp), PARAMETER :: xvals(3) = [0.0_wp, 0.01_wp, 0.02_wp]

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create mixed ROD motion file')
    IF (ios /= 0) RETURN
    DO i = 1, 3
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 2, xvals(i), 0.0_wp, -2.0_wp, &
        2.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 3, xvals(i), 0.0_wp, 0.0_wp, &
        2.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 5, 2.0_wp, 0.0_wp, -2.0_wp, &
        0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
      WRITE (u, '(ES16.8,1X,I0,9(1X,ES16.8))') tvals(i), 6, 2.0_wp, 0.0_wp, 0.0_wp, &
        0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp
    END DO
    CLOSE (u)
  END SUBROUTINE write_mixed_rod_motion_file

  SUBROUTINE write_dynamic_bad_coupled_rod_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create bad Coupled ROD deck')
    IF (ios /= 0) RETURN
    CALL write_prescribed_rod_common_prefix(u)
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 rodmat Coupled 0.0 0.0 -2.0 0.0 0.0 0.0 1 -'
    CALL write_prescribed_rod_common_suffix(u, include_motion=.FALSE.)
    CLOSE (u)
  END SUBROUTINE write_dynamic_bad_coupled_rod_deck

  SUBROUTINE write_prescribed_rod_common_prefix(u)
    INTEGER, INTENT(IN) :: u
    WRITE (u, '(A)') 'Two-line prescribed ROD boundary deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rodmat 0.20 50.0 1.0 1.0 0.0 0.0 0.2 0.0'
  END SUBROUTINE write_prescribed_rod_common_prefix

  SUBROUTINE write_prescribed_rod_common_suffix(u, include_motion, motion_path)
    INTEGER, INTENT(IN) :: u
    LOGICAL, INTENT(IN) :: include_motion
    CHARACTER(*), INTENT(IN), OPTIONAL :: motion_path
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed -0.5 0.0 -3.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Rod1B 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Fixed 0.5 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.1 1'
    WRITE (u, '(A)') '2 line 1.1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    IF (include_motion) THEN
      CALL require(PRESENT(motion_path), 'motion path supplied for boundary deck')
      IF (PRESENT(motion_path)) WRITE (u, '(A)') TRIM(motion_path)//' motionFile'
    END IF
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px Point2pz Point3px Point3pz'
    WRITE (u, '(A)') '--- end ---'
  END SUBROUTINE write_prescribed_rod_common_suffix

  SUBROUTINE write_dynamic_fixed_rod_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create dynamic fixed ROD deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'Two-line dynamic fixed ROD smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'rodmat 0.20 50.0 1.0 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 rodmat Fixed 0.0 0.0 -2.0 0.0 0.0 0.0 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed -0.5 0.0 -3.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '2 Rod1A 0.0 0.0 -2.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '3 Rod1B 0.0 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '4 Fixed 0.5 0.0 -1.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '2 3 4 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 line 1.1 1'
    WRITE (u, '(A)') '2 line 1.1 1'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.005 dtM'
    WRITE (u, '(A)') '0.01 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px Point2pz Point3px Point3pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_fixed_rod_deck

  SUBROUTINE write_dynamic_current_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 uniform-current dynamic smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A)') 'uniform 1.0 0.0 0.0 current'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_current_deck

  SUBROUTINE write_dynamic_current_profile_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 current-profile dynamic smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A)') 'profile -50.0 0.2 0.0 0.0 0.0 1.1 0.0 0.0 current'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_current_profile_deck

  SUBROUTINE write_dynamic_wave_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 Airy-wave dynamic smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A)') 'airy 2.0 1.5 0.0 waves'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_wave_deck

  SUBROUTINE write_l3_wave_deck(path)
    !! WD0050 Airy-wave deck matching the L3-2 OrcaFlex parity gate. This checks
    !! the public `.dat` -> dynamic `.out` workflow, not just the core load path.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create L3-2 dynamic deck')
    IF (ios /= 0) RETURN
    WRITE (u, '(A)') 'WD0050 Airy-wave dynamic L3-2 deck validation'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '48.0 TMax'
    WRITE (u, '(A)') '0.4 rho_inf'
    WRITE (u, '(A)') 'airy 3.0 8.0 180.0 waves'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_l3_wave_deck

  SUBROUTINE write_dynamic_jonswap_deck(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 JONSWAP-wave dynamic smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A)') 'jonswap 2.0 1.5 3.3 0.0 waves'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_jonswap_deck

  SUBROUTINE write_dynamic_motion_deck(path, motion_path, cdn, nonconvergent)
    CHARACTER(*), INTENT(IN) :: path, motion_path
    REAL(wp), INTENT(IN), OPTIONAL :: cdn
    LOGICAL, INTENT(IN), OPTIONAL :: nonconvergent
    INTEGER :: u, ios
    REAL(wp) :: cdn_value
    LOGICAL :: force_nonconvergence
    cdn_value = 1.37_wp
    IF (PRESENT(cdn)) cdn_value = cdn
    force_nonconvergence = .FALSE.
    IF (PRESENT(nonconvergent)) force_nonconvergence = nonconvergent
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 prescribed-motion smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A,F8.4,A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 ', cdn_value, ' 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    IF (force_nonconvergence) WRITE (u, '(A)') 'dynamic_solver 1.0e-12 1.0e-14 1 0'
    WRITE (u, '(A,A)') TRIM(motion_path), ' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 Point2pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_motion_deck

  SUBROUTINE write_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '0.00 2 0.0 0.0 0.000 0.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.01 2 0.0 0.0 0.005 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.02 2 0.0 0.0 0.010 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.03 2 0.0 0.0 0.015 0.0 0.0 0.5 0.0 0.0 0.0'
    CLOSE (u)
  END SUBROUTINE write_motion_file

  SUBROUTINE write_dynamic_finite_motion_deck(path, motion_path, line_outputs)
    CHARACTER(*), INTENT(IN) :: path, motion_path
    LOGICAL, INTENT(IN), OPTIONAL :: line_outputs
    INTEGER :: u, ios
    LOGICAL :: request_outputs

    request_outputs = .FALSE.
    IF (PRESENT(line_outputs)) request_outputs = line_outputs
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'finite-EI prescribed-motion smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0 0 -80'
    WRITE (u, '(A)') '2 Coupled 40 0 -20'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (request_outputs) THEN
      WRITE (u, '(A)') '1 2 1 pt'
    ELSE
      WRITE (u, '(A)') '1 2 1 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 70 5'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A,A)') TRIM(motion_path), ' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2pz L1N1pz L1N1vz L1N1az FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_finite_motion_deck

  SUBROUTINE write_finite_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '0.00 2 40.0 0.0 -19.999 0.0 0.0 0.1 0.0 0.0 0.05'
    WRITE (u, '(A)') '0.01 2 40.0 0.0 -19.995 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.02 2 40.0 0.0 -19.990 0.0 0.0 0.5 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.03 2 40.0 0.0 -19.985 0.0 0.0 0.5 0.0 0.0 0.0'
    CLOSE (u)
  END SUBROUTINE write_finite_motion_file

  SUBROUTINE write_dynamic_finite_friction_deck(path, motion_path, mu)
    CHARACTER(*), INTENT(IN) :: path, motion_path
    REAL(wp), INTENT(IN) :: mu
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'finite-EI touchdown friction smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0 0 -80.0'
    WRITE (u, '(A)') '2 Coupled 40 0 -70.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    ! Twenty elements keep the touchdown bend below the production h*kappa limit;
    ! this test exercises friction/motion coupling, not coarse-mesh acceptance.
    WRITE (u, '(A)') '1 pcable 45 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '80.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(ES14.6,A)') mu, ' frictionMu'
    WRITE (u, '(A)') 'True adaptive_mesh'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A,A)') TRIM(motion_path), ' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px L1N1px FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_finite_friction_deck

  SUBROUTINE write_dynamic_finite_current_seed_deck(path, modified_newton)
    !! A suspended (taut, no-seabed) finite-EI line in a strong uniform current. The static IC
    !! is the equilibrium in that current, so the march starts and stays at rest. No WtrDpth:
    !! seabed contact is not engaged, so the current drag is the only environmental load.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN), OPTIONAL :: modified_newton
    INTEGER :: u, ios
    LOGICAL :: use_modified_newton

    use_modified_newton = .FALSE.
    IF (PRESENT(modified_newton)) use_modified_newton = modified_newton
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create finite-EI current-seed deck')
    WRITE (u, '(A)') 'finite-EI current initial-acceleration seed regression'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0 0 -80'
    WRITE (u, '(A)') '2 Coupled 40 0 -20'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 70 5'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.001 dtM'
    WRITE (u, '(A)') '0.003 TMax'
    WRITE (u, '(A)') 'uniform 2.0 0.0 0.0 current'
    IF (use_modified_newton) WRITE (u, '(A)') 'true modified_newton'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'L1N3vx L1N3px FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_finite_current_seed_deck

  SUBROUTINE write_dynamic_finite_bathymetry_deck(path, motion_path, bathy_path, mu)
    !! Same finite-EI touchdown deck as write_dynamic_finite_friction_deck, but
    !! the seabed is supplied by a constant structured bathymetry grid.
    CHARACTER(*), INTENT(IN) :: path, motion_path, bathy_path
    REAL(wp), INTENT(IN) :: mu
    INTEGER :: u, ios

    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    CALL require(ios == 0, 'create finite-EI bathymetry deck')
    WRITE (u, '(A)') 'finite-EI touchdown bathymetry smoke'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0 0 -80.0'
    WRITE (u, '(A)') '2 Coupled 40 0 -70.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 pcable 45 20'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') TRIM(bathy_path)//' bathymetryFile'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(ES14.6,A)') mu, ' frictionMu'
    WRITE (u, '(A)') 'True adaptive_mesh'
    WRITE (u, '(A)') '0.01 dtM'
    WRITE (u, '(A)') '0.03 TMax'
    WRITE (u, '(A,A)') TRIM(motion_path), ' motionFile'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px L1N1px FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_dynamic_finite_bathymetry_deck

  SUBROUTINE write_finite_friction_motion_file(path)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    ! Row 1 intentionally differs from the deck fairlead and carries nonzero v/a:
    ! the Hermite contact predictor must be refreshed after this state is committed.
    WRITE (u, '(A)') '0.00 2 40.005 0.0 -69.8 0.5 0.0 -0.1 0.0 0.0 0.2'
    WRITE (u, '(A)') '0.01 2 40.01 0.0 -69.8 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.02 2 40.02 0.0 -69.8 1.0 0.0 0.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '0.03 2 40.03 0.0 -69.8 1.0 0.0 0.0 0.0 0.0 0.0'
    CLOSE (u)
  END SUBROUTINE write_finite_friction_motion_file

  SUBROUTINE write_multisec_deck(path)
    !! ONE line, TWO sections of the SAME type "chain" with DIFFERENT mesh (18 + 27 segs);
    !! total 410 m as the single deck but a different, finer mesh -> mesh-consistent tension.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 chain as one line, two same-type sections, different mesh'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 180.0 18'
    WRITE (u, '(A)') '1 chain 230.0 27'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_multisec_deck

  SUBROUTINE write_idmap_deck(path)
    !! WD0050 chain with non-contiguous, out-of-order ids: anchor = point 20, fairlead =
    !! point 10, line id 7. Exercises external-id -> array-index mapping (points/lines/channels).
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 chain, non-contiguous out-of-order ids'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '20 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '10 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '7 10 20 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '7 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen7 AnchTen7'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_idmap_deck

  SUBROUTINE write_reversed_deck(path)
    !! WD0050 chain in stock MoorDyn anchor-first order: point 1 = Fixed anchor
    !! [400,0,-50], point 2 = Coupled fairlead [0,0,0], line NodeA=1 NodeB=2. The
    !! parser normalizes this into the CableDyn convention (End A = fairlead), so
    !! the solution must match the fairlead-first deck exactly.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'WD0050 chain, legacy anchor-first endpoints'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_reversed_deck

  SUBROUTINE write_stock_deck(path, with_dtm, with_seabed, wavekin_val)
    !! The WD0050 chain written in the stock MoorDyn coupled-deck dialect: title
    !! banner + free-text + Echo preamble, stock LINE TYPES header (Cd Ca CdAx CaAx
    !! column order, so the data row carries Ca_n in column 8), 9-column POINTS with
    !! a Vessel fairlead, a stock 7-column LINES row in anchor-first order (implicit
    !! single SECTIONS row), OPTIONS rows with trailing commentary including the
    !! dynamic-relaxation IC class, WriteLog/dtOut, and WaveKin/Currents switches,
    !! and an END-terminated one-channel-per-row OUTPUTS list. Physically identical
    !! to write_single_deck (cdn=1.37, cdt=0.64, can=1.0, cat=0.0).
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(IN) :: with_dtm, with_seabed
    INTEGER, INTENT(IN) :: wavekin_val
    INTEGER :: u, ios
    CHARACTER(8) :: wk
    WRITE (wk, '(I0)') wavekin_val
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '--------------------- MoorDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'WD0050 chain written in the stock MoorDyn coupled-deck dialect'
    WRITE (u, '(A)') 'FALSE    Echo      - echo the input file data (flag)'
    WRITE (u, '(A)') '----------------------- LINE TYPES ------------------------------------------'
    WRITE (u, '(A)') 'Name  Diam  MassDen  EA       BA/-zeta  EI    Cd    Ca    CdAx   CaAx'
    WRITE (u, '(A)') '(-)   (m)   (kg/m)   (N)      (N-s/-)   (-)   (-)   (-)   (-)    (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 1.0 0.64 0.0'
    WRITE (u, '(A)') '---------------------- POINTS --------------------------------'
    WRITE (u, '(A)') 'ID   Type      X         Y       Z       M    V    CdA   CA'
    WRITE (u, '(A)') '(-)  (-)      (m)       (m)     (m)    (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1   Fixed   400.0    0.0   -50.0     0    0    0    0'
    WRITE (u, '(A)') '2   Vessel    0.0    0.0     0.0     0    0    0    0'
    WRITE (u, '(A)') '---------------------- LINES --------------------------------------'
    WRITE (u, '(A)') 'ID  LineType  AttachA   AttachB  UnstrLen  NumSegs  Outputs'
    WRITE (u, '(A)') '(-)   (-)       (-)       (-)      (m)       (-)      (-)'
    WRITE (u, '(A)') '1     chain      1         2     410.0      41        -'
    WRITE (u, '(A)') '---------------------- SOLVER OPTIONS ---------------------------------------'
    IF (with_dtm) THEN
      WRITE (u, '(A)') '0.001    dtM       - time step to use in mooring integration (s)'
    END IF
    WRITE (u, '(A)') 'RK4      tScheme   - time integration scheme (stock; CableDyn is implicit)'
    WRITE (u, '(A)') '9.80665  g         - gravity (m/s^2)'
    WRITE (u, '(A)') '1025.0   rhoW      - water density (kg/m^3)'
    IF (with_seabed) THEN
      WRITE (u, '(A)') '50.0     WtrDpth   - water depth (m)'
      WRITE (u, '(A)') '1.0e5    kBot      - bottom stiffness (Pa/m)'
    END IF
    WRITE (u, '(A)') '1.0      dtIC      - time interval for analyzing convergence during IC gen (s)'
    WRITE (u, '(A)') '60.0     TmaxIC    - max time for ic gen (s)'
    WRITE (u, '(A)') '4.0      CdScaleIC - factor by which to scale drag coefficients during dynamic relaxation (-)'
    WRITE (u, '(A)') '0.001    threshIC  - threshold for IC convergence (-)'
    WRITE (u, '(A)') '1        WriteLog  - log verbosity (-)'
    WRITE (u, '(A)') '0.05     dtOut     - output file time step (s)'
    WRITE (u, '(A)') TRIM(wk)//'        WaveKin   - wave kinematics source (0 none)'
    WRITE (u, '(A)') '0        WaterKin  - MoorDyn-F water-kinematics selector (0 none)'
    WRITE (u, '(A)') '0        Currents  - current source (0 none)'
    WRITE (u, '(A)') '------------------------ OUTPUTS --------------------------------------------'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') 'AnchTen1'
    WRITE (u, '(A)') 'END'
    WRITE (u, '(A)') '------------------------- need this line --------------------------------------'
    CLOSE (u)
  END SUBROUTINE write_stock_deck

  SUBROUTINE write_comment_deck(path)
    !! WD0050 single deck with legacy-style `--` comment lines (whole-line + inside
    !! OPTIONS and OUTPUTS) -> they are stripped, the deck parses, same tensions as single.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') '-- WD0050 chain with -- comments'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 410.0 41'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '-- environment'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth   -- water depth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') '-- requested channels'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_comment_deck

  SUBROUTINE write_noseabed_deck(path)
    !! A TAUT chain (length 65 m < chord ~67.1 m) with NO WtrDpth -> solves suspended, no
    !! bottom contact, via solve_one_line's no-seabed branch. Proves WtrDpth is optional.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'Taut chain, no seabed (suspended)'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 60.0 0.0 -30.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 65.0 22'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_noseabed_deck

  CHARACTER(900) FUNCTION deck_with_zero_point_id() RESULT(s)
    !! A POINT with id 0 -> fail closed (ids must be >= 1; 0 would alias an empty channel suffix).
    s = 'zero-id'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'0 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 0 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_zero_point_id

  CHARACTER(900) FUNCTION deck_with_bad_output_flag() RESULT(s)
    !! A LINE Outputs field "x" (not p/t/-) -> fail closed (typo guard).
    s = 'bad-flag'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 x'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_bad_output_flag

  CHARACTER(900) FUNCTION deck_with_buoyant_section() RESULT(s)
    !! A net-buoyant line type (dry mass 50 kg/m < displaced ~201 kg/m at d=0.5) -> fail
    !! closed (buoyant / lazy-wave sections are not supported on the static EI=0 path).
    s = 'buoyant'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'buoy 0.5 50.0 1.0e8 -1.0 0.0 1.2 0.5 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 buoy 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')// &
        '1.0e5 kBot'//NEW_LINE('a')//'--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_buoyant_section

  CHARACTER(900) FUNCTION deck_with_held_point_load() RESULT(s)
    !! A Fixed point carrying a non-zero Mass load column (9-col row) -> fail closed
    !! (Mass/Vol/CdA/Ca apply only to Connect/Free points).
    s = 'held-point-load'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z Mass Vol CdA Ca'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'//NEW_LINE('a')// &
        '1 Fixed 400 0 -50 5000 0 0 0'//NEW_LINE('a')// &
        '2 Coupled 0 0 0 0 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_held_point_load

  CHARACTER(900) FUNCTION deck_with_bad_point_channel() RESULT(s)
    !! An OUTPUTS channel "Point2px_raw" (trailing text after the component) -> fail closed.
    s = 'bad-channel'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'Point2px_raw'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_bad_point_channel

  CHARACTER(900) FUNCTION deck_with_duplicate_type() RESULT(s)
    !! Two LINE TYPES sharing the name "chain" -> must fail closed (ambiguous binding).
    s = 'dup-type'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        'chain 0.300 500 2.0e9 -1.0 0.0 1.2 0.5 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_duplicate_type

  CHARACTER(900) FUNCTION deck_with_negative_ei() RESULT(s)
    !! A LINE TYPE with EI < 0 -> must fail closed (not silently solve as EI=0).
    s = 'neg-EI'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 1.674e9 -1.0 -5.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_negative_ei

  CHARACTER(900) FUNCTION deck_with_nonfinite_point() RESULT(s)
    !! An EXTRA Fixed point (3) carrying a NaN Z, requested ONLY through a Point3pz channel
    !! (never a line endpoint, so it never enters the solve) -> must fail closed at validation
    !! rather than write a non-finite value to the .out with CD_DECKDRV_OK.
    s = 'nan-point'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'3 Fixed 10 0 NaN'//NEW_LINE('a')// &
        '--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'Point3pz'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_nonfinite_point

  CHARACTER(900) FUNCTION deck_with_nonfinite_type() RESULT(s)
    !! A LINE TYPE with EA = Inf -> must fail closed (a non-finite property would otherwise
    !! reach the net-buoyant gate, where NaN/Inf comparisons mislead, or the static solve).
    s = 'inf-type'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 Inf -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_nonfinite_type

  CHARACTER(900) FUNCTION deck_with_zero_ea() RESULT(s)
    !! A used LINE TYPE with EA = 0 -> singular axial-stiffness solve; must fail closed
    !! (Diam and EA must be strictly positive where the type is used).
    s = 'zero-ea'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.252 390 0.0 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 410 41'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_zero_ea

  CHARACTER(1200) FUNCTION deck_with_heterogeneous_hydro() RESULT(s)
    !! Composite line with section-varying diameter/Can. The persistent model keeps
    !! these properties at element resolution.
    s = 'heterogeneous-hydro'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chainA 0.252 390 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'//NEW_LINE('a')// &
        'chainB 0.300 500 1.674e9 -1.0 0.0 1.37 0.64 1.2 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 400 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chainA 205 20'//NEW_LINE('a')//'1 chainB 205 21'//NEW_LINE('a')// &
        '--- OPTIONS ---'//NEW_LINE('a')//'9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')// &
        '50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_heterogeneous_hydro

  ! fail-closed deck bodies (single string; expect_badinput writes them verbatim)
  CHARACTER(900) FUNCTION deck_with_bodies() RESULT(s)
    s = 'd'//NEW_LINE('a')//'--- BODIES ---'//NEW_LINE('a')// &
        'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-)'// &
        NEW_LINE('a')//'1 Rigid6 0 0 -2 0 0 0 100 1 0 0 0 0 0'
  END FUNCTION deck_with_bodies

  CHARACTER(900) FUNCTION deck_with_finite_ei() RESULT(s)
    !! A valid single line whose type has EI>0 but no dynamic options -> finite-EI
    !! static decks must fail closed and request dtM/TMax.
    s = 'finite-EI'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'cable 0.35 120 7.0e8 -1.0 1.2e5 1.2 0.05 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 100 0 -50'//NEW_LINE('a')// &
        '2 Coupled 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 cable 120 30'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'50.0 WtrDpth'//NEW_LINE('a')//'1.0e5 kBot'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_finite_ei

  CHARACTER(1100) FUNCTION deck_with_finite_ei_current() RESULT(s)
    !! A dynamic finite-EI line with current uses the translational finite-EI
    !! environmental load bridge.
    s = 'finite-EI-current'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 pcable 70 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')// &
        '0.005 dtM'//NEW_LINE('a')//'0.01 TMax'//NEW_LINE('a')// &
        'uniform 0.1 0.0 0.0 current'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1 AnchTen1 L1N1px L1N6pz L1N6vz Ten1N6'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_finite_ei_current

  CHARACTER(1200) FUNCTION deck_with_finite_ei_wave() RESULT(s)
    !! A dynamic finite-EI line with Airy waves uses the translational finite-EI
    !! environmental load bridge.
    s = 'finite-EI-wave'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 pcable 70 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')//'100.0 WtrDpth'//NEW_LINE('a')// &
        '0.005 dtM'//NEW_LINE('a')//'0.01 TMax'//NEW_LINE('a')// &
        'airy 1.0 1.5 0.0 waves'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1 AnchTen1 L1N1px L1N6pz L1N6vz Ten1N6'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_finite_ei_wave

  CHARACTER(1700) FUNCTION deck_with_finite_ei_lazy_wave() RESULT(s)
    !! The equivalent-buoyancy table creates a net-buoyant finite-EI line and
    !! exercises the cubic-Hermite arch seed.
    s = 'finite-EI-lazy-wave'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'power 0.10 500 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 power 90 64'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')//'100.0 WtrDpth'//NEW_LINE('a')// &
        '0.001 dtM'//NEW_LINE('a')//'0.002 TMax'//NEW_LINE('a')// &
        '--- EQUIVALENT BUOYANCY ---'//NEW_LINE('a')// &
        'LineType Diam SubmergedWeightNpm'//NEW_LINE('a')//'(-) (m) (N/m)'//NEW_LINE('a')// &
        'power 0.50 -1483.0'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1 AnchTen1 L1N1px L1N33pz L1N65pz L1N65vz Ten1N65'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_finite_ei_lazy_wave

  CHARACTER(2200) FUNCTION deck_with_sectioned_finite_ei_lazy_wave() RESULT(s)
    !! Three-section finite-EI cable: heavy top, equivalent-buoyant middle, heavy tail.
    !! This is a static branch/mesh-interface regression (TMax=0); the adjacent
    !! homogeneous and native finite-EI cases exercise the dynamic lifecycle.
    s = 'sectioned-finite-EI-lazy-wave'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'top 0.18 120 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        'float 0.10 500 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        'tail 0.22 180 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 top 19 19'//NEW_LINE('a')//'1 float 35 34'//NEW_LINE('a')//'1 tail 19 19'//NEW_LINE('a')// &
        '--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')//'100.0 WtrDpth'//NEW_LINE('a')// &
        '0.001 dtM'//NEW_LINE('a')//'0.0 TMax'//NEW_LINE('a')// &
        '--- EQUIVALENT BUOYANCY ---'//NEW_LINE('a')// &
        'LineType Diam SubmergedWeightNpm'//NEW_LINE('a')//'(-) (m) (N/m)'//NEW_LINE('a')// &
        'float 0.50 -500.0'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1 AnchTen1 L1N1px L1N37pz L1N73pz L1N73vz Ten1N73'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_sectioned_finite_ei_lazy_wave

  CHARACTER(1300) FUNCTION deck_with_unknown_equivalent_buoyancy() RESULT(s)
    !! Equivalent-buoyancy rows must bind to an existing line type.
    s = 'bad-equivalent-unknown'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'power 0.10 500 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 power 90 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '0.001 dtM'//NEW_LINE('a')//'0.002 TMax'//NEW_LINE('a')// &
        '--- EQUIVALENT BUOYANCY ---'//NEW_LINE('a')// &
        'LineType Diam SubmergedWeightNpm'//NEW_LINE('a')//'(-) (m) (N/m)'//NEW_LINE('a')// &
        'missing 0.50 -100.0'//NEW_LINE('a')//'--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_unknown_equivalent_buoyancy

  CHARACTER(1300) FUNCTION deck_with_bad_equivalent_buoyancy() RESULT(s)
    !! Equivalent-buoyancy rows must not imply negative dry mass per length.
    s = 'bad-equivalent-negative-mass'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'power 0.10 500 8.0e8 0.0 2.0e5 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 power 90 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '0.001 dtM'//NEW_LINE('a')//'0.002 TMax'//NEW_LINE('a')// &
        '--- EQUIVALENT BUOYANCY ---'//NEW_LINE('a')// &
        'LineType Diam SubmergedWeightNpm'//NEW_LINE('a')//'(-) (m) (N/m)'//NEW_LINE('a')// &
        'power 0.50 -10000.0'//NEW_LINE('a')//'--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_bad_equivalent_buoyancy

  CHARACTER(1700) FUNCTION deck_with_native_finite_ei_lazy_wave() RESULT(s)
    !! Native finite-EI line type: explicit GAs/GJ/Irt/Irn for a net-buoyant power cable.
    s = 'native-finite-EI-lazy-wave'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'power 0.50 50 8.0e8 0.0 2.0e5 3.0e8 1.1e5 0.8 1.6 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 power 90 64'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')//'100.0 WtrDpth'//NEW_LINE('a')// &
        '0.001 dtM'//NEW_LINE('a')//'0.002 TMax'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1 AnchTen1 L1N1px L1N33pz L1N65pz L1N65vz Ten1N65'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_native_finite_ei_lazy_wave

  CHARACTER(1200) FUNCTION deck_with_bad_native_finite_ei() RESULT(s)
    !! Explicit finite-EI rows must reject non-positive torsional/shear/inertia fields.
    s = 'bad-native-finite-EI'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'power 0.50 50 8.0e8 0.0 2.0e5 3.0e8 -1.0 0.8 1.6 0.8 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 power 90 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '0.001 dtM'//NEW_LINE('a')//'0.002 TMax'//NEW_LINE('a')//'--- OUTPUTS ---'//NEW_LINE('a')// &
        'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_bad_native_finite_ei

  CHARACTER(1400) FUNCTION deck_with_finite_ei_connect() RESULT(s)
    !! Finite-EI deck dynamics are held-end only; dynamic points must fail closed.
    s = 'finite-EI-connect'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z Mass Vol CdA Ca'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'//NEW_LINE('a')// &
        '1 Fixed 0 0 -80 0 0 0 0'//NEW_LINE('a')// &
        '2 Connect 40 0 -20 20 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 pcable 70 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')// &
        '0.005 dtM'//NEW_LINE('a')//'0.01 TMax'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_finite_ei_connect

  CHARACTER(1800) FUNCTION deck_with_two_moving_end_connection() RESULT(s)
    !! A non-pinned connection on a line whose End B is a Free point (a dynamic point the cubic-Hermite
    !! boundary cannot hold or drive) is refused by name, never run as a pinned end.
    s = 'two-moving-end-connection'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z Mass Vol CdA Ca'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'//NEW_LINE('a')// &
        '1 Free 0 0 -80 20 0 0 0'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20 0 0 0 0'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 pcable 70 5'//NEW_LINE('a')//'--- END CONNECTIONS ---'//NEW_LINE('a')// &
        'LineID End Stiffness EzX EzY EzZ'//NEW_LINE('a')//'(-) (-) (N-m/rad) (-) (-) (-)'//NEW_LINE('a')// &
        '1 A 2.0e4 -1 0 0'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')// &
        '0.005 dtM'//NEW_LINE('a')//'0.01 TMax'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_two_moving_end_connection

  CHARACTER(1800) FUNCTION deck_with_finite_ei_body_mix() RESULT(s)
    !! Finite-EI deck dynamics own only finite-EI line objects; body objects
    !! must not be silently ignored.
    s = 'finite-EI-body-mix'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- BODIES ---'//NEW_LINE('a')// &
        'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'// &
        NEW_LINE('a')//'1 Rigid6 0 0 -30 0 0 0 1000 0.1 0 0 0 0 0 10 10 10'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 pcable 70 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '0.005 dtM'//NEW_LINE('a')//'0.01 TMax'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_finite_ei_body_mix

  CHARACTER(1800) FUNCTION deck_with_finite_ei_rod_mix() RESULT(s)
    !! Finite-EI deck dynamics own only finite-EI line objects; rod objects
    !! must not be silently ignored.
    s = 'finite-EI-rod-mix'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- ROD TYPES ---'//NEW_LINE('a')//'Name Diam Mass Cd Ca CdEnd CaEnd'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (-) (-) (-) (-)'//NEW_LINE('a')//'rodtype 0.5 100 1.0 1.0 0.0 0.0'//NEW_LINE('a')// &
        '--- RODS ---'//NEW_LINE('a')//'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'//NEW_LINE('a')// &
        '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'//NEW_LINE('a')// &
        '1 rodtype Free 0 0 -10 0 0 -20 1 -'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Fixed 0 0 -80'//NEW_LINE('a')// &
        '2 Coupled 40 0 -20'//NEW_LINE('a')//'--- LINES ---'//NEW_LINE('a')// &
        'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 2 1 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 pcable 70 5'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '0.005 dtM'//NEW_LINE('a')//'0.01 TMax'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_finite_ei_rod_mix

  CHARACTER(1500) FUNCTION deck_with_rigid6_connect() RESULT(s)
    !! Mixed Rigid6 and independently integrated Connect/Free points must fail closed.
    s = 'rigid6-connect'//NEW_LINE('a')//'--- LINE TYPES ---'//NEW_LINE('a')// &
        'Name Diam Mass EA BA EI Cdn Cdt Can Cat'//NEW_LINE('a')// &
        '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'//NEW_LINE('a')// &
        'chain 0.10 100 1.0e8 0.0 0.0 1.0 0.0 1.0 0.0'//NEW_LINE('a')// &
        '--- BODIES ---'//NEW_LINE('a')// &
        'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)'// &
        NEW_LINE('a')//'1 Rigid6 0 0 0 0 0 0 100 0.1 0 0 0 0 0 10 10 10'//NEW_LINE('a')// &
        '--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z Rot1 Rot2 Rot3 Mass Vol CdA Ca'//NEW_LINE('a')// &
        '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (m2) (-)'//NEW_LINE('a')// &
        '1 Body1 0 0 -1 0 0 0 0 0 0 0'//NEW_LINE('a')// &
        '2 Connect 30 0 -30 0 0 0 20 0 0 0'//NEW_LINE('a')// &
        '--- LINES ---'//NEW_LINE('a')//'ID NodeA NodeB Outputs'//NEW_LINE('a')//'(-) (-) (-) (-)'//NEW_LINE('a')// &
        '1 1 2 -'//NEW_LINE('a')//'--- SECTIONS ---'//NEW_LINE('a')// &
        'LineID LineType Length NumSegs'//NEW_LINE('a')//'(-) (-) (m) (-)'//NEW_LINE('a')// &
        '1 chain 40 4'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '9.80665 g'//NEW_LINE('a')//'1025.0 rhoW'//NEW_LINE('a')// &
        '0.005 dtM'//NEW_LINE('a')//'0.01 TMax'//NEW_LINE('a')// &
        '--- OUTPUTS ---'//NEW_LINE('a')//'FairTen1 Point2pz'//NEW_LINE('a')//'--- end ---'
  END FUNCTION deck_with_rigid6_connect

  CHARACTER(900) FUNCTION deck_with_connect() RESULT(s)
    s = 'connect'//NEW_LINE('a')//'--- POINTS ---'//NEW_LINE('a')//'ID Type X Y Z'// &
        NEW_LINE('a')//'(-) (-) (m) (m) (m)'//NEW_LINE('a')//'1 Connect 50 0 -30'
  END FUNCTION deck_with_connect

  CHARACTER(900) FUNCTION deck_with_bad_keyword() RESULT(s)
    s = 'badkw'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')//'9.81 gravvity'
  END FUNCTION deck_with_bad_keyword

  CHARACTER(900) FUNCTION deck_with_bad_dynamic_solver() RESULT(s)
    s = 'baddynsolver'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        'dynamic_solver -1.0e-8 1.0e-14 30 8'
  END FUNCTION deck_with_bad_dynamic_solver

  CHARACTER(900) FUNCTION deck_with_bad_modified_newton() RESULT(s)
    s = 'badmodnewton'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        'maybe modified_newton'
  END FUNCTION deck_with_bad_modified_newton

  CHARACTER(900) FUNCTION deck_with_bad_tensile_mode() RESULT(s)
    s = 'badtensile'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        'maybe tensile_safety'
  END FUNCTION deck_with_bad_tensile_mode

  CHARACTER(900) FUNCTION deck_with_bad_tensile_tolerance() RESULT(s)
    s = 'badtentol'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '-1e-6 tensile_strain_tolerance'
  END FUNCTION deck_with_bad_tensile_tolerance

  CHARACTER(900) FUNCTION deck_with_bad_recovery_cap() RESULT(s)
    s = 'badrecovery'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        'NaN recovery_max_substeps'
  END FUNCTION deck_with_bad_recovery_cap

  CHARACTER(900) FUNCTION deck_with_fractional_recovery_cap() RESULT(s)
    s = 'fracrecovery'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')// &
        '4.5 recovery_max_substeps'
  END FUNCTION deck_with_fractional_recovery_cap

  CHARACTER(900) FUNCTION deck_with_ei0_option(row) RESULT(s)
    CHARACTER(*), INTENT(IN) :: row
    s = 'badei0'//NEW_LINE('a')//'--- OPTIONS ---'//NEW_LINE('a')//row
  END FUNCTION deck_with_ei0_option

END PROGRAM test_deck_driver
