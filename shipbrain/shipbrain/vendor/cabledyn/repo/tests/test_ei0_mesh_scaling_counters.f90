! File: tests/test_ei0_mesh_scaling_counters.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_ei0_mesh_scaling_counters
  !! PORTABLE-COUNTER mesh-scaling gate for the standalone EI=0 dynamic route.
  !! Wall-clock gates are machine-bound; the regression tripwires here are COUNTS.
  !!
  !! Rig: the committed held-fairlead chain deck (path = argument 1; 410 m studless chain,
  !! 50 m depth, seabed contact, BA damping, added mass) re-meshed from 41 to 82 and to
  !! 820 segments, then marched 200 steps at dt = 0.05 s through the production
  !! recovering step. A fine mesh of this stiff chain drives the Newton residual onto its
  !! round-off floor (eps*|q|*||A||, which grows with EA/l0) above rel_tol*scale; if the
  !! solver cannot recognise that floor, every step exhausts its iteration budget and is
  !! re-solved by temporal subdivision, and the run cost grows ~cubically with the mesh
  !! (820 segments took minutes instead of about a second).
  !!
  !! Gates (counts only; each holds >= 2x headroom over the measured values):
  !!   * every step converges, no hard errors;
  !!   * no nominal step needs temporal subdivision at either mesh;
  !!   * mean Newton iterations per step <= 6 at both meshes (measured ~2-3), and the
  !!     820-segment mean exceeds the 82-segment mean by at most 2;
  !!   * the element-band route never allocates the dense (n_dof x n_dof) mass workspace.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Step_Model_Recovering, CD_End_Model, CD_MODEL_OK
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_Models, CD_DECKDRV_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: DT = 0.05_wp
  INTEGER, PARAMETER :: NSTEP = 200
  REAL(wp), PARAMETER :: MEAN_ITER_GATE = 6.0_wp, MEAN_ITER_GROWTH_GATE = 2.0_wp
  CHARACTER(1024) :: deck
  REAL(wp) :: mean_coarse, mean_fine
  INTEGER :: nfail

  nfail = 0
  IF (COMMAND_ARGUMENT_COUNT() < 1) THEN
    WRITE (*, '(A)') 'FAIL: deck path argument required'
    ERROR STOP 1
  END IF
  CALL GET_COMMAND_ARGUMENT(1, deck)

  CALL run_mesh(82, mean_coarse)
  CALL run_mesh(820, mean_fine)
  CALL require(mean_fine - mean_coarse <= MEAN_ITER_GROWTH_GATE, &
               'mean Newton iterations per step must not grow with the mesh')

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' gate(s) tripped'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: EI=0 mesh-scaling counters'

CONTAINS

  SUBROUTINE run_mesh(nseg, mean_iter)
    INTEGER, INTENT(IN) :: nseg
    REAL(wp), INTENT(OUT) :: mean_iter

    TYPE(CD_ModelType), ALLOCATABLE :: models(:)
    CHARACTER(64) :: path
    CHARACTER(160) :: label
    CHARACTER(512) :: em
    INTEGER :: es, istep, n_iter, nsub, n_subdivided, iter_sum, iter_max
    LOGICAL :: conv, stalled, all_conv

    mean_iter = HUGE(1.0_wp)
    WRITE (path, '(A,I0,A)') 'ei0_mesh_scaling_', nseg, '.dat'
    CALL write_remeshed_deck(TRIM(deck), TRIM(path), nseg)
    IF (nfail > 0) RETURN
    CALL CD_Init_Deck_Models(TRIM(path), models, es, em)
    WRITE (label, '(A,I0,A)') 'deck init at ', nseg, ' segments: '
    CALL require(es == CD_DECKDRV_OK, TRIM(label)//TRIM(em))
    IF (es /= CD_DECKDRV_OK) RETURN
    CALL require(SIZE(models) == 1, 'one line model')
    IF (SIZE(models) /= 1) RETURN

    n_subdivided = 0
    iter_sum = 0
    iter_max = 0
    all_conv = .TRUE.
    DO istep = 1, NSTEP
      CALL CD_Step_Model_Recovering(models(1), DT, conv, stalled, n_iter, es, em, substeps_used=nsub)
      IF (es /= CD_MODEL_OK .OR. .NOT. conv) THEN
        WRITE (*, '(A,I0,A,I0,A)') 'step ', istep, ' at ', nseg, ' segments failed: '//TRIM(em)
        all_conv = .FALSE.
        EXIT
      END IF
      IF (nsub > 1) n_subdivided = n_subdivided + 1
      iter_sum = iter_sum + n_iter
      iter_max = MAX(iter_max, n_iter)
    END DO
    mean_iter = REAL(iter_sum, wp)/REAL(NSTEP, wp)
    WRITE (*, '(A,I0,A,F6.2,A,I0,A,I0)') 'segments=', nseg, ' mean_iter=', mean_iter, ' max_iter=', iter_max, &
      ' subdivided=', n_subdivided

    WRITE (label, '(A,I0,A)') ' (', nseg, ' segments)'
    CALL require(all_conv, 'every step converges'//TRIM(label))
    CALL require(n_subdivided == 0, 'no nominal step needs temporal subdivision'//TRIM(label))
    CALL require(mean_iter <= MEAN_ITER_GATE, 'mean Newton iterations per step within the gate'//TRIM(label))
    CALL require(.NOT. ALLOCATED(models(1)%dynamic_workspace%M), &
                 'element-band route never allocates the dense mass workspace'//TRIM(label))
    CALL CD_End_Model(models(1), es, em)
  END SUBROUTINE run_mesh

  SUBROUTINE write_remeshed_deck(src, dst, nseg)
    !! Copy the deck, replacing NumSegs on the single SECTIONS row.
    CHARACTER(*), INTENT(IN) :: src, dst
    INTEGER, INTENT(IN) :: nseg

    CHARACTER(512) :: line
    CHARACTER(32) :: line_id, type_name, length_txt, segs_txt
    INTEGER :: uin, uout, ios, n_replaced
    LOGICAL :: in_sections

    OPEN (NEWUNIT=uin, FILE=src, STATUS='old', ACTION='read', IOSTAT=ios)
    CALL require(ios == 0, 'open source deck '//src)
    IF (ios /= 0) RETURN
    OPEN (NEWUNIT=uout, FILE=dst, STATUS='replace', ACTION='write', IOSTAT=ios)
    CALL require(ios == 0, 'open re-meshed deck '//dst)
    IF (ios /= 0) THEN
      CLOSE (uin)
      RETURN
    END IF
    in_sections = .FALSE.
    n_replaced = 0
    DO
      READ (uin, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (INDEX(line, '----') > 0) in_sections = INDEX(line, 'SECTIONS') > 0
      IF (in_sections .AND. INDEX(line, 'chain') > 0) THEN
        READ (line, *, IOSTAT=ios) line_id, type_name, length_txt, segs_txt
        IF (ios == 0 .AND. TRIM(type_name) == 'chain') THEN
          WRITE (line, '(A,1X,A,1X,A,1X,I0)') TRIM(line_id), TRIM(type_name), TRIM(length_txt), nseg
          n_replaced = n_replaced + 1
        END IF
      END IF
      WRITE (uout, '(A)') TRIM(line)
    END DO
    CLOSE (uin)
    CLOSE (uout)
    CALL require(n_replaced == 1, 're-mesh exactly one SECTIONS row')
  END SUBROUTINE write_remeshed_deck

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'FAIL: '//label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_ei0_mesh_scaling_counters
