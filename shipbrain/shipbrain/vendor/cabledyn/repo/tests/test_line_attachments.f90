! File: tests/test_line_attachments.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_line_attachments
  !! Gates for discrete ATTACHMENTS (buoyancy modules and clumps lumped at nodes of a
  !! cubic-Hermite cable), on a lazy-wave power cable whose 50 m buoyancy section is either
  !! a smeared equivalent line type (Diam 0.29 m, 59.53 kg/m) or the bare cable (Diam 0.16 m,
  !! 36.70 kg/m) carrying modules of the same mass, volume, drag area and added mass per
  !! metre at pitch p:
  !!   1. Static convergence: as p -> 0 (5, 2.5, 1.25 m) the discrete equilibrium converges
  !!      to the smeared one, at second order in p.
  !!   2. Local curvature: at p = 5 m the curvature peaks at the modules and dips between
  !!      them; halving the element length changes the peak by less than 2 %.
  !!   3. Dynamics: under fairlead heave the discrete cable runs stably and its fairlead
  !!      tension follows the smeared cable's.
  !!   4. Deck grammar: series expansion, stock endpoint order, and fail-closed rows.
  !!   5. Deck current (uniform, profile): convergence to EQUIVALENT BUOYANCY and no drift at rest.
  !!   6. Coupled route (the OpenFAST aggregate): held SeaState-style kinematics at the
  !!      attachment nodes, and a bit-identical checkpoint restart.
  !!   7. Acceptance of a fallback attachment state (CD_Attachment_Discrete_Verdict): a slope
  !!      jump beside an attachment node passes the kink limit; the same bend away from it, a
  !!      compressed state under tensile_safety and an unstable state fail closed by name.
  !!   8. A neutral line whose length equals its span (straight at zero strain, no weight, no
  !!      tension) with neutral modules (m = rho V) or with a drag area alone, pinned or clamped:
  !!      the static start converges and stays straight and unloaded (fairlead tension below
  !!      1e-3 N). Its residual sits at the round-off floor of the axial forces, about
  !!      eps max(EA/l0) |x| = 9e-8 N here, above tol x 1 N, where the polish stalled at every
  !!      load step; the convergence scale now keeps tol x scale at 16 times that floor. Heavy
  !!      modules on the same line (which carry it into tension) still solve. Restrained in
  !!      torsion (GJ 5e4 N m^2, a quarter turn at End B), the neutral-module line carries the
  !!      torque GJ Phi / L to 1e-6. The same with End B on a Coupled point (two moving ends):
  !!      neutral modules and a drag area alone stay unloaded, the line restrained in torsion at
  !!      both ends carries GJ Phi / L to 1e-6, and a span 1e-8 longer than the line (two moving
  !!      ends whose chord exceeds the length, a 0.1 N tension that the tension bound of the
  !!      convergence scale alone put below the floor) carries EA (chord / L - 1) to 2e-6 N
  !!      (measured 2.2e-7 N). Restrained in torsion at End A only (End B free in torsion), the
  !!      line starts untwisted. Each of these failed in the polish before the floor.
  !!   9. A bending-pinned cable from a moored body (a keel point, 45 deg towards a Fixed anchor)
  !!      carrying a 2 t clump 50 m along it, with and without its END CONNECTIONS row: the body
  !!      static solve balances the body on the cubic-Hermite cable's end loads (the passes of the
  !!      connected ends), so the body holds its static pose over 5 s of the march to 1e-5 m and
  !!      1e-4 deg (measured 0, the output's 8 digits). The cable without bending stiffness that
  !!      the body solve otherwise takes for a pinned line does not carry the clump: the body
  !!      started at the pose of the line without it and drifted by up to 2.9e-2 m and 0.20 deg.
  !!  10. The pinned cable with the clump of case 9 from a Point3 buoy, where a finite-EI end is not
  !!      supported: the deck is refused by that name. Before, the body passes of case 9 took the
  !!      line and refused it as a clamped or elastic END CONNECTION on a body that is not Rigid6,
  !!      which the deck does not have.
  !!  11. A free buoyant spar rod (10 m, 1 m diameter) on four taut legs with a finite-EI cable
  !!      pinned at its upper end carrying a 1500 kg clump 25 m along it; bodyIC static: the body
  !!      static passes converge (6, on the core cable that carries the clump smeared) and the rod
  !!      holds its static pose over 1 s of the march (dtM 0.01 s) to 1e-6 m (measured 1e-7) and
  !!      the leg tensions to 1e-5 (measured 2.9e-7). Before, the plain passes diverged (end-load
  !!      change 2.9 of the force scale after 60 passes) and the deck stopped.
  !!  12. The spar rod of case 11 with the cable and no clump: the bending share of the pinned
  !!      cable's end force is in the rod's static balance too, so the rod holds its pose over
  !!      1 s to 1e-6 m (measured 0) and its leg tensions to 1e-5 (measured 3.8e-8). Before, the
  !!      body passes left a pinned line without ATTACHMENTS to the core's cable without bending
  !!      stiffness: the rod started 5.7e-2 m off its equilibrium and its top moved 1.8e-4 m in 0.1 s
  !!      (dtM 0.01 s; 7e-2 m and a 2.3 % leg tension change in 3 s with the implicit object
  !!      coupling).
  !!  13. The static start of case 11 does not hinge on round-off: with the anchor of a leg moved
  !!      by 1 ulp either way (x = 25 m -+ 3.6e-15 m) the passes converge to the same rod pose to
  !!      1e-9 m (measured 0) in at most 10 passes (measured 6). Before, the Anderson fit kept
  !!      columns of round-off size and the passes converged in 26, or ran out after 60 (the
  !!      relative end-load change 1.5) or turned the rod over, by that 1 ulp.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK, CD_Attachment_Discrete_Verdict, &
                                 CD_Body_Static_Pass_Limit
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_PINNED
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_GetMovingPointMesh, &
                                         CD_AGG_UpdateStates_Moving, CD_AGG_Step_Moving, CD_AGG_CalcOutput, &
                                         CD_AGG_End, CD_AGG_NFluidNodes, CD_AGG_GetFluidNodePositions, &
                                         CD_AGG_SetFluidFields, CD_AGG_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_MirrorSize, CD_HFMF_PackMirror, CD_HFMF_UnpackMirror, CD_HFMF_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp
  REAL(wp), PARAMETER :: DM = 59.53_wp - 36.70_wp                        ! module mass per metre
  REAL(wp), PARAMETER :: DV = 0.25_wp*PI*(0.29_wp**2 - 0.16_wp**2)       ! module volume per metre
  REAL(wp), PARAMETER :: DCDA = 1.2_wp*(0.29_wp - 0.16_wp)               ! module normal drag area per metre
  REAL(wp), PARAMETER :: DCDAX = PI*0.1_wp*(0.29_wp - 0.16_wp)           ! module axial drag area per metre
  INTEGER :: nfail
  nfail = 0

  CALL case_static_convergence()
  CALL case_curvature_peaks()
  CALL case_dynamics()
  CALL case_current('uniform', 'uniform 0.6 0.0 0.0 current')
  CALL case_current_friction()
  CALL case_current('profile', 'profile -60.0 0.2 0.3 0.0 0.0 0.5 0.4 0.0 current')
  CALL case_grammar()
  CALL case_coupled()
  CALL case_fallback_verdict()
  CALL case_zero_strain()
  CALL case_zero_strain_moving()
  CALL case_pinned_body_clump()
  CALL case_pinned_point3_clump()
  CALL case_pinned_rod_clump(.TRUE.)
  CALL case_pinned_rod_clump(.FALSE.)
  CALL case_pinned_rod_roundoff()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: discrete line attachments'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE case_zero_strain()
    !! 8: a 100 m neutral line (Diam 0.2 m, mass rho pi d^2/4, EA 1e7, EI 1e6) between a Coupled
    !! point and a Fixed one 100 m apart, 40 elements, TMax 0, with three modules at 25 m pitch.
    CHARACTER(160) :: trow
    ! the module rows: neutral (m = rho V), a drag area alone, heavy
    CHARACTER(*), PARAMETER :: ROW1 = '1 25.0:25.0:75.0 102.5 0.1 0.0 0.0 0.0'
    CHARACTER(*), PARAMETER :: ROW2 = '1 25.0:25.0:75.0 0.0 0.0 0.1 0.0 0.0'
    CHARACTER(*), PARAMETER :: ROW3 = '1 25.0:25.0:75.0 200.0 0.1 0.0 0.0 0.0'
    CHARACTER(64) :: rows(3)
    CHARACTER(16) :: label(3)
    REAL(wp), ALLOCATABLE :: d(:, :)
    INTEGER :: k, iend, u, nrow
    LOGICAL :: ok
    CHARACTER(1024) :: msg
    CHARACTER(32) :: root
    rows = [CHARACTER(64) :: ROW1, ROW2, ROW3]
    label = [CHARACTER(16) :: 'neutral modules', 'drag area alone', 'heavy modules']
    WRITE (trow, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, ' 1.0e7 0.0 1.0e6 0.0 0.0 0.0 0.0'
    DO iend = 1, 2
      DO k = 1, 3
        WRITE (root, '(A,I0,A,I0)') 'att_span_', k, '_', iend
        OPEN (NEWUNIT=u, FILE=TRIM(root)//'.dat', STATUS='replace', ACTION='write')
        WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
        WRITE (u, '(A)') 'neutral line of the length of its span with attachments'
        WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
        WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
        WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
        WRITE (u, '(A)') TRIM(trow)
        WRITE (u, '(A)') '--------------------- POINTS -------------------------------------------------'
        WRITE (u, '(A)') 'ID Type X Y Z'
        WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
        WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0'
        WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0'
        WRITE (u, '(A)') '--------------------- LINES --------------------------------------------------'
        WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
        WRITE (u, '(A)') '(-) (-) (-) (-)'
        WRITE (u, '(A)') '1 1 2 -'
        WRITE (u, '(A)') '--------------------- SECTIONS -----------------------------------------------'
        WRITE (u, '(A)') 'LineID LineType Length NumSegs'
        WRITE (u, '(A)') '(-) (-) (m) (-)'
        WRITE (u, '(A)') '1 cab 100.0 40'
        WRITE (u, '(A)') '--------------------- ATTACHMENTS -------------------------------------------'
        WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
        WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
        WRITE (u, '(A)') TRIM(rows(k))
        IF (iend == 2) THEN
          WRITE (u, '(A)') '--------------------- END CONNECTIONS ----------------------------------------'
          WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
          WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
          WRITE (u, '(A)') '1 A Rigid 1 0 0'
          WRITE (u, '(A)') '1 B Rigid 1 0 0'
        END IF
        WRITE (u, '(A)') '--------------------- OPTIONS ------------------------------------------------'
        WRITE (u, '(A)') '9.80665 g'
        WRITE (u, '(A)') '1025.0 rhoW'
        WRITE (u, '(A)') '0.1 dtM'
        WRITE (u, '(A)') '0.0 TMax'
        WRITE (u, '(A)') '--------------------- OUTPUTS ------------------------------------------------'
        WRITE (u, '(A)') 'FairTen1'
        WRITE (u, '(A)') '--------------------- END ----------------------------------------------------'
        CLOSE (u)
        CALL run(TRIM(root)//'.dat', TRIM(root), ok, msg)
        CALL require(ok, '8 '//TRIM(label(k))//MERGE(' (clamped)', ' (pinned) ', iend == 2)// &
                     ': the static start of a line as long as its span converges: '//TRIM(msg))
        IF (.NOT. ok) CYCLE
        CALL read_out(TRIM(root)//'.out', d, nrow, 2)
        CALL require(nrow >= 1, '8 '//TRIM(label(k))//': static row written')
        IF (nrow < 1) CYCLE
        WRITE (*, '(A,A,A,ES12.4,A)') '  8 ', TRIM(label(k)), MERGE(' (clamped)', ' (pinned) ', iend == 2), &
          d(2, 1), ' N fairlead tension'
        IF (k < 3) CALL require(ABS(d(2, 1)) < 1.0e-3_wp, '8 '//TRIM(label(k))//': the line stays unloaded')
        IF (k == 3) CALL require(d(2, 1) > 1.0e3_wp, '8 heavy modules: the line is carried into tension')
      END DO
    END DO
    ! restrained in torsion, pinned in bending, a quarter turn at End B
    WRITE (trow, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'
    root = 'att_span_torsion'
    OPEN (NEWUNIT=u, FILE=TRIM(root)//'.dat', STATUS='replace', ACTION='write')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'neutral line of the length of its span with neutral attachments, restrained in torsion'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(trow)
    WRITE (u, '(A)') '--------------------- POINTS -------------------------------------------------'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Fixed 100.0 0.0 -50.0'
    WRITE (u, '(A)') '--------------------- LINES --------------------------------------------------'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--------------------- SECTIONS -----------------------------------------------'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    WRITE (u, '(A)') '--------------------- ATTACHMENTS -------------------------------------------'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
    WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
    WRITE (u, '(A)') TRIM(rows(1))
    WRITE (u, '(A)') '--------------------- END CONNECTIONS ----------------------------------------'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    WRITE (u, '(A)') '1 A Pinned 1 0 0 Rigid 0 0 1 0'
    WRITE (u, '(A)') '1 B Pinned 1 0 0 Rigid 0 0 1 90'
    WRITE (u, '(A)') '--------------------- OPTIONS ------------------------------------------------'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.1 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--------------------- OUTPUTS ------------------------------------------------'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') '--------------------- END ----------------------------------------------------'
    CLOSE (u)
    CALL run(TRIM(root)//'.dat', TRIM(root), ok, msg)
    CALL require(ok, '8 torsion: the static start of a line as long as its span converges: '//TRIM(msg))
    IF (.NOT. ok) RETURN
    CALL read_out(TRIM(root)//'.out', d, nrow, 3)
    CALL require(nrow >= 1, '8 torsion: static row written')
    IF (nrow < 1) RETURN
    WRITE (*, '(A,ES16.8,A,ES16.8,A)') '  8 torsion: torque ', d(3, 1), ' N m, GJ Phi / L ', &
      5.0e4_wp*0.5_wp*PI/100.0_wp, ' N m'
    CALL require(ABS(d(3, 1) - 5.0e4_wp*0.5_wp*PI/100.0_wp) <= 1.0e-6_wp*5.0e4_wp*0.5_wp*PI/100.0_wp, &
                 '8 torsion: the straight line carries GJ Phi / L')
  END SUBROUTINE case_zero_strain

  SUBROUTINE case_zero_strain_moving()
    !! 8 (continued): the line of case 8 with End B on a Coupled point (two moving ends), and
    !! restrained in torsion at End A only.
    CHARACTER(*), PARAMETER :: NEUTRAL = '1 25.0:25.0:75.0 102.5 0.1 0.0 0.0 0.0'
    CHARACTER(*), PARAMETER :: DRAG = '1 25.0:25.0:75.0 0.0 0.0 0.1 0.0 0.0'
    CHARACTER(*), PARAMETER :: TORS_HDR = 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    CHARACTER(*), PARAMETER :: TORS_UNITS = '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: chord, ten
    INTEGER :: nrow
    LOGICAL :: ok
    ! two moving ends: neutral modules, a drag area alone
    CALL span_deck('att_span_b1', 'Coupled', '100.0', NEUTRAL, .FALSE., [CHARACTER(64) ::], ['FairTen1'])
    CALL span_run('att_span_b1', 'two moving ends, neutral modules', 2, d, nrow, ok)
    IF (ok) CALL require(ABS(d(2, 1)) < 1.0e-3_wp, '8 two moving ends, neutral modules: the line stays unloaded')
    CALL span_deck('att_span_b2', 'Coupled', '100.0', DRAG, .FALSE., [CHARACTER(64) ::], ['FairTen1'])
    CALL span_run('att_span_b2', 'two moving ends, drag area alone', 2, d, nrow, ok)
    IF (ok) CALL require(ABS(d(2, 1)) < 1.0e-3_wp, '8 two moving ends, drag area alone: the line stays unloaded')
    ! two moving ends whose chord exceeds the length by 1e-8: tension EA (chord/L - 1) = 0.1 N
    CALL span_deck('att_span_b3', 'Coupled', '100.000001', NEUTRAL, .FALSE., [CHARACTER(64) ::], ['FairTen1'])
    CALL span_run('att_span_b3', 'two moving ends, chord above the length', 2, d, nrow, ok)
    IF (ok) THEN
      chord = 100.000001_wp
      ten = 1.0e7_wp*(chord/100.0_wp - 1.0_wp)
      WRITE (*, '(A,ES16.8,A,ES16.8,A)') '  8 two moving ends, chord above the length: tension ', d(2, 1), &
        ' N, EA (chord/L - 1) ', ten, ' N'
      CALL require(ABS(d(2, 1) - ten) <= 2.0e-6_wp, '8 two moving ends, chord above the length: EA (chord/L - 1)')
    END IF
    ! two moving ends restrained in torsion at both ends, a quarter turn at End B
    CALL span_deck('att_span_b4', 'Coupled', '100.0', NEUTRAL, .TRUE., &
                   [CHARACTER(80) :: TORS_HDR, TORS_UNITS, '1 A Pinned 1 0 0 Rigid 0 0 1 0', &
                    '1 B Pinned 1 0 0 Rigid 0 0 1 90'], ['FairTen1', 'Torq1N1 '])
    CALL span_run('att_span_b4', 'two moving ends, torsion', 3, d, nrow, ok)
    IF (ok) THEN
      WRITE (*, '(A,ES16.8,A,ES16.8,A)') '  8 two moving ends, torsion: torque ', d(3, 1), ' N m, GJ Phi / L ', &
        5.0e4_wp*0.5_wp*PI/100.0_wp, ' N m'
      CALL require(ABS(d(3, 1) - 5.0e4_wp*0.5_wp*PI/100.0_wp) <= 1.0e-6_wp*5.0e4_wp*0.5_wp*PI/100.0_wp, &
                   '8 two moving ends, torsion: the straight line carries GJ Phi / L')
    END IF
    ! restrained in torsion at End A only
    CALL span_deck('att_span_b5', 'Fixed', '100.0', NEUTRAL, .TRUE., &
                   [CHARACTER(80) :: TORS_HDR, TORS_UNITS, '1 A Pinned 1 0 0 Rigid 0 0 1 0', &
                    '1 B Pinned 1 0 0 Free 0 0 1 0'], ['FairTen1', 'Twist1  '])
    CALL span_run('att_span_b5', 'torsion at End A only', 3, d, nrow, ok)
    IF (ok) THEN
      WRITE (*, '(A,ES12.4,A,ES12.4,A)') '  8 torsion at End A only: tension ', d(2, 1), ' N, twist ', d(3, 1), ' deg'
      CALL require(ABS(d(2, 1)) < 1.0e-3_wp .AND. ABS(d(3, 1)) < 1.0e-6_wp, &
                   '8 torsion at End A only: the line starts straight, unloaded and untwisted')
    END IF
  END SUBROUTINE case_zero_strain_moving

  SUBROUTINE span_deck(root, end_b_type, end_b_x, att_row, torsion, endconn_rows, outputs)
    !! The neutral 100 m line of case 8 (40 elements, TMax 0) from a Coupled End A at
    !! (0, 0, -50) m to End B of type end_b_type at (end_b_x, 0, -50) m, with one ATTACHMENTS row;
    !! torsion: the line type with GJ 5e4 N m^2 (and its END CONNECTIONS rows).
    CHARACTER(*), INTENT(IN) :: root, end_b_type, end_b_x, att_row
    LOGICAL, INTENT(IN) :: torsion
    CHARACTER(*), INTENT(IN) :: endconn_rows(:), outputs(:)
    CHARACTER(160) :: trow
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=root//'.dat', STATUS='replace', ACTION='write')
    WRITE (u, '(A)') '--------------------- CableDyn Input File ------------------------------------'
    WRITE (u, '(A)') 'neutral line of the length of its span with attachments'
    WRITE (u, '(A)') '--------------------- LINE TYPES ---------------------------------------------'
    IF (torsion) THEN
      WRITE (trow, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, &
        ' 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-12 0.0 0.0 0.0 0.0'
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    ELSE
      WRITE (trow, '(A,ES24.16,A)') 'cab 0.2 ', 1025.0_wp*0.25_wp*PI*0.04_wp, ' 1.0e7 0.0 1.0e6 0.0 0.0 0.0 0.0'
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    END IF
    WRITE (u, '(A)') TRIM(trow)
    WRITE (u, '(A)') '--------------------- POINTS -------------------------------------------------'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -50.0'
    WRITE (u, '(A)') '2 '//end_b_type//' '//end_b_x//' 0.0 -50.0'
    WRITE (u, '(A)') '--------------------- LINES --------------------------------------------------'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--------------------- SECTIONS -----------------------------------------------'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 cab 100.0 40'
    WRITE (u, '(A)') '--------------------- ATTACHMENTS -------------------------------------------'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
    WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
    WRITE (u, '(A)') att_row
    IF (SIZE(endconn_rows) > 0) THEN
      WRITE (u, '(A)') '--------------------- END CONNECTIONS ----------------------------------------'
      DO i = 1, SIZE(endconn_rows)
        WRITE (u, '(A)') TRIM(endconn_rows(i))
      END DO
    END IF
    WRITE (u, '(A)') '--------------------- OPTIONS ------------------------------------------------'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.1 dtM'
    WRITE (u, '(A)') '0.0 TMax'
    WRITE (u, '(A)') '--------------------- OUTPUTS ------------------------------------------------'
    DO i = 1, SIZE(outputs)
      WRITE (u, '(A)') TRIM(outputs(i))
    END DO
    WRITE (u, '(A)') '--------------------- END ----------------------------------------------------'
    CLOSE (u)
  END SUBROUTINE span_deck

  SUBROUTINE span_run(root, label, ncol, d, nrow, ok)
    !! Run a span_deck deck and read its static row (ncol columns, time first).
    CHARACTER(*), INTENT(IN) :: root, label
    INTEGER, INTENT(IN) :: ncol
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: d(:, :)
    INTEGER, INTENT(OUT) :: nrow
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(1024) :: msg
    nrow = 0
    CALL run(root//'.dat', root, ok, msg)
    CALL require(ok, '8 '//label//': the static start of a line as long as its span converges: '//TRIM(msg))
    IF (.NOT. ok) RETURN
    CALL read_out(root//'.out', d, nrow, ncol)
    ok = nrow >= 1
    CALL require(ok, '8 '//label//': static row written')
    IF (ok) WRITE (*, '(A,A,A,ES12.4,A)') '  8 ', label, ': ', d(2, 1), ' N fairlead tension'
  END SUBROUTINE span_run

  SUBROUTINE case_pinned_body_clump()
    !! 9: a buoyant body (hydrostatic C44 = C55 = 2e6 N m/rad) on three EI = 0 legs, with a
    !! finite-EI cable from its keel point at 45 deg towards a Fixed anchor, pinned in bending at
    !! the body, carrying a 2 t clump 50 m along it; bodyIC static, 5 s of the march (dtM 0.05 s).
    INTEGER :: u, k, nrow
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: dpos, dpitch
    LOGICAL :: ok
    CHARACTER(1024) :: msg
    CHARACTER(32) :: root
    DO k = 1, 2
      root = MERGE('att_body_pin_row', 'att_body_pin    ', k == 1)
      OPEN (NEWUNIT=u, FILE=TRIM(root)//'.dat', STATUS='REPLACE', ACTION='WRITE')
      WRITE (u, '(A)') 'pinned cable with a clump on a moored body'
      WRITE (u, '(A)') '--- LINE TYPES ---'
      WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
      WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
      WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
      WRITE (u, '(A)') 'cab 0.2 60.0 5.0e8 -1.0 2.0e4 1.2 0.0 1.0 0.0'
      WRITE (u, '(A)') '--- BODIES ---'
      WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
      WRITE (u, '(A)') '1 Rigid6 0 0 -20 0 0 0 2.0e4 40.0 0.0 2.0e6 2.0e6 8.0 0.5 3.5e4 3.5e4 3.5e4'
      WRITE (u, '(A)') '--- POINTS ---'
      WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
      WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
      WRITE (u, '(A)') '1 Body1 1.5 0.0 -2.0 0 0 0 0'
      WRITE (u, '(A)') '2 Body1 -0.75 1.299 -2.0 0 0 0 0'
      WRITE (u, '(A)') '3 Body1 -0.75 -1.299 -2.0 0 0 0 0'
      WRITE (u, '(A)') '4 Fixed 40.0 0.0 -100.0 0 0 0 0'
      WRITE (u, '(A)') '5 Fixed -20.0 34.641 -100.0 0 0 0 0'
      WRITE (u, '(A)') '6 Fixed -20.0 -34.641 -100.0 0 0 0 0'
      WRITE (u, '(A)') '7 Body1 0.0 0.0 -3.0 0 0 0 0'
      WRITE (u, '(A)') '8 Fixed -40.0 0.0 -100.0 0 0 0 0'
      WRITE (u, '(A)') '--- LINES ---'
      WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
      WRITE (u, '(A)') '(-) (-) (-) (-)'
      WRITE (u, '(A)') '1 1 4 -'
      WRITE (u, '(A)') '2 2 5 -'
      WRITE (u, '(A)') '3 3 6 -'
      WRITE (u, '(A)') '4 7 8 -'
      WRITE (u, '(A)') '--- SECTIONS ---'
      WRITE (u, '(A)') 'LineID LineType Length NumSegs'
      WRITE (u, '(A)') '(-) (-) (m) (-)'
      WRITE (u, '(A)') '1 poly 86.85 20'
      WRITE (u, '(A)') '2 poly 86.85 20'
      WRITE (u, '(A)') '3 poly 86.85 20'
      WRITE (u, '(A)') '4 cab 100.0 50'
      WRITE (u, '(A)') '--- ATTACHMENTS ---'
      WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
      WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
      WRITE (u, '(A)') '4 50.0 2000.0 0.0 0.0 0.0'
      IF (k == 1) THEN
        WRITE (u, '(A)') '--- END CONNECTIONS ---'
        WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ'
        WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-)'
        WRITE (u, '(A)') '4 A Pinned -0.7071067811865476 0.0 -0.7071067811865476'
      END IF
      WRITE (u, '(A)') '--- OPTIONS ---'
      WRITE (u, '(A)') '100.0 WtrDpth'
      WRITE (u, '(A)') '9.80665 g'
      WRITE (u, '(A)') '1025.0 rhoW'
      WRITE (u, '(A)') '1.0e5 kBot'
      WRITE (u, '(A)') '1.0e4 cBot'
      WRITE (u, '(A)') '0.05 dtM'
      WRITE (u, '(A)') '5.0 TMax'
      WRITE (u, '(A)') 'static bodyIC'
      WRITE (u, '(A)') 'monolithic bodyScheme'
      WRITE (u, '(A)') '--- OUTPUTS ---'
      WRITE (u, '(A)') 'Body1Px'
      WRITE (u, '(A)') 'Body1Pz'
      WRITE (u, '(A)') 'Body1Ry'
      WRITE (u, '(A)') '--- END ---'
      CLOSE (u)
      CALL run(TRIM(root)//'.dat', TRIM(root), ok, msg)
      CALL require(ok, '9 '//TRIM(root)//': runs: '//TRIM(msg))
      IF (.NOT. ok) CYCLE
      CALL read_out(TRIM(root)//'.out', d, nrow, 4)
      CALL require(nrow >= 101, '9 '//TRIM(root)//': 5 s written')
      IF (nrow < 101) CYCLE
      dpos = MAXVAL(ABS(d(2:3, 1:nrow) - SPREAD(d(2:3, 1), 2, nrow)))
      dpitch = MAXVAL(ABS(d(4, 1:nrow) - d(4, 1)))
      WRITE (*, '(A,A,A,ES10.3,A,ES10.3,A)') '  9 ', TRIM(root), ': body drift over 5 s ', dpos, ' m, pitch ', &
        dpitch, ' deg'
      CALL require(dpos <= 1.0e-5_wp .AND. dpitch <= 1.0e-4_wp, &
                   '9 '//TRIM(root)//': the clump on a pinned cable is in the body''s static balance')
    END DO
  END SUBROUTINE case_pinned_body_clump

  SUBROUTINE case_pinned_point3_clump()
    !! 10: a Point3 buoy (2 t, 10 m^3) on an EI = 0 leg, with the finite-EI cable of case 9 pinned
    !! at it carrying the 2 t clump; bodyIC static.
    INTEGER :: u
    LOGICAL :: ok
    CHARACTER(1024) :: msg
    OPEN (NEWUNIT=u, FILE='att_point3_pin.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'pinned cable with a clump on a Point3 buoy'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cab 0.2 60.0 5.0e8 -1.0 2.0e4 1.2 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- BODIES ---'
    WRITE (u, '(A)') 'ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)'
    WRITE (u, '(A)') '1 Point3 0 0 -20 0 0 0 2.0e3 10.0 0.0 0.0 0.0 8.0 0.5 0 0 0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Body1 0.0 0.0 0.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed 60.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '8 Fixed -60.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 4 -'
    WRITE (u, '(A)') '4 1 8 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 105.0 20'
    WRITE (u, '(A)') '4 cab 110.0 50'
    WRITE (u, '(A)') '--- ATTACHMENTS ---'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
    WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
    WRITE (u, '(A)') '4 50.0 2000.0 0.0 0.0 0.0'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '100.0 WtrDpth'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '1.0 TMax'
    WRITE (u, '(A)') 'static bodyIC'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point1Pz'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
    CALL run('att_point3_pin.dat', 'att_point3_pin', ok, msg)
    WRITE (*, '(2A)') '  10 pinned cable on a Point3 buoy: ', TRIM(msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'Point3 buoy is not supported') > 0, &
                 '10 pinned cable with a clump on a Point3 buoy: refused by that name')
  END SUBROUTINE case_pinned_point3_clump

  SUBROUTINE case_pinned_rod_clump(clump)
    !! 11 (clump) and 12: 1 s of the march of pinned_rod_deck (dtM 0.01 s; the pinned cable is
    !! coupled to the free rod implicitly, test_pinned_cable_light_object).
    LOGICAL, INTENT(IN) :: clump
    INTEGER :: nrow
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: dpos, dten
    LOGICAL :: ok
    CHARACTER(1024) :: msg
    CHARACTER(16) :: root, gate
    root = MERGE('att_rod_pin   ', 'att_rod_pin_no', clump)
    gate = MERGE('11 with a clump', '12 alone       ', clump)
    CALL pinned_rod_deck(TRIM(root), clump, '25.0', '0.01', '1.0')
    CALL run(TRIM(root)//'.dat', TRIM(root), ok, msg)
    CALL require(ok, TRIM(gate)//', a pinned cable on a free rod: runs: '//TRIM(msg))
    IF (.NOT. ok) RETURN
    CALL read_out(TRIM(root)//'.out', d, nrow, 6)
    CALL require(nrow >= 101, TRIM(gate)//', a pinned cable on a free rod: the run written')
    IF (nrow < 101) RETURN
    dpos = MAXVAL(ABS(d(2:3, 1:nrow) - SPREAD(d(2:3, 1), 2, nrow)))
    dten = MAXVAL(ABS(d(4:6, 1:nrow) - SPREAD(d(4:6, 1), 2, nrow))/SPREAD(ABS(d(4:6, 1)), 2, nrow))
    WRITE (*, '(A,A,A,ES10.3,A,ES10.3)') '  ', TRIM(gate), ', a pinned cable on a free rod: rod top drift ', dpos, &
      ' m, rel. leg tension ', dten
    CALL require(dpos <= 1.0e-6_wp .AND. dten <= 1.0e-5_wp, &
                 TRIM(gate)//', a pinned cable on a free rod: the rod starts in the march''s equilibrium')
  END SUBROUTINE case_pinned_rod_clump

  SUBROUTINE case_pinned_rod_roundoff()
    !! 13: the static start of case 11 with leg anchor x = 25 m and 1 ulp either side of it.
    CHARACTER(*), PARAMETER :: X3(3) = ['25.0              ', '24.999999999999996', '25.000000000000004']
    REAL(wp), ALLOCATABLE :: d(:, :)
    REAL(wp) :: p0(2), dmax
    INTEGER :: k, nrow
    LOGICAL :: ok
    CHARACTER(1024) :: msg
    CHARACTER(24) :: root
    dmax = 0.0_wp
    p0 = 0.0_wp
    nrow = 0
    ok = .FALSE.
    ! at most 10 passes
    CALL CD_Body_Static_Pass_Limit(10)
    DO k = 1, 3
      WRITE (root, '(A,I0)') 'att_rod_ulp', k
      CALL pinned_rod_deck(TRIM(root), .TRUE., TRIM(X3(k)), '0.01', '0.0')
      CALL run(TRIM(root)//'.dat', TRIM(root), ok, msg)
      CALL require(ok, '13 '//TRIM(root)//' (anchor x '//TRIM(X3(k))//'): the static start converges: '//TRIM(msg))
      IF (.NOT. ok) EXIT
      CALL read_out(TRIM(root)//'.out', d, nrow, 6)
      CALL require(nrow >= 1, '13 '//TRIM(root)//': static row written')
      IF (nrow < 1) EXIT
      IF (k == 1) p0 = d(2:3, 1)
      dmax = MAX(dmax, MAXVAL(ABS(d(2:3, 1) - p0)))
    END DO
    CALL CD_Body_Static_Pass_Limit(0)
    IF (.NOT. ok .OR. nrow < 1) RETURN
    WRITE (*, '(A,ES10.3,A)') '  13 anchor moved by 1 ulp: rod pose change ', dmax, ' m'
    CALL require(dmax <= 1.0e-9_wp, '13 anchor moved by 1 ulp: the same static start')
  END SUBROUTINE case_pinned_rod_roundoff

  SUBROUTINE pinned_rod_deck(root, clump, x3, dtm, tmax)
    !! The spar rod from z = -30 m to -20 m in 50 m of water, two legs from each end (the first
    !! to an anchor at x = x3), the cable from its upper end towards a Fixed point at
    !! (-40, 0, -50) m, a 1500 kg clump 25 m along it with clump.
    CHARACTER(*), INTENT(IN) :: root, x3, dtm, tmax
    LOGICAL, INTENT(IN) :: clump
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=root//'.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'pinned cable with a clump on a free spar rod'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.10 10.0 2.0e7 -1.0 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') 'cab 0.20 60.0 5.0e8 -1.0 2.0e4 1.2 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- ROD TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx'
    WRITE (u, '(A)') '(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'spar 1.0 300.0 0.8 1.0 0.0 0.0 0.2 0.0'
    WRITE (u, '(A)') '--- RODS ---'
    WRITE (u, '(A)') 'ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)'
    WRITE (u, '(A)') '1 spar Free 0.0 0.0 -30.0 0.0 0.0 -20.0 1 -'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)'
    WRITE (u, '(A)') '1 Rod1A 0.0 0.0 -30.0 0 0 0 0'
    WRITE (u, '(A)') '2 Rod1B 0.0 0.0 -20.0 0 0 0 0'
    WRITE (u, '(A)') '3 Fixed '//x3//' 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '4 Fixed -25.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '5 Fixed 0.0 30.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '6 Fixed 0.0 -30.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '7 Fixed -40.0 0.0 -50.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 3 -'
    WRITE (u, '(A)') '2 1 4 -'
    WRITE (u, '(A)') '3 2 5 -'
    WRITE (u, '(A)') '4 2 6 -'
    WRITE (u, '(A)') '5 2 7 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 31.95 16'
    WRITE (u, '(A)') '2 poly 31.95 16'
    WRITE (u, '(A)') '3 poly 42.40 20'
    WRITE (u, '(A)') '4 poly 42.40 20'
    WRITE (u, '(A)') '5 cab 55.0 40'
    IF (clump) THEN
      WRITE (u, '(A)') '--- ATTACHMENTS ---'
      WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
      WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
      WRITE (u, '(A)') '5 25.0 1500.0 0.0 0.0 0.0'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '50.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    WRITE (u, '(A)') dtm//' dtM'
    WRITE (u, '(A)') tmax//' TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Point2px'
    WRITE (u, '(A)') 'Point2pz'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') 'FairTen2'
    WRITE (u, '(A)') 'FairTen3'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE pinned_rod_deck

  SUBROUTINE case_fallback_verdict()
    !! A straight 10 m line on 1 m elements whose tangent at node 6 is turned by 0.6 rad: the
    !! two elements beside node 6 carry h*kappa of about 2.3, beyond the kink limit 0.7, as the
    !! elements beside a lumped attachment load carry its slope jump. With the attachment at
    !! node 6 the verdict accepts the state; with it at node 3 it rejects the kink; a uniformly
    !! compressed straight line is rejected under tensile_safety True; and an unstable state
    !! (the caller's stability test) is rejected.
    INTEGER, PARAMETER :: NE = 10
    REAL(wp), PARAMETER :: THETA = 0.6_wp
    REAL(wp) :: l0(NE), ea(NE), ei(NE), w(NE), diam(NE), q(6*(NE + 1)), qc(6*(NE + 1))
    INTEGER :: i
    LOGICAL :: accepted
    CHARACTER(1024) :: msg
    l0 = 1.0_wp
    ea = 1.0e8_wp
    ei = 1.0e4_wp
    w = 100.0_wp
    diam = 0.1_wp
    q = 0.0_wp
    qc = 0.0_wp
    DO i = 1, NE + 1
      q(6*(i - 1) + 1:6*(i - 1) + 3) = [REAL(i - 1, wp), 0.0_wp, -50.0_wp]
      q(6*(i - 1) + 4:6*(i - 1) + 6) = [1.0_wp, 0.0_wp, 0.0_wp]
      qc(6*(i - 1) + 1:6*(i - 1) + 3) = [0.99_wp*REAL(i - 1, wp), 0.0_wp, -50.0_wp]
      qc(6*(i - 1) + 4:6*(i - 1) + 6) = [0.99_wp, 0.0_wp, 0.0_wp]
    END DO
    q(6*5 + 4:6*5 + 6) = [COS(THETA), 0.0_wp, SIN(THETA)]
    CALL CD_Attachment_Discrete_Verdict(l0, q, ea, ei, w, diam, [CD_ENDCONN_PINNED, CD_ENDCONN_PINNED], [6], &
                                        -1000.0_wp, .FALSE., .TRUE., accepted, msg)
    CALL require(accepted, 'fallback verdict: a slope jump beside the attachment node is accepted ('// &
                 TRIM(msg)//')')
    CALL CD_Attachment_Discrete_Verdict(l0, q, ea, ei, w, diam, [CD_ENDCONN_PINNED, CD_ENDCONN_PINNED], [3], &
                                        -1000.0_wp, .FALSE., .TRUE., accepted, msg)
    CALL require(.NOT. accepted .AND. INDEX(msg, 'discrete ATTACHMENTS') > 0 .AND. &
                 INDEX(msg, 'is unresolved/kinked') > 0 .AND. INDEX(msg, 'away from the attachment nodes') > 0, &
                 'fallback verdict: the bend away from the attachment fails the kink limit ('//TRIM(msg)//')')
    CALL CD_Attachment_Discrete_Verdict(l0, qc, ea, ei, w, diam, [CD_ENDCONN_PINNED, CD_ENDCONN_PINNED], [6], &
                                        -1000.0_wp, .TRUE., .TRUE., accepted, msg)
    CALL require(.NOT. accepted .AND. INDEX(msg, 'carries axial compression under tensile_safety True') > 0, &
                 'fallback verdict: a compressed state fails the tensile contract ('//TRIM(msg)//')')
    CALL CD_Attachment_Discrete_Verdict(l0, qc, ea, ei, w, diam, [CD_ENDCONN_PINNED, CD_ENDCONN_PINNED], [6], &
                                        -1000.0_wp, .FALSE., .TRUE., accepted, msg)
    CALL require(accepted, 'fallback verdict: compression alone passes without tensile_safety ('//TRIM(msg)//')')
    CALL CD_Attachment_Discrete_Verdict(l0, q, ea, ei, w, diam, [CD_ENDCONN_PINNED, CD_ENDCONN_PINNED], [6], &
                                        -1000.0_wp, .FALSE., .FALSE., accepted, msg)
    CALL require(.NOT. accepted .AND. INDEX(msg, 'is an unstable equilibrium') > 0, &
                 'fallback verdict: an unstable state is rejected ('//TRIM(msg)//')')
  END SUBROUTINE case_fallback_verdict

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      nfail = nfail + 1
      WRITE (*, '(A)') 'FAIL: '//TRIM(msg)
    END IF
  END SUBROUTINE require

  SUBROUTINE write_deck(path, buoy_segs, pitch, options, stock, extra_rows, equivalent, anchor_row)
    !! pitch <= 0: smeared buoyancy section; otherwise bare section + modules at pitch.
    !! equivalent: the smeared section is given by an EQUIVALENT BUOYANCY row.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: buoy_segs
    REAL(wp), INTENT(IN) :: pitch
    CHARACTER(*), INTENT(IN) :: options(:)
    LOGICAL, INTENT(IN), OPTIONAL :: stock
    CHARACTER(*), INTENT(IN), OPTIONAL :: extra_rows(:)
    LOGICAL, INTENT(IN), OPTIONAL :: equivalent
    CHARACTER(*), INTENT(IN), OPTIONAL :: anchor_row
    INTEGER :: u, i
    LOGICAL :: stock_order
    stock_order = .FALSE.
    IF (PRESENT(stock)) stock_order = stock
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'lazy-wave power cable with smeared or discrete buoyancy modules'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'buoy 0.29 59.53 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    IF (PRESENT(anchor_row)) THEN
      WRITE (u, '(A)') anchor_row
    ELSE
      WRITE (u, '(A)') '1 Fixed 0.0 0.0 -56.0'
    END IF
    WRITE (u, '(A)') '2 Coupled 90.0 0.0 -14.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    IF (stock_order) THEN
      WRITE (u, '(A)') '1 1 2 -'
    ELSE
      WRITE (u, '(A)') '1 2 1 -'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    IF (stock_order) WRITE (u, '(A)') '1 bare 55.0 18'
    IF (.NOT. stock_order) WRITE (u, '(A)') '1 bare 40.0 13'
    IF (pitch > 0.0_wp) THEN
      WRITE (u, '(A,I0)') '1 bare 50.0 ', buoy_segs
    ELSE
      WRITE (u, '(A,I0)') '1 buoy 50.0 ', buoy_segs
    END IF
    IF (stock_order) WRITE (u, '(A)') '1 bare 40.0 13'
    IF (.NOT. stock_order) WRITE (u, '(A)') '1 bare 55.0 18'
    IF (PRESENT(equivalent)) THEN
      IF (equivalent) THEN
        ! the buoyancy section by its submerged weight: (59.53 - rhoW pi 0.29^2/4) g
        WRITE (u, '(A)') '--- EQUIVALENT BUOYANCY ---'
        WRITE (u, '(A)') 'LineType Diam SubmergedWeightNpm'
        WRITE (u, '(A)') '(-) (m) (N/m)'
        WRITE (u, '(A,ES24.16)') 'buoy 0.29 ', (59.53_wp - 1025.0_wp*0.25_wp*PI*0.29_wp**2)*9.80665_wp
      END IF
    END IF
    IF (pitch > 0.0_wp .OR. PRESENT(extra_rows)) THEN
      WRITE (u, '(A)') '--- ATTACHMENTS ---'
      WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
      WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
      IF (pitch > 0.0_wp) THEN
        IF (stock_order) THEN
          ! arcs from the stock End A (the anchor): the same physical positions
          WRITE (u, '(A,F0.4,A,F0.4,A,F0.4,5(1X,ES24.16))') '1 ', 55.0_wp + 0.5_wp*pitch, ':', pitch, ':', &
            105.0_wp - 0.5_wp*pitch, DM*pitch, DV*pitch, DCDA*pitch, 1.0_wp, DCDAX*pitch
        ELSE
          WRITE (u, '(A,F0.4,A,F0.4,A,F0.4,5(1X,ES24.16))') '1 ', 40.0_wp + 0.5_wp*pitch, ':', pitch, ':', &
            90.0_wp - 0.5_wp*pitch, DM*pitch, DV*pitch, DCDA*pitch, 1.0_wp, DCDAX*pitch
        END IF
      END IF
      IF (PRESENT(extra_rows)) THEN
        DO i = 1, SIZE(extra_rows)
          WRITE (u, '(A)') TRIM(extra_rows(i))
        END DO
      END IF
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    DO i = 1, SIZE(options)
      IF (LEN_TRIM(options(i)) > 0) WRITE (u, '(A)') TRIM(options(i))
    END DO
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') 'AnchTen1'
    WRITE (u, '(A)') 'END'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE run(deck, root, ok, msg)
    CHARACTER(*), INTENT(IN) :: deck, root
    LOGICAL, INTENT(OUT) :: ok
    CHARACTER(*), INTENT(OUT) :: msg
    LOGICAL :: conv
    INTEGER :: es
    CALL CD_Run_Deck_Driver(deck, root, conv, es, msg)
    ok = es == CD_DECKDRV_OK .AND. conv
  END SUBROUTINE run

  SUBROUTINE read_static(path, prof, n)
    !! .static.out rows: LineID Node ArcLength X Y Z Tension Curvature BendMoment Decl Incl Azi
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: prof(:, :)
    INTEGER, INTENT(OUT) :: n
    INTEGER :: u, ios
    CHARACTER(1024) :: line
    REAL(wp) :: row(12)
    ALLOCATE (prof(12, 2000))
    n = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      READ (line, *, IOSTAT=ios) row
      IF (ios /= 0) CYCLE
      n = n + 1
      prof(:, n) = row
    END DO
    CLOSE (u)
  END SUBROUTINE read_static

  SUBROUTINE read_out(path, data, nrow, ncol)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: data(:, :)
    INTEGER, INTENT(OUT) :: nrow
    INTEGER, INTENT(IN) :: ncol
    INTEGER :: u, ios
    CHARACTER(1024) :: line
    REAL(wp) :: row(ncol)
    ALLOCATE (data(ncol, 100000))
    nrow = 0
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. line(1:4) == 'Time') CYCLE
      READ (line, *, IOSTAT=ios) row
      IF (ios /= 0) CYCLE
      nrow = nrow + 1
      data(:, nrow) = row
    END DO
    CLOSE (u)
  END SUBROUTINE read_out

  SUBROUTINE case_static_convergence()
    CHARACTER(24) :: opts(2)
    CHARACTER(512) :: msg
    CHARACTER(40) :: name
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: ps(:, :), pd(:, :)
    REAL(wp) :: err(3), terr(3), pitch(3)
    INTEGER :: ns, nd, k
    opts(1) = '0.05 dtM'
    opts(2) = '0.0 TMax'
    CALL write_deck('att_smeared.dat', 80, 0.0_wp, opts)
    CALL run('att_smeared.dat', 'att_smeared', ok, msg)
    CALL require(ok, 'static: smeared deck solves: '//TRIM(msg))
    CALL read_static('att_smeared.static.out', ps, ns)
    pitch = [5.0_wp, 2.5_wp, 1.25_wp]
    err = HUGE(1.0_wp); terr = HUGE(1.0_wp)
    DO k = 1, 3
      WRITE (name, '(A,I0)') 'att_discrete_', k
      CALL write_deck(TRIM(name)//'.dat', 80, pitch(k), opts)
      CALL run(TRIM(name)//'.dat', TRIM(name), ok, msg)
      CALL require(ok, 'static: discrete deck solves: '//TRIM(msg))
      IF (.NOT. ok) CYCLE
      CALL read_static(TRIM(name)//'.static.out', pd, nd)
      IF (nd /= ns .OR. ns < 1) THEN
        CALL require(.FALSE., 'static: profiles have the same nodes')
        CYCLE
      END IF
      err(k) = MAXVAL(SQRT((pd(4, :nd) - ps(4, :ns))**2 + (pd(6, :nd) - ps(6, :ns))**2))
      terr(k) = ABS(pd(7, 1) - ps(7, 1))/ps(7, 1)
      WRITE (*, '(A,F6.3,A,ES11.4,A,ES11.4)') '  static: pitch ', pitch(k), ' m: max node offset [m] = ', &
        err(k), ', fairlead tension rel. diff = ', terr(k)
    END DO
    CALL require(err(3) < 0.02_wp, 'static: p = 1.25 m discrete shape within 2 cm of the smeared shape')
    CALL require(terr(3) < 1.0e-3_wp, 'static: p = 1.25 m fairlead tension within 0.1 % of smeared')
    CALL require(err(2) < 0.5_wp*err(1) .AND. err(3) < 0.5_wp*err(2), &
                 'static: the discrete equilibrium converges to the smeared one as the pitch shrinks')
  END SUBROUTINE case_static_convergence

  SUBROUTINE case_curvature_peaks()
    !! p = 5 m modules at s = 42.5 + 5 i from End A. Element 0.625 m vs 0.3125 m in the
    !! buoyancy section; module i = 4 (s = 62.5 m) sits mid-arch.
    CHARACTER(24) :: opts(2)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: p1(:, :), p2(:, :)
    INTEGER :: n1, n2, jm1, jm2, jh1, jh2
    REAL(wp) :: k_mod1, k_mod2, k_mid1, k_mid2
    opts(1) = '0.05 dtM'
    opts(2) = '0.0 TMax'
    CALL write_deck('att_peak_a.dat', 80, 5.0_wp, opts)
    CALL run('att_peak_a.dat', 'att_peak_a', ok, msg)
    CALL require(ok, 'peaks: 0.625 m mesh solves: '//TRIM(msg))
    CALL write_deck('att_peak_b.dat', 160, 5.0_wp, opts)
    CALL run('att_peak_b.dat', 'att_peak_b', ok, msg)
    CALL require(ok, 'peaks: 0.3125 m mesh solves: '//TRIM(msg))
    CALL read_static('att_peak_a.static.out', p1, n1)
    CALL read_static('att_peak_b.static.out', p2, n2)
    IF (n1 /= 112 .OR. n2 /= 192) THEN
      CALL require(.FALSE., 'peaks: profiles written'); RETURN
    END IF
    ! node index from End A: 14 nodes over the first 40 m, then one per element
    jm1 = 14 + NINT((62.5_wp - 40.0_wp)/0.625_wp); jh1 = 14 + NINT((65.0_wp - 40.0_wp)/0.625_wp)
    jm2 = 14 + NINT((62.5_wp - 40.0_wp)/0.3125_wp); jh2 = 14 + NINT((65.0_wp - 40.0_wp)/0.3125_wp)
    k_mod1 = p1(8, jm1); k_mod2 = p2(8, jm2)
    k_mid1 = p1(8, jh1); k_mid2 = p2(8, jh2)
    WRITE (*, '(A,4ES12.4)') '  peaks: curvature at module / between modules (0.625 m, 0.3125 m) = ', &
      k_mod1, k_mid1, k_mod2, k_mid2
    CALL require(ABS(k_mod1 - k_mid1) > 0.05_wp*MAX(ABS(k_mod1), ABS(k_mid1)), &
                 'peaks: the curvature varies between the modules')
    CALL require(ABS(k_mod2/k_mod1 - 1.0_wp) < 0.02_wp .AND. ABS(k_mid2/k_mid1 - 1.0_wp) < 0.02_wp, &
                 'peaks: module and inter-module curvature converged under mesh halving (2 %)')
  END SUBROUTINE case_curvature_peaks

  SUBROUTINE case_dynamics()
    !! Fairlead heave 1.5 m, 10 s, ramped: discrete p = 2.5 m vs smeared.
    CHARACTER(24) :: opts(3)
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: ds(:, :), dd(:, :)
    INTEGER :: ns, nd, u, n
    REAL(wp) :: t, r, rd, rdd, z, w, amp, dev, span
    w = 2.0_wp*PI/10.0_wp
    amp = 1.5_wp
    OPEN (NEWUNIT=u, FILE='att_heave.txt', STATUS='REPLACE', ACTION='WRITE')
    DO n = 0, 600
      t = 0.05_wp*REAL(n, wp)
      ! half-cosine ramp over 10 s
      IF (t < 10.0_wp) THEN
        r = 0.5_wp*(1.0_wp - COS(PI*t/10.0_wp)); rd = 0.5_wp*(PI/10.0_wp)*SIN(PI*t/10.0_wp)
        rdd = 0.5_wp*(PI/10.0_wp)**2*COS(PI*t/10.0_wp)
      ELSE
        r = 1.0_wp; rd = 0.0_wp; rdd = 0.0_wp
      END IF
      z = amp*SIN(w*t)
      WRITE (u, '(ES24.16,I3,9(1X,ES24.16))') t, 2, 90.0_wp, 0.0_wp, -14.0_wp + r*z, 0.0_wp, 0.0_wp, &
        rd*z + r*amp*w*COS(w*t), 0.0_wp, 0.0_wp, rdd*z + 2.0_wp*rd*amp*w*COS(w*t) - r*w*w*z
    END DO
    CLOSE (u)
    opts(1) = '0.05 dtM'
    opts(2) = '30.0 TMax'
    opts(3) = 'att_heave.txt motionFile'
    CALL write_deck('att_dyn_s.dat', 80, 0.0_wp, opts)
    CALL run('att_dyn_s.dat', 'att_dyn_s', ok, msg)
    CALL require(ok, 'dynamics: smeared run completes: '//TRIM(msg))
    CALL write_deck('att_dyn_d.dat', 80, 2.5_wp, opts)
    CALL run('att_dyn_d.dat', 'att_dyn_d', ok, msg)
    CALL require(ok, 'dynamics: discrete run completes stably: '//TRIM(msg))
    CALL read_out('att_dyn_s.out', ds, ns, 3)
    CALL read_out('att_dyn_d.out', dd, nd, 3)
    IF (ns /= 601 .OR. nd /= 601) THEN
      CALL require(.FALSE., 'dynamics: full records written'); RETURN
    END IF
    span = MAXVAL(ds(2, :ns)) - MINVAL(ds(2, :ns))
    dev = nan_max_abs(dd(2, :nd) - ds(2, :ns))
    WRITE (*, '(A,2ES12.4)') '  dynamics: fairlead tension range (smeared) and max discrete deviation [N] = ', &
      span, dev
    CALL require(span > 0.0_wp .AND. dev < 0.05_wp*span + 0.01_wp*ABS(ds(2, 1)), &
                 'dynamics: the discrete fairlead tension follows the smeared one')
  END SUBROUTINE case_dynamics

  SUBROUTINE case_current(label, current_row)
    !! Static equilibrium in a deck current: the discrete modules (normal and axial drag areas
    !! matching the smeared section's Cd_n d and Cd_t pi d per metre) converge to the smeared
    !! EQUIVALENT BUOYANCY section as the pitch shrinks; a dynamic run held at rest in the
    !! current does not drift.
    CHARACTER(*), INTENT(IN) :: label, current_row
    CHARACTER(64) :: opts(3)
    CHARACTER(512) :: msg
    CHARACTER(40) :: name
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: ps(:, :), pd(:, :), d0(:, :)
    REAL(wp) :: err(3), pitch(3)
    INTEGER :: ns, nd, k, n0
    opts(1) = '0.05 dtM'
    opts(2) = '0.0 TMax'
    opts(3) = current_row
    CALL write_deck('att_cur_s_'//label//'.dat', 80, 0.0_wp, opts, equivalent=.TRUE.)
    CALL run('att_cur_s_'//label//'.dat', 'att_cur_s_'//label, ok, msg)
    CALL require(ok, 'current '//label//': smeared EQUIVALENT BUOYANCY deck solves: '//TRIM(msg))
    CALL read_static('att_cur_s_'//label//'.static.out', ps, ns)
    IF (ns < 1) RETURN
    pitch = [5.0_wp, 2.5_wp, 1.25_wp]
    err = HUGE(1.0_wp)
    DO k = 1, 3
      WRITE (name, '(A,A,A,I0)') 'att_cur_d_', label, '_', k
      CALL write_deck(TRIM(name)//'.dat', 80, pitch(k), opts)
      CALL run(TRIM(name)//'.dat', TRIM(name), ok, msg)
      CALL require(ok, 'current '//label//': discrete deck solves: '//TRIM(msg))
      IF (.NOT. ok) CYCLE
      CALL read_static(TRIM(name)//'.static.out', pd, nd)
      IF (nd /= ns) CYCLE
      err(k) = MAXVAL(SQRT((pd(4, :nd) - ps(4, :ns))**2 + (pd(5, :nd) - ps(5, :ns))**2 + &
                           (pd(6, :nd) - ps(6, :ns))**2))
      WRITE (*, '(A,A,A,F6.3,A,ES11.4,A,ES11.4)') '  current ', label, ': pitch ', pitch(k), &
        ' m: max node offset from smeared [m] = ', err(k), '; fairlead tension rel. diff = ', &
        ABS(pd(7, 1) - ps(7, 1))/ps(7, 1)
    END DO
    CALL require(err(2) < 0.5_wp*err(1) .AND. err(3) < 0.5_wp*err(2) .AND. err(3) < 0.02_wp, &
                 'current '//label//': discrete equilibrium converges to EQUIVALENT BUOYANCY in current')
    ! at-rest drift: the p = 2.5 m cable held for 10 s in the current
    opts(2) = '10.0 TMax'
    CALL write_deck('att_cur_dyn_'//label//'.dat', 80, 2.5_wp, opts)
    CALL run('att_cur_dyn_'//label//'.dat', 'att_cur_dyn_'//label, ok, msg)
    CALL require(ok, 'current '//label//': dynamic run at rest completes: '//TRIM(msg))
    CALL read_out('att_cur_dyn_'//label//'.out', d0, n0, 3)
    IF (n0 == 201) THEN
      WRITE (*, '(A,A,A,ES11.4)') '  current ', label, ': at-rest fairlead-tension drift [N] = ', &
        nan_max_abs(d0(2, :n0) - d0(2, 1))
      CALL require(nan_max_abs(d0(2, :n0) - d0(2, 1)) < 1.0e-3_wp*d0(2, 1), &
                   'current '//label//': no drift at rest in the current (fairlead tension within 0.1 %)')
    ELSE
      CALL require(.FALSE., 'current '//label//': at-rest record written')
    END IF
  END SUBROUTINE case_current

  SUBROUTINE held_field(xyz, t, fv, fa, wl)
    !! A host-style held fluid field at the sampling nodes: a 0.3 m/s current along +x and a
    !! deep-water-decaying 10 s wave velocity along +x, with its exact time derivative.
    REAL(wp), INTENT(IN) :: xyz(:, :), t
    REAL(wp), INTENT(OUT) :: fv(:, :), fa(:, :), wl(:)
    REAL(wp), PARAMETER :: AMP = 0.8_wp, OM = 2.0_wp*PI/10.0_wp, KW = OM*OM/9.80665_wp
    REAL(wp) :: ph, dec
    INTEGER :: i
    DO i = 1, SIZE(xyz, 2)
      ph = KW*xyz(1, i) - OM*t
      dec = AMP*OM*EXP(KW*MIN(xyz(3, i), 0.0_wp))
      fv(:, i) = [0.3_wp + dec*COS(ph), 0.0_wp, dec*SIN(ph)]
      fa(:, i) = [dec*OM*SIN(ph), 0.0_wp, -dec*OM*COS(ph)]
      wl(i) = AMP*COS(ph)
    END DO
  END SUBROUTINE held_field

  SUBROUTINE coupled_step(agg, s, r0, pos, vel, acc, ok)
    !! One coupled advance: the held field at the current nodes, then a 0.8 m fairlead heave.
    TYPE(CD_AGG_ModuleType), INTENT(INOUT) :: agg
    INTEGER, INTENT(IN) :: s
    REAL(wp), INTENT(IN) :: r0(:, :)
    REAL(wp), INTENT(OUT) :: pos(:, :), vel(:, :), acc(:, :)
    LOGICAL, INTENT(OUT) :: ok
    REAL(wp), PARAMETER :: DT = 0.05_wp, W = 2.0_wp*PI/8.0_wp
    REAL(wp), ALLOCATABLE :: xyz(:, :), fv(:, :), fa(:, :), wl(:)
    REAL(wp) :: t
    INTEGER :: es, nfl, ni
    LOGICAL :: cv, st
    CHARACTER(512) :: em
    t = REAL(s, wp)*DT
    nfl = CD_AGG_NFluidNodes(agg, es, em)
    ALLOCATE (xyz(3, nfl), fv(3, nfl), fa(3, nfl), wl(nfl))
    CALL CD_AGG_GetFluidNodePositions(agg, xyz, es, em)
    CALL held_field(xyz, t, fv, fa, wl)
    CALL CD_AGG_SetFluidFields(agg, fv, fa, wl, es, em)
    ok = es == CD_AGG_OK
    pos = r0
    vel = 0.0_wp
    acc = 0.0_wp
    pos(3, :) = r0(3, :) + 0.4_wp*(1.0_wp - COS(W*t))
    vel(3, :) = 0.4_wp*W*SIN(W*t)
    acc(3, :) = 0.4_wp*W*W*COS(W*t)
    CALL CD_AGG_Step_Moving(agg, DT, pos, vel, acc, cv, st, ni, es, em, t_committed=t)
    ok = ok .AND. es == CD_AGG_OK .AND. cv
    IF (.NOT. ok) WRITE (*, '(A)') '  coupled step: '//TRIM(em)
    CALL CD_AGG_CalcOutput(agg, es, em)
  END SUBROUTINE coupled_step

  SUBROUTINE case_coupled()
    !! Attachments on the coupled OpenFAST route (the aggregate behind CableDyn_OF): (1) under a
    !! held SeaState-style field and fairlead heave the discrete-module cable's fairlead load
    !! tracks the smeared cable's -- the attachments take the held kinematics at their nodes;
    !! (2) checkpoint restart: a fresh instance overlaid with the coupled kinematics and the
    !! cable mirror continues BIT-IDENTICALLY with the original.
    TYPE(CD_AGG_ModuleType), SAVE :: agg_s, agg_d, agg_b
    CHARACTER(24) :: opts(1)
    CHARACTER(512) :: em
    INTEGER, PARAMETER :: NPRE = 30, NPOST = 30
    REAL(wp) :: r0(3, 1), pos(3, 1), vel(3, 1), acc(3, 1), ls(3, 1), ld(3, 1), lb(3, 1), pa(3, 1), pb(3, 1)
    REAL(wp) :: dev, span, lmin, lmax
    REAL(wp), ALLOCATABLE :: cbuf(:)
    INTEGER :: es, s, csz
    LOGICAL :: ok, ok2, same
    opts(1) = ''
    CALL write_deck('att_cpl_s.dat', 80, 0.0_wp, opts)
    CALL write_deck('att_cpl_d.dat', 80, 2.5_wp, opts)
    CALL CD_AGG_Init_From_Deck(agg_s, 'att_cpl_s.dat', 0.05_wp, es, em, external_fluid=.TRUE.)
    CALL require(es == CD_AGG_OK, 'coupled: smeared deck initializes: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_Init_From_Deck(agg_d, 'att_cpl_d.dat', 0.05_wp, es, em, external_fluid=.TRUE.)
    CALL require(es == CD_AGG_OK, 'coupled: discrete deck initializes: '//TRIM(em))
    IF (es /= CD_AGG_OK) RETURN
    CALL CD_AGG_GetMovingPointMesh(agg_d, r0, vel, acc, ld, es, em)
    dev = 0.0_wp; lmin = HUGE(1.0_wp); lmax = -HUGE(1.0_wp)
    DO s = 1, NPRE + NPOST
      CALL coupled_step(agg_s, s, r0, pos, vel, acc, ok)
      CALL coupled_step(agg_d, s, r0, pos, vel, acc, ok2)
      CALL require(ok .AND. ok2, 'coupled: both cables step')
      IF (.NOT. (ok .AND. ok2)) RETURN
      CALL CD_AGG_GetMovingPointMesh(agg_s, pa, vel, acc, ls, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg_d, pa, vel, acc, ld, es, em)
      dev = MAX(dev, NORM2(ld(:, 1) - ls(:, 1)))
      lmin = MIN(lmin, NORM2(ls(:, 1))); lmax = MAX(lmax, NORM2(ls(:, 1)))
      IF (s == NPRE) THEN
        ! the checkpoint: a fresh instance with A's coupled kinematics and cable mirror
        CALL CD_AGG_Init_From_Deck(agg_b, 'att_cpl_d.dat', 0.05_wp, es, em, external_fluid=.TRUE.)
        CALL require(es == CD_AGG_OK, 'coupled: restart instance initializes: '//TRIM(em))
        CALL CD_AGG_GetMovingPointMesh(agg_d, pa, vel, acc, ld, es, em)
        CALL CD_AGG_UpdateStates_Moving(agg_b, pa, vel, acc, es, em)
        csz = CD_HFMF_MirrorSize(agg_d%cables(1))
        ALLOCATE (cbuf(csz))
        CALL CD_HFMF_PackMirror(agg_d%cables(1), cbuf, es, em)
        CALL CD_HFMF_UnpackMirror(agg_b%cables(1), cbuf, agg_d%cables(1)%line%t, es, em)
        CALL require(es == CD_HFMF_OK, 'coupled: cable mirror reloads: '//TRIM(em))
        ! the host re-samples its field on the restored state (the CableDyn_OF rebuild)
        BLOCK
          REAL(wp), ALLOCATABLE :: xyz(:, :), fv(:, :), fa(:, :), wl(:)
          INTEGER :: nfl
          nfl = CD_AGG_NFluidNodes(agg_b, es, em)
          ALLOCATE (xyz(3, nfl), fv(3, nfl), fa(3, nfl), wl(nfl))
          CALL CD_AGG_GetFluidNodePositions(agg_b, xyz, es, em)
          CALL held_field(xyz, REAL(NPRE, wp)*0.05_wp, fv, fa, wl)
          CALL CD_AGG_SetFluidFields(agg_b, fv, fa, wl, es, em)
          CALL require(es == CD_AGG_OK, 'coupled: restored instance takes the re-sampled field: '//TRIM(em))
        END BLOCK
        CALL CD_AGG_CalcOutput(agg_b, es, em)
      END IF
    END DO
    span = lmax - lmin
    WRITE (*, '(A,2ES12.4)') '  coupled: smeared fairlead-load range and max discrete deviation [N] = ', span, dev
    CALL require(span > 0.0_wp .AND. dev < 0.1_wp*span, &
                 'coupled: the discrete cable tracks the smeared one under the held field')
    ! restart continuation: B (restored at NPRE) against A replayed from the same point
    CALL CD_AGG_End(agg_d, es, em)
    CALL CD_AGG_Init_From_Deck(agg_d, 'att_cpl_d.dat', 0.05_wp, es, em, external_fluid=.TRUE.)
    DO s = 1, NPRE
      CALL coupled_step(agg_d, s, r0, pos, vel, acc, ok)
    END DO
    same = .TRUE.
    DO s = NPRE + 1, NPRE + NPOST
      CALL coupled_step(agg_d, s, r0, pos, vel, acc, ok)
      CALL coupled_step(agg_b, s, r0, pos, vel, acc, ok2)
      CALL require(ok .AND. ok2, 'coupled: original and restarted instances step')
      IF (.NOT. (ok .AND. ok2)) EXIT
      CALL CD_AGG_GetMovingPointMesh(agg_d, pa, vel, acc, ld, es, em)
      CALL CD_AGG_GetMovingPointMesh(agg_b, pb, vel, acc, lb, es, em)
      same = same .AND. nan_max_abs(ld - lb) <= 0.0_wp .AND. &
             nan_max_abs(agg_d%cables(1)%line%q - agg_b%cables(1)%line%q) <= 0.0_wp .AND. &
             nan_max_abs(agg_d%cables(1)%line%v - agg_b%cables(1)%line%v) <= 0.0_wp
    END DO
    CALL require(same, 'coupled: the restarted instance continues bit-identically')
    CALL CD_AGG_End(agg_s, es, em)
    CALL CD_AGG_End(agg_d, es, em)
    CALL CD_AGG_End(agg_b, es, em)
  END SUBROUTINE case_coupled

  SUBROUTINE case_current_friction()
    !! Attachments in a current on a frictional seabed with ANISOTROPIC friction (axial 0.3,
    !! lateral 0.6), on the Gulf of Mexico 80 m installed lazy-wave geometry (touchdown on the
    !! seabed): the static solve (still-water friction reference, then the current) and a run
    !! held at rest in the current start in equilibrium and do not drift.
    CHARACTER(512) :: msg
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: d0(:, :)
    INTEGER :: n0, u
    REAL(wp), PARAMETER :: P = 2.5_wp
    OPEN (NEWUNIT=u, FILE='att_cur_fric.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'installed lazy-wave cable with discrete modules in a current on a frictional seabed'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Coupled 5.0 0.0 -14.0'
    WRITE (u, '(A)') '2 Fixed 125.0 0.0 -80.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 68.114 112'
    WRITE (u, '(A)') '1 bare 50.0 80'
    WRITE (u, '(A)') '1 bare 52.101 80'
    WRITE (u, '(A)') '--- ATTACHMENTS ---'
    WRITE (u, '(A)') 'LineID ArcLength Mass Volume CdA Ca CdAx'
    WRITE (u, '(A)') '(-) (m) (kg) (m^3) (m^2) (-) (m^2)'
    WRITE (u, '(A,F0.4,A,F0.4,A,F0.4,5(1X,ES24.16))') '1 ', 68.114_wp + 0.5_wp*P, ':', P, ':', &
      118.114_wp - 0.5_wp*P, DM*P, DV*P, DCDA*P, 1.0_wp, DCDAX*P
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '80.0 WtrDpth'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '10.0 TMax'
    WRITE (u, '(A)') 'uniform 0.3 0.15 0.0 current'
    WRITE (u, '(A)') '0.3 frictionMuAxial'
    WRITE (u, '(A)') '0.6 frictionMuLateral'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') 'AnchTen1'
    WRITE (u, '(A)') 'END'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
    CALL run('att_cur_fric.dat', 'att_cur_fric', ok, msg)
    CALL require(ok, 'current+friction: anisotropic-friction deck with attachments runs: '//TRIM(msg))
    CALL read_out('att_cur_fric.out', d0, n0, 3)
    IF (n0 == 201) THEN
      WRITE (*, '(A,ES11.4,A,ES11.4)') '  current+friction: at-rest fairlead-tension drift [N] = ', &
        nan_max_abs(d0(2, :n0) - d0(2, 1)), ' of ', d0(2, 1)
      CALL require(nan_max_abs(d0(2, :n0) - d0(2, 1)) < 1.0e-3_wp*d0(2, 1), &
                   'current+friction: no drift at rest (fairlead tension within 0.1 %)')
    ELSE
      CALL require(.FALSE., 'current+friction: at-rest record written')
    END IF
  END SUBROUTINE case_current_friction

  SUBROUTINE case_grammar()
    CHARACTER(24) :: opts(2)
    CHARACTER(512) :: msg
    CHARACTER(80) :: rows(1)
    LOGICAL :: ok
    REAL(wp), ALLOCATABLE :: pa(:, :), pb(:, :)
    INTEGER :: na, nb
    opts(1) = '0.05 dtM'
    opts(2) = '0.0 TMax'
    ! stock endpoint order: the arcs are measured from the stock End A (the anchor)
    CALL write_deck('att_stock.dat', 80, 5.0_wp, opts, stock=.TRUE.)
    CALL run('att_stock.dat', 'att_stock', ok, msg)
    CALL require(ok, 'grammar: stock-order deck solves: '//TRIM(msg))
    CALL read_static('att_peak_a.static.out', pa, na)
    CALL read_static('att_stock.static.out', pb, nb)
    IF (ok .AND. na == nb .AND. na > 0) THEN
      CALL require(nan_max_abs(pa(4:6, :na) - pb(4:6, :nb)) < 1.0e-6_wp, &
                   'grammar: stock order places the modules at the same physical arcs')
    END IF
    rows(1) = '1 60.0 100 0.1 0.1 1.0 0.2 7'
    CALL write_deck('att_bad0.dat', 80, 0.0_wp, opts, extra_rows=rows)
    CALL run('att_bad0.dat', 'att_bad0', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'LineID ArcLength') > 0, 'grammar: an eight-column row: '//TRIM(msg))
    rows(1) = '1 60.0 0 0 0 1.0'
    CALL write_deck('att_bad1.dat', 80, 0.0_wp, opts, extra_rows=rows)
    CALL run('att_bad1.dat', 'att_bad1', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'positive Mass') > 0, 'grammar: an empty attachment: '//TRIM(msg))
    rows(1) = '1 200.0 100 0.1 0.1 1.0'
    CALL write_deck('att_bad2.dat', 80, 0.0_wp, opts, extra_rows=rows)
    CALL run('att_bad2.dat', 'att_bad2', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'beyond the end') > 0, 'grammar: arc beyond the line: '//TRIM(msg))
    rows(1) = '1 150.0 100 0.1 0.1 1.0'
    CALL write_deck('att_bad2s.dat', 80, 0.0_wp, opts, stock=.TRUE., extra_rows=rows)
    CALL run('att_bad2s.dat', 'att_bad2s', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'beyond the end') > 0, 'grammar: stock-order arc beyond the line: '// &
                 TRIM(msg))
    rows(1) = '1 60:0:70 100 0.1 0.1 1.0'
    CALL write_deck('att_bad3.dat', 80, 0.0_wp, opts, extra_rows=rows)
    CALL run('att_bad3.dat', 'att_bad3', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'pitch > 0') > 0, 'grammar: a zero pitch: '//TRIM(msg))
    rows(1) = '2 60.0 100 0.1 0.1 1.0'
    CALL write_deck('att_bad4.dat', 80, 0.0_wp, opts, extra_rows=rows)
    CALL run('att_bad4.dat', 'att_bad4', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'undefined LINE') > 0, 'grammar: an unknown line: '//TRIM(msg))
    rows(1) = '1 60.0 100 0.1 0.1'
    CALL write_deck('att_bad5.dat', 80, 0.0_wp, opts, extra_rows=rows)
    CALL run('att_bad5.dat', 'att_bad5', ok, msg)
    CALL require(.NOT. ok .AND. INDEX(msg, 'LineID ArcLength') > 0, 'grammar: a five-column row: '//TRIM(msg))
  END SUBROUTINE case_grammar

END PROGRAM test_line_attachments
