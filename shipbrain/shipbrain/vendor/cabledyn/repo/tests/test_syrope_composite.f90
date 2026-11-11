! File: tests/test_syrope_composite.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_syrope_composite
  !! Composite Syrope lines: a chain-polyester-chain mooring whose polyester section follows the
  !! Syrope working-curve model, in 200 m of water (the line of
  !! examples/composite_chain_poly_chain.dat with its anchor 30 m further out, so the polyester
  !! carries about 1 MN, where the working curve of these constants is admissible for a virgin
  !! rope).
  !!   1. The line builds; the Syrope flags sit on the 40 polyester elements only, the chains keep
  !!      their BA damping and the polyester takes none (its working curve carries the rope's).
  !!   2. The static polyester sits on its rest curve: every element's geometric strain gives its
  !!      tension on the OWC (each element takes its own secant EA), and so does the section's mean.
  !!   3. The same line with a linear-EA polyester of the mean secant EA has the static tensions to
  !!      the spread of the elements' own secants: the chains are built as any EI = 0 line.
  !!   4. The dynamics start in the static equilibrium: a still run keeps the fairlead tension
  !!      (one secant per section left the elements away from the mean off the curve, and their
  !!      slow strains moved the fairlead tension by 1.4e-5 within 2 s).
  !!   5. A SYROPE IC history (Tmax0 above the static tension) puts the section on the Tmax0
  !!      working curve instead.
  !!   6. A pretension above the top of the OWC table fails closed by name.
  !!   7. A taut line of two Syrope sections whose first solve, at the placeholder alpha, overshoots
  !!      the top of the table: the update continues from the table's top secant and every
  !!      element lands on its OWC.
  !!   8. A lightly loaded SYROPE IC rope near its working curve's zero-tension strain, where the
  !!      plain secant update contracts slowly: the accelerated update lands every element on the
  !!      Tmax0 working curve.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_Models, CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_Model, ONLY: CD_ModelType, CD_End_Model, CD_Get_Model_Tension
  USE CableDyn_Syrope, ONLY: CD_SyropeType, CD_Syrope_Init, CD_Syrope_End, CD_Syrope_Static_Tension, &
                             CD_SYROPE_WC_EXP, CD_SYROPE_OK
  IMPLICIT NONE

  INTEGER, PARAMETER :: NOWC = 30, NE_A = 25, NE_P = 40, NE_F = 12
  ! the shipped data/syrope/syrope_owc.dat table
  REAL(wp), PARAMETER :: OWC_EPS(NOWC) = [ &
                         0.00000e+00_wp, 2.06897e-03_wp, 4.13793e-03_wp, 6.20690e-03_wp, 8.27586e-03_wp, &
                         1.03448e-02_wp, 1.24138e-02_wp, 1.44828e-02_wp, 1.65517e-02_wp, 1.86207e-02_wp, &
                         2.06897e-02_wp, 2.27586e-02_wp, 2.48276e-02_wp, 2.68966e-02_wp, 2.89655e-02_wp, &
                         3.10345e-02_wp, 3.31034e-02_wp, 3.51724e-02_wp, 3.72414e-02_wp, 3.93103e-02_wp, &
                         4.13793e-02_wp, 4.34483e-02_wp, 4.55172e-02_wp, 4.75862e-02_wp, 4.96552e-02_wp, &
                         5.17241e-02_wp, 5.37931e-02_wp, 5.58621e-02_wp, 5.79310e-02_wp, 6.00000e-02_wp]
  REAL(wp), PARAMETER :: OWC_TEN(NOWC) = [ &
                         0.00000e+00_wp, 1.71768e+05_wp, 3.30952e+05_wp, 4.78788e+05_wp, 6.16510e+05_wp, &
                         7.45355e+05_wp, 8.66556e+05_wp, 9.81351e+05_wp, 1.09097e+06_wp, 1.19666e+06_wp, &
                         1.29964e+06_wp, 1.40116e+06_wp, 1.50245e+06_wp, 1.60474e+06_wp, 1.70927e+06_wp, &
                         1.81728e+06_wp, 1.93000e+06_wp, 2.04866e+06_wp, 2.17450e+06_wp, 2.30876e+06_wp, &
                         2.45267e+06_wp, 2.60747e+06_wp, 2.77439e+06_wp, 2.95467e+06_wp, 3.14954e+06_wp, &
                         3.36024e+06_wp, 3.58800e+06_wp, 3.83406e+06_wp, 4.09965e+06_wp, 4.38601e+06_wp]
  INTEGER :: nfail = 0, es, e
  CHARACTER(1024) :: em
  TYPE(CD_ModelType), ALLOCATABLE :: models(:), lin(:)
  REAL(wp) :: t_syr(NE_A + NE_P + NE_F), t_lin(NE_A + NE_P + NE_F), eps_bar, t_bar, secant, eps_e, worst
  CHARACTER(32) :: ea_text

  CALL write_owc('csyr_owc.dat', NOWC)
  CALL write_settings('csyr_settings.dat', 'csyr_owc.dat')

  ! 1. the composite line builds, with its Syrope elements and damping where they belong
  CALL write_deck('csyr.dat', '"SYROPE:csyr_settings.dat|1.53e8|23.12"', '5.0e10|1.0e5')
  CALL CD_Init_Deck_Models('csyr.dat', models, es, em)
  CALL require(es == CD_DECKDRV_OK, 'chain-Syrope-chain line builds: '//TRIM(em))
  IF (es /= CD_DECKDRV_OK) CALL finish()
  ASSOCIATE (md => models(1))
    ! internal element order anchor -> fairlead: the anchor chain, the polyester, the fairlead chain
    CALL require(md%n_elem == NE_A + NE_P + NE_F, 'the composite mesh has the three sections'' elements')
    CALL require(COUNT(md%syrope_is) == NE_P .AND. ALL(md%syrope_is(NE_A + 1:NE_A + NE_P)), &
                 'the Syrope flags sit on the polyester elements only')
    CALL require(ALL(md%ba_dyn(1:NE_A) > 0.0_wp) .AND. ALL(md%ba_dyn(NE_A + NE_P + 1:) > 0.0_wp), &
                 'the chain sections keep their BA damping')
    CALL require(ALL(.NOT. (md%ba_dyn(NE_A + 1:NE_A + NE_P) > 0.0_wp)), &
                 'the polyester takes no legacy BA (its working curve carries the damping)')
    CALL CD_Get_Model_Tension(md, t_syr, es, em)
    ! 2. on the rest curve (a virgin rope: the OWC) at the section's mean strain
    eps_bar = 0.0_wp
    DO e = NE_A + 1, NE_A + NE_P
      eps_bar = eps_bar + (NORM2(md%q(3*md%elem_conn(2, e) - 2:3*md%elem_conn(2, e)) - &
                                 md%q(3*md%elem_conn(1, e) - 2:3*md%elem_conn(1, e))) - md%l0(e))
    END DO
    eps_bar = eps_bar/SUM(md%l0(NE_A + 1:NE_A + NE_P))
    t_bar = SUM(md%l0(NE_A + 1:NE_A + NE_P)*t_syr(NE_A + 1:NE_A + NE_P))/SUM(md%l0(NE_A + 1:NE_A + NE_P))
    PRINT '(A,ES12.5,A,ES12.5,A,ES12.5,A,ES12.5)', '  polyester mean strain ', eps_bar, ', mean tension ', &
      t_bar, ' N, OWC there ', owc(eps_bar), ' N; fairlead tension ', t_syr(NE_A + NE_P + NE_F)
    CALL require(ABS(owc(eps_bar) - t_bar) <= 1.0e-6_wp*t_bar, &
                 'the static polyester section sits on its OWC at its mean strain')
    ! and every polyester element on its own OWC (each takes its own secant)
    worst = 0.0_wp
    DO e = NE_A + 1, NE_A + NE_P
      eps_e = NORM2(md%q(3*md%elem_conn(2, e) - 2:3*md%elem_conn(2, e)) - &
                    md%q(3*md%elem_conn(1, e) - 2:3*md%elem_conn(1, e)))/md%l0(e) - 1.0_wp
      worst = MAX(worst, ABS(owc(eps_e) - t_syr(e))/t_syr(e))
    END DO
    PRINT '(A,ES10.3,A,ES12.5,A,ES12.5,A)', '  polyester elements off their OWC by at most ', worst, &
      ' (tensions ', MINVAL(t_syr(NE_A + 1:NE_A + NE_P)), ' to ', MAXVAL(t_syr(NE_A + 1:NE_A + NE_P)), ' N)'
    CALL require(worst <= 1.0e-8_wp, 'every static polyester element sits on its OWC')
    secant = t_bar/eps_bar
  END ASSOCIATE
  CALL CD_End_Model(models(1), es, em)

  ! 3. the same line with a linear-EA polyester of the converged secant EA
  WRITE (ea_text, '(ES23.16)') secant
  CALL write_deck('csyr_lin.dat', TRIM(ADJUSTL(ea_text)), '0.0')
  CALL CD_Init_Deck_Models('csyr_lin.dat', lin, es, em)
  CALL require(es == CD_DECKDRV_OK, 'the linear-EA twin builds: '//TRIM(em))
  IF (es == CD_DECKDRV_OK) THEN
    CALL CD_Get_Model_Tension(lin(1), t_lin, es, em)
    PRINT '(A,ES10.3)', '  Syrope vs linear-EA twin: max element-tension difference / max tension ', &
      MAXVAL(ABS(t_syr - t_lin))/MAXVAL(t_lin)
    CALL require(MAXVAL(ABS(t_syr - t_lin)) <= 1.0e-6_wp*MAXVAL(t_lin), &
                 'the linear-EA twin of the mean secant EA has the static tensions (to the spread of '// &
                 'the elements'' own secants)')
    CALL CD_End_Model(lin(1), es, em)
  END IF

  ! 4. the dynamics start in the static equilibrium
  CALL still_run()

  ! 5. a SYROPE IC history above the static tension: the Tmax0 working curve
  CALL tmax0_curve()

  ! 6. a pretension above the top of the OWC table
  CALL write_owc('csyr_owc_short.dat', 6)
  CALL write_settings('csyr_settings_short.dat', 'csyr_owc_short.dat')
  CALL write_deck('csyr_short.dat', '"SYROPE:csyr_settings_short.dat|1.53e8|23.12"', '5.0e10|1.0e5')
  CALL CD_Init_Deck_Models('csyr_short.dat', models, es, em)
  CALL require(es /= CD_DECKDRV_OK .AND. INDEX(em, 'above the top of its OWC table') > 0, &
               'a pretension above the OWC table fails closed by name: '//TRIM(em))

  ! 7. an overshooting first solve on a taut two-section rope: alpha (1.53e8 N) at the 3.5 % chord
  ! strain gives 5.4 MN, above the table's 4.4 MN top, while the OWC there is about 2 MN
  CALL taut_rope(20.7_wp, '22.42', 'a taut rope whose first solve overshoots the OWC table')
  ! 8. a lightly loaded, nearly neutrally buoyant rope on the Tmax0 = 2.5 MN working curve, near its
  ! zero-tension strain (about 53 kN), where the plain secant update contracts slowly
  CALL taut_rope(20.2_wp, '16.70', 'a lightly loaded preconditioned rope', tmax0=2.5e6_wp)

  CALL finish()

CONTAINS

  SUBROUTINE still_run()
    !! The composite line run still for 2 s: the fairlead tension stays at its static value.
    INTEGER :: u, ios, n
    CHARACTER(4096) :: row
    REAL(wp) :: t, ft, ft0, dev
    LOGICAL :: conv
    CALL write_deck('csyr_dyn.dat', '"SYROPE:csyr_settings.dat|1.53e8|23.12"', '5.0e10|1.0e5', dynamic=.TRUE.)
    CALL CD_Run_Deck_Driver('csyr_dyn.dat', 'csyr_dyn', conv, es, em)
    CALL require(es == CD_DECKDRV_OK, 'the composite line runs: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    OPEN (NEWUNIT=u, FILE='csyr_dyn.out', STATUS='OLD', ACTION='READ', IOSTAT=ios)
    n = 0
    dev = 0.0_wp
    ft0 = 0.0_wp
    DO
      READ (u, '(A)', IOSTAT=ios) row
      IF (ios /= 0) EXIT
      IF (row(1:1) == '#' .OR. INDEX(row, 'Time') > 0) CYCLE
      READ (row, *, IOSTAT=ios) t, ft
      IF (ios /= 0) CYCLE
      n = n + 1
      IF (n == 1) ft0 = ft
      dev = MAX(dev, ABS(ft - ft0))
    END DO
    CLOSE (u)
    PRINT '(A,I0,A,ES10.3)', '  still run: ', n, ' rows, max |FairTen - FairTen(0)| / FairTen(0) ', dev/ft0
    CALL require(n > 100 .AND. dev <= 1.0e-7_wp*ft0, 'the dynamics start in the static equilibrium')
  END SUBROUTINE still_run

  SUBROUTINE taut_rope(span, mass, what, tmax0)
    !! 20 m of rope in two 10 m Syrope sections between fixed points span apart, of the given mass
    !! per length, a virgin rope or (tmax0 present) a SYROPE IC history: every element must land on
    !! its rest curve (the OWC, or the Tmax0 working curve), inside the table.
    REAL(wp), INTENT(IN) :: span
    CHARACTER(*), INTENT(IN) :: mass, what
    REAL(wp), INTENT(IN), OPTIONAL :: tmax0
    TYPE(CD_ModelType), ALLOCATABLE :: mt(:)
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ten(10), eps_k, wst, tcurve
    INTEGER :: u, k
    CHARACTER(32) :: s_span, s_tmax0
    WRITE (s_span, '(F8.3)') span
    OPEN (NEWUNIT=u, FILE='csyr_taut.dat', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'taut two-section Syrope test deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'poly 0.1438 '//mass//' "SYROPE:csyr_settings.dat|1.53e8|23.12" 5.0e10|1.0e5 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed '//TRIM(ADJUSTL(s_span))//' 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '2 Vessel 0.0 0.0 -100.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    IF (PRESENT(tmax0)) THEN
      WRITE (s_tmax0, '(ES23.16)') tmax0
      WRITE (u, '(A)') '--- SYROPE IC ---'
      WRITE (u, '(A)') 'Line(s) Tmax0 Tmean0'
      WRITE (u, '(A)') '(-) (N) (N)'
      WRITE (u, '(A)') '1 '//TRIM(ADJUSTL(s_tmax0))//' 1.0e5'
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 poly 10.0 5'
    WRITE (u, '(A)') '1 poly 10.0 5'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
    CALL CD_Init_Deck_Models('csyr_taut.dat', mt, es, em)
    CALL require(es == CD_DECKDRV_OK, what//' builds: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    IF (PRESENT(tmax0)) THEN
      CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.20_wp, 1.50_wp, 1.53e8_wp, 23.12_wp, &
                          5.0e10_wp, 1.0e5_wp, es, em)
      CALL require(es == CD_SYROPE_OK, 'reference working curve: '//TRIM(em))
    END IF
    ASSOCIATE (md => mt(1))
      CALL CD_Get_Model_Tension(md, ten, es, em)
      wst = 0.0_wp
      DO k = 1, md%n_elem
        eps_k = NORM2(md%q(3*md%elem_conn(2, k) - 2:3*md%elem_conn(2, k)) - &
                      md%q(3*md%elem_conn(1, k) - 2:3*md%elem_conn(1, k)))/md%l0(k) - 1.0_wp
        IF (PRESENT(tmax0)) THEN
          CALL CD_Syrope_Static_Tension(td, tmax0, eps_k, tcurve, es, em)
        ELSE
          tcurve = owc(eps_k)
        END IF
        wst = MAX(wst, ABS(tcurve - ten(k))/ten(k))
      END DO
      PRINT '(A,ES12.5,A,ES12.5,A,ES10.3)', '  taut rope: tensions ', MINVAL(ten), ' to ', MAXVAL(ten), &
        ' N, elements off their rest curve by at most ', wst
      CALL require(wst <= 1.0e-8_wp .AND. MAXVAL(ten) < OWC_TEN(NOWC), &
                   'every element of '//what//' sits on its rest curve, inside the table')
    END ASSOCIATE
    CALL CD_End_Model(mt(1), es, em)
    IF (PRESENT(tmax0)) CALL CD_Syrope_End(td)
  END SUBROUTINE taut_rope

  SUBROUTINE tmax0_curve()
    !! SYROPE IC Tmax0 = 2.5 MN: the polyester's mean tension is the Tmax0 working curve's at its
    !! mean strain.
    TYPE(CD_ModelType), ALLOCATABLE :: mic(:)
    TYPE(CD_SyropeType) :: td
    REAL(wp) :: ten(NE_A + NE_P + NE_F), eb, tb, tcurve
    INTEGER :: k
    CALL write_deck('csyr_ic.dat', '"SYROPE:csyr_settings.dat|1.53e8|23.12"', '5.0e10|1.0e5', &
                    ic_row='1  2.5e6  1.0e6')
    CALL CD_Init_Deck_Models('csyr_ic.dat', mic, es, em)
    CALL require(es == CD_DECKDRV_OK, 'the composite line with SYROPE IC builds: '//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL CD_Syrope_Init(td, OWC_EPS, OWC_TEN, CD_SYROPE_WC_EXP, 0.20_wp, 1.50_wp, 1.53e8_wp, 23.12_wp, &
                        5.0e10_wp, 1.0e5_wp, es, em)
    CALL require(es == CD_SYROPE_OK, 'reference working curve: '//TRIM(em))
    ASSOCIATE (md => mic(1))
      CALL CD_Get_Model_Tension(md, ten, es, em)
      eb = 0.0_wp
      DO k = NE_A + 1, NE_A + NE_P
        eb = eb + (NORM2(md%q(3*md%elem_conn(2, k) - 2:3*md%elem_conn(2, k)) - &
                         md%q(3*md%elem_conn(1, k) - 2:3*md%elem_conn(1, k))) - md%l0(k))
      END DO
      eb = eb/SUM(md%l0(NE_A + 1:NE_A + NE_P))
      tb = SUM(md%l0(NE_A + 1:NE_A + NE_P)*ten(NE_A + 1:NE_A + NE_P))/SUM(md%l0(NE_A + 1:NE_A + NE_P))
      CALL CD_Syrope_Static_Tension(td, 2.5e6_wp, eb, tcurve, es, em)
      PRINT '(A,ES12.5,A,ES12.5,A,ES12.5,A)', '  SYROPE IC: polyester mean strain ', eb, ', mean tension ', tb, &
        ' N, Tmax0 working curve there ', tcurve, ' N'
      CALL require(es == CD_SYROPE_OK .AND. ABS(tcurve - tb) <= 1.0e-6_wp*tb, &
                   'with SYROPE IC the polyester sits on the Tmax0 working curve')
      CALL require(ALL(md%syrope_tmax(NE_A + 1:NE_A + NE_P) >= 2.5e6_wp), &
                   'every polyester element carries the Tmax0 history')
    END ASSOCIATE
    CALL CD_End_Model(mic(1), es, em)
    CALL CD_Syrope_End(td)
  END SUBROUTINE tmax0_curve

  REAL(wp) FUNCTION owc(eps) RESULT(t)
    !! The OWC table, interpolated linearly.
    REAL(wp), INTENT(IN) :: eps
    INTEGER :: k
    t = OWC_TEN(NOWC)
    DO k = 2, NOWC
      IF (eps <= OWC_EPS(k)) THEN
        t = OWC_TEN(k - 1) + (OWC_TEN(k) - OWC_TEN(k - 1))*(eps - OWC_EPS(k - 1))/(OWC_EPS(k) - OWC_EPS(k - 1))
        RETURN
      END IF
    END DO
  END FUNCTION owc

  SUBROUTINE write_owc(path, nrow)
    CHARACTER(*), INTENT(IN) :: path
    INTEGER, INTENT(IN) :: nrow
    INTEGER :: u, k
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'Strain      Tension'
    WRITE (u, '(A)') '(-)         (N)'
    DO k = 1, nrow
      WRITE (u, '(ES14.6,1X,ES14.6)') OWC_EPS(k), OWC_TEN(k)
    END DO
    CLOSE (u)
  END SUBROUTINE write_owc

  SUBROUTINE write_settings(path, owc_path)
    CHARACTER(*), INTENT(IN) :: path, owc_path
    INTEGER :: u
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') owc_path//'  OWC     - Original working-curve table file'
    WRITE (u, '(A)') 'EXP             WCType  - Working-curve formulation'
    WRITE (u, '(A)') '0.20            k1      - First working-curve shape parameter'
    WRITE (u, '(A)') '1.50            k2      - Second working-curve shape parameter'
    CLOSE (u)
  END SUBROUTINE write_settings

  SUBROUTINE write_deck(path, poly_ea, poly_ba, dynamic, ic_row)
    !! The chain-polyester-chain line (anchor at 780 m), the polyester with the given EA and BA
    !! columns.
    CHARACTER(*), INTENT(IN) :: path, poly_ea, poly_ba
    LOGICAL, INTENT(IN), OPTIONAL :: dynamic
    CHARACTER(*), INTENT(IN), OPTIONAL :: ic_row
    INTEGER :: u
    LOGICAL :: dyn
    dyn = .FALSE.
    IF (PRESENT(dynamic)) dyn = dynamic
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'composite Syrope test deck'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.2791 480.93 2.058e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') 'poly 0.1438 22.42 '//poly_ea//' '//poly_ba//' 0.0 1.2 0.2 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Fixed 780.0 0.0 -200.0 0 0 0 0'
    WRITE (u, '(A)') '2 Vessel 58.0 0.0 -14.0 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    IF (PRESENT(ic_row)) THEN
      WRITE (u, '(A)') '--- SYROPE IC ---'
      WRITE (u, '(A)') 'Line(s) Tmax0 Tmean0'
      WRITE (u, '(A)') '(-) (N) (N)'
      WRITE (u, '(A)') ic_row
    END IF
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 chain 100.0 12'
    WRITE (u, '(A)') '1 poly 400.0 40'
    WRITE (u, '(A)') '1 chain 250.0 25'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '200.0 WtrDpth'
    WRITE (u, '(A)') '3.0e6 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    IF (dyn) THEN
      WRITE (u, '(A)') '0.01 dtM'
      WRITE (u, '(A)') '2.0 TMax'
    END IF
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE require(ok, what)
    LOGICAL, INTENT(IN) :: ok
    CHARACTER(*), INTENT(IN) :: what
    IF (ok) THEN
      PRINT '(A)', 'PASS: '//what
    ELSE
      PRINT '(A)', 'FAIL: '//what
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE finish()
    IF (nfail > 0) THEN
      PRINT '(I0,A)', nfail, ' assertion(s) failed'
      ERROR STOP 1
    END IF
    PRINT '(A)', 'all composite Syrope checks passed'
    STOP
  END SUBROUTINE finish
END PROGRAM test_syrope_composite
