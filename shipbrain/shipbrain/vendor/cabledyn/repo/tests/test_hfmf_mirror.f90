! File: tests/test_hfmf_mirror.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_hfmf_mirror
  !! Gate for the finite-EI cable's continuous-state mirror accessors
  !! (CD_HFMF_MirrorSize / CD_HFMF_PackMirror / CD_HFMF_UnpackMirror), the pieces the
  !! OpenFAST shell's x%states packer appends after the EI=0 mooring block and the
  !! checkpoint-restart rebuild reloads. Builds a real lazy-wave coupled cable from a
  !! deck and checks:
  !!   1) MirrorSize is the free-DOF [v; q; a] layout (three blocks strictly below ndof
  !!      each: the coupled fairlead is prescribed) plus the committed-boundary block ([q; v; a]
  !!      of the held DOFs, end-connection directions, parent frame) and the force-blend block
  !!      (validity flag, committed force) of the default force blend;
  !!   2) PackMirror fills a correctly sized buffer with finite values whose velocity
  !!      AND acceleration blocks are zero at the static IC (rest), confirming the
  !!      [v_free; q_free; a_free] order;
  !!   3) UnpackMirror ROUND-TRIPS: perturb the packed state, unpack into a second
  !!      identically built cable, re-pack -- bit-identical buffers, and the line clock
  !!      carries the restart time;
  !!   4) wrong-sized / non-finite buffers, a non-orthogonal parent orientation and a
  !!      non-finite time fail closed.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_DeckDriver, ONLY: CD_Init_Deck_HermiteCable, CD_DECKDRV_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_ModuleType, CD_HFMF_MirrorSize, CD_HFMF_PackMirror, &
                                          CD_HFMF_UnpackMirror, CD_HFMF_FrictionMirrorSize, CD_HFMF_ForceMirrorSize, &
                                          CD_HFMF_BoundaryMirrorSize, &
                                          CD_HFMF_End, CD_HFMF_OK, CD_HFMF_BADINPUT
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE, IEEE_VALUE, IEEE_QUIET_NAN
  IMPLICIT NONE
  INTEGER :: nfail
  TYPE(CD_HFMF_ModuleType) :: cable, twin
  INTEGER :: es, cn, n, nf, i, nx, kb
  CHARACTER(512) :: em
  REAL(wp), ALLOCATABLE :: buf(:), buf2(:), badbuf(:)

  nfail = 0
  CALL write_cable_deck('hfmf_mirror.dat')
  CALL CD_Init_Deck_HermiteCable('hfmf_mirror.dat', 0.05_wp, cable, cn, es, em)
  CALL require(es == CD_DECKDRV_OK, 'init cable deck: '//TRIM(em))
  IF (es /= CD_DECKDRV_OK) THEN
    CALL finish()
  END IF

  ! (1) size: [v; q; a] of the free DOFs (strictly below 3*ndof: the coupled node is
  !     prescribed) plus the committed-boundary and force-blend blocks of the default force blend
  n = CD_HFMF_MirrorSize(cable)
  nx = CD_HFMF_FrictionMirrorSize(cable) + CD_HFMF_BoundaryMirrorSize(cable) + CD_HFMF_ForceMirrorSize(cable)
  nf = (n - nx)/3
  CALL require(n > 0, 'mirror size positive')
  CALL require(MOD(n - nx, 3) == 0, 'free-DOF part a multiple of three ([v; q; a])')
  CALL require(3*nf < 3*cable%line%ndof, 'free-DOF part below 3*ndof (some DOFs prescribed/fixed)')
  CALL require(CD_HFMF_BoundaryMirrorSize(cable) == 3*(cable%line%ndof - nf) + 21, &
               'boundary block: held-DOF [q; v; a], end-connection directions, parent frame')
  CALL require(CD_HFMF_ForceMirrorSize(cable) == 1 + cable%line%ndof, 'force-blend block: flag, committed force')

  ! (2) pack a correctly sized buffer: finite, velocity + acceleration blocks zero at rest
  ALLOCATE (buf(n), buf2(n))
  CALL CD_HFMF_PackMirror(cable, buf, es, em)
  CALL require(es == CD_HFMF_OK, 'pack ok: '//TRIM(em))
  CALL require(ALL(IEEE_IS_FINITE(buf)), 'packed values finite')
  IF (nf >= 1) THEN
    ! ABS(.) >= 0, so "<= 0" asserts an exact zero without a REAL equality compare.
    CALL require(nan_max_abs(buf(1:nf)) <= 0.0_wp, 'velocity block is zero at the static IC')
    CALL require(nan_max_abs(buf(nf + 1:2*nf)) > 0.0_wp, 'position block is nonzero (real geometry)')
    ! the acceleration block is the equations-consistent residual acceleration at the
    ! static IC -- near zero at the static tolerance scale, not an exact zero (the hydro
    ! setters recompute it after configuration)
    CALL require(nan_max_abs(buf(2*nf + 1:3*nf)) <= 1.0e-2_wp, 'acceleration block is near-zero at the static IC')
  END IF

  ! (3) unpack round-trip into an identically built twin: perturbed [v; q; a] survives
  !     bit-for-bit (held DOFs and parent frame included) and the clock carries the restart time
  CALL CD_Init_Deck_HermiteCable('hfmf_mirror.dat', 0.05_wp, twin, cn, es, em)
  CALL require(es == CD_DECKDRV_OK, 'init twin: '//TRIM(em))
  DO i = 1, n
    buf(i) = buf(i) + 1.0e-3_wp*REAL(i, wp)   ! a deterministic mid-flight-like state
  END DO
  ! the parent orientation stays a rotation (a quarter turn about z), the force-blend validity
  ! flag is 0 or 1 (a committed force at the restored state)
  kb = 3*nf + CD_HFMF_FrictionMirrorSize(cable) + 3*(cable%line%ndof - nf)
  buf(kb + 7:kb + 15) = [0.0_wp, 1.0_wp, 0.0_wp, -1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp]
  IF (CD_HFMF_ForceMirrorSize(cable) > 0) buf(kb + 22) = 1.0_wp
  CALL CD_HFMF_UnpackMirror(twin, buf, 12.5_wp, es, em)
  CALL require(es == CD_HFMF_OK, 'unpack ok: '//TRIM(em))
  CALL require(ABS(twin%line%t - 12.5_wp) <= 0.0_wp, 'restart time set on the line clock')
  CALL CD_HFMF_PackMirror(twin, buf2, es, em)
  CALL require(es == CD_HFMF_OK, 're-pack ok')
  CALL require(nan_max_abs(buf2 - buf) <= 0.0_wp, 'unpack -> pack round-trips bit-identically')
  CALL require(nan_max_abs(twin%parent_dcm(:, 1) - [0.0_wp, 1.0_wp, 0.0_wp]) <= 0.0_wp, &
               'the parent orientation reloads from the boundary block')

  ! (4) fail-closed edges
  ALLOCATE (badbuf(n + 1))
  CALL CD_HFMF_PackMirror(cable, badbuf, es, em)
  CALL require(es == CD_HFMF_BADINPUT, 'wrong-sized pack buffer fails closed')
  CALL CD_HFMF_UnpackMirror(twin, badbuf, 1.0_wp, es, em)
  CALL require(es == CD_HFMF_BADINPUT, 'wrong-sized unpack buffer fails closed')
  buf(1) = IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN)
  CALL CD_HFMF_UnpackMirror(twin, buf, 1.0_wp, es, em)
  CALL require(es == CD_HFMF_BADINPUT, 'non-finite mirror fails closed')
  buf(1) = 0.0_wp
  buf(kb + 7) = 2.0_wp
  CALL CD_HFMF_UnpackMirror(twin, buf, 1.0_wp, es, em)
  CALL require(es == CD_HFMF_BADINPUT, 'a non-orthogonal parent orientation fails closed')
  buf(kb + 7) = 0.0_wp
  CALL CD_HFMF_UnpackMirror(twin, buf, IEEE_VALUE(1.0_wp, IEEE_QUIET_NAN), es, em)
  CALL require(es == CD_HFMF_BADINPUT, 'non-finite restart time fails closed')

  CALL CD_HFMF_End(cable)
  CALL CD_HFMF_End(twin)
  CALL finish()

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, msg)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: msg
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'MISMATCH: '//msg
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE finish()
    IF (nfail > 0) THEN
      WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
      ERROR STOP 1
    END IF
    WRITE (*, '(A)') 'PASS: CD_HFMF continuous-state mirror accessors'
    STOP 0
  END SUBROUTINE finish

  SUBROUTINE write_cable_deck(path)
    !! A finite-EI lazy-wave power cable, coupled at the fairlead (End A), fixed anchor
    !! at End B -- the Humboldt/GoMex 15 MW bare + buoyancy-module convention.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    WRITE (u, '(A)') 'finite-EI lazy-wave power cable, coupled fairlead (mirror-accessor gate)'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'bare 0.16 36.70 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') 'buoy 0.29 59.53 4.69e8 0.0 1.99e4 1.2 0.1 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0.0 0.0 -56.0'
    WRITE (u, '(A)') '2 Coupled 90.0 0.0 -14.0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A)') '1 bare 40.0 13'
    WRITE (u, '(A)') '1 buoy 50.0 16'
    WRITE (u, '(A)') '1 bare 55.0 18'
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.5 rhoInf'
    WRITE (u, '(A)') '--- need this line ---'
    CLOSE (u)
  END SUBROUTINE write_cable_deck

END PROGRAM test_hfmf_mirror
