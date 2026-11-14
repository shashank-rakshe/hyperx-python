! ##################################################################################################################################
! Begin MIT license text.
! _______________________________________________________________________________________________________

! Copyright 2022 Dr William R Case, Jr (mystransolver@gmail.com)

! Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
! associated documentation files (the "Software"), to deal in the Software without restriction, including
! without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
! copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to
! the following conditions:

! The above copyright notice and this permission notice shall be included in all copies or substantial
! portions of the Software and documentation.

! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
! OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
! THE SOFTWARE.
! _______________________________________________________________________________________________________

! End MIT license text.

      SUBROUTINE REBUILD_KLLD_FROM_KGGD

! Re-entrant rebuild of the L-set differential stiffness matrix KLLD from the displacement field currently held in UG_COL.
!
! This is the SOL 105 step-2 LINK2 reduction chain (KGGD -> KNND -> KFFD -> KAAD -> KLLD) wrapped so the multi-buckling-subcase
! driver added to LINK4 (Phase 4) can rebuild KLLD once per buckling subcase (each with its own preload UG_COL) without
! re-entering all of LINK1 and LINK2.
!
! Caller responsibilities:
!   * SOL_NAME(1:8) == 'BUCKLING' and LOAD_ISTEP == 2. Each of the four reducers below internally branches on those globals to
!     run the D-only path. (Verify LOAD_ISTEP at call site; callers from LINK4 do not modify it.)
!   * UG_COL must already be loaded with the preload static displacement field for the buckling subcase being assembled
!     (typically by READ_L5A_UG_FOR_SUBCASE). This routine then calls BUILD_KGGD_FROM_UG which assembles KGGD from UG_COL.
!   * Files L2A and L2E (containing GMN and GOA respectively) must remain on disk with CLOSE_STAT='KEEP'. REDUCE_KGGD_TO_KNND
!     and REDUCE_KFFD_TO_KAAD self-load GMN/GOA from those files when not in memory.
!
! Re-entry safety: any pre-existing D-side derived matrices (KNND/KNMD/KMMD/KFFD/KFSD/KSSD/KAAD/KAOD/KOOD/KLLD/KRLD/KRRD) and
! any intermediate transposes/partitions (GMNt, KMND) are deallocated before the reduction chain is re-run. KGGD itself is
! also deallocated as part of the cleanup; BUILD_KGGD_FROM_UG rebuilds it afresh from UG_COL.
!
! KLL/MLL (the non-differential L-set matrices used in the buckling eigenproblem alongside KLLD) are NOT touched: those are
! built once during LINK2 step 1 and must persist across all buckling-subcase iterations. LINK4 already snapshots/restores
! KLL via KLL_BAK because the eigensolver consumes it destructively.

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG
      USE IOUNT1, ONLY                :  ERR, F06, SC1
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, SOL_NAME,                                                                   &
                                         NTERM_KNND, NTERM_KNMD, NTERM_KMMD,                                                       &
                                         NTERM_KFFD, NTERM_KFSD, NTERM_KSSD,                                                       &
                                         NTERM_KAAD, NTERM_KAOD, NTERM_KOOD,                                                       &
                                         NTERM_KLLD, NTERM_KRLD, NTERM_KRRD
      USE NONLINEAR_PARAMS, ONLY      :  LOAD_ISTEP
      USE SPARSE_MATRICES, ONLY       :  I_KNND, J_KNND, KNND, I_KNMD, J_KNMD, KNMD, I_KMMD, J_KMMD, KMMD,                         &
                                         I_KFFD, J_KFFD, KFFD, I_KFSD, J_KFSD, KFSD, I_KSSD, J_KSSD, KSSD,                         &
                                         I_KAAD, J_KAAD, KAAD, I_KAOD, J_KAOD, KAOD, I_KOOD, J_KOOD, KOOD,                         &
                                         I_KLLD, J_KLLD, KLLD, I_KRLD, J_KRLD, KRLD, I_KRRD, J_KRRD, KRRD,                         &
                                         I_GMN , J_GMN , GMN , I_GMNt, J_GMNt, GMNt, I_KMND, J_KMND, KMND,                         &
                                         I_GOA , J_GOA , GOA , I_GOAt, J_GOAt, GOAt

      USE REBUILD_KLLD_FROM_KGGD_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'REBUILD_KLLD_FROM_KGGD'



! **********************************************************************************************************************************
! Guard: this routine is BUCKLING step-2 only.

      IF ((SOL_NAME(1:8) /= 'BUCKLING') .OR. (LOAD_ISTEP /= 2)) THEN
         WRITE(ERR,9101) SUBR_NAME, SOL_NAME, LOAD_ISTEP
         WRITE(F06,9101) SUBR_NAME, SOL_NAME, LOAD_ISTEP
         RETURN
      ENDIF

! **********************************************************************************************************************************
! 1) Drop all stale D-side derived matrices from any prior iteration.
!    These are everything REDUCE_G_NM/REDUCE_N_FS/REDUCE_F_AO/REDUCE_A_LR allocate on the D-only step-2 path.

      IF (ALLOCATED(KNND) .OR. ALLOCATED(I_KNND) .OR. ALLOCATED(J_KNND)) CALL DEALLOCATE_SPARSE_MAT ( 'KNND' )
      IF (ALLOCATED(KNMD) .OR. ALLOCATED(I_KNMD) .OR. ALLOCATED(J_KNMD)) CALL DEALLOCATE_SPARSE_MAT ( 'KNMD' )
      IF (ALLOCATED(KMMD) .OR. ALLOCATED(I_KMMD) .OR. ALLOCATED(J_KMMD)) CALL DEALLOCATE_SPARSE_MAT ( 'KMMD' )
      IF (ALLOCATED(KFFD) .OR. ALLOCATED(I_KFFD) .OR. ALLOCATED(J_KFFD)) CALL DEALLOCATE_SPARSE_MAT ( 'KFFD' )
      IF (ALLOCATED(KFSD) .OR. ALLOCATED(I_KFSD) .OR. ALLOCATED(J_KFSD)) CALL DEALLOCATE_SPARSE_MAT ( 'KFSD' )
      IF (ALLOCATED(KSSD) .OR. ALLOCATED(I_KSSD) .OR. ALLOCATED(J_KSSD)) CALL DEALLOCATE_SPARSE_MAT ( 'KSSD' )
      IF (ALLOCATED(KAAD) .OR. ALLOCATED(I_KAAD) .OR. ALLOCATED(J_KAAD)) CALL DEALLOCATE_SPARSE_MAT ( 'KAAD' )
      IF (ALLOCATED(KAOD) .OR. ALLOCATED(I_KAOD) .OR. ALLOCATED(J_KAOD)) CALL DEALLOCATE_SPARSE_MAT ( 'KAOD' )
      IF (ALLOCATED(KOOD) .OR. ALLOCATED(I_KOOD) .OR. ALLOCATED(J_KOOD)) CALL DEALLOCATE_SPARSE_MAT ( 'KOOD' )
      IF (ALLOCATED(KLLD) .OR. ALLOCATED(I_KLLD) .OR. ALLOCATED(J_KLLD)) CALL DEALLOCATE_SPARSE_MAT ( 'KLLD' )
      IF (ALLOCATED(KRLD) .OR. ALLOCATED(I_KRLD) .OR. ALLOCATED(J_KRLD)) CALL DEALLOCATE_SPARSE_MAT ( 'KRLD' )
      IF (ALLOCATED(KRRD) .OR. ALLOCATED(I_KRRD) .OR. ALLOCATED(J_KRRD)) CALL DEALLOCATE_SPARSE_MAT ( 'KRRD' )

! 2) Drop intermediate transposes / partitions that REDUCE_KGGD_TO_KNND allocates internally and does not deallocate
!    in time for the next call (GMNt is freed at end of REDUCE_KGGD_TO_KNND; KMND is held until LINK2 end). GMN/GOA are
!    self-loaded from L2A/L2E so dropping any in-memory copy here forces a fresh read.

      IF (ALLOCATED(GMNt) .OR. ALLOCATED(I_GMNt) .OR. ALLOCATED(J_GMNt)) CALL DEALLOCATE_SPARSE_MAT ( 'GMNt' )
      IF (ALLOCATED(KMND) .OR. ALLOCATED(I_KMND) .OR. ALLOCATED(J_KMND)) CALL DEALLOCATE_SPARSE_MAT ( 'KMND' )
      IF (ALLOCATED(GOAt) .OR. ALLOCATED(I_GOAt) .OR. ALLOCATED(J_GOAt)) CALL DEALLOCATE_SPARSE_MAT ( 'GOAt' )
      IF (ALLOCATED(GMN)  .OR. ALLOCATED(I_GMN)  .OR. ALLOCATED(J_GMN))  CALL DEALLOCATE_SPARSE_MAT ( 'GMN'  )
      IF (ALLOCATED(GOA)  .OR. ALLOCATED(I_GOA)  .OR. ALLOCATED(J_GOA))  CALL DEALLOCATE_SPARSE_MAT ( 'GOA'  )

! 3) Rebuild KGGD at the G-set from the current UG_COL. BUILD_KGGD_FROM_UG itself deallocs any stale KGGD before fresh assembly.

      CALL BUILD_KGGD_FROM_UG

! 4) Re-zero the D-side term counters. Mirror the same zero-out that LINK2 step 2 performs before the four reducers.

      NTERM_KNND = 0
      NTERM_KNMD = 0
      NTERM_KMMD = 0
      NTERM_KFFD = 0
      NTERM_KFSD = 0
      NTERM_KSSD = 0
      NTERM_KAAD = 0
      NTERM_KAOD = 0
      NTERM_KOOD = 0
      NTERM_KLLD = 0
      NTERM_KRLD = 0
      NTERM_KRRD = 0

! 5) Re-run the LINK2 reduction chain. Each of these branches on (SOL_NAME=='BUCKLING' .AND. LOAD_ISTEP==2) and walks
!    the D-only code path that produces the corresponding D matrix at the next reduced set.

      CALL REDUCE_G_NM            ! KGGD  -> KNND
      CALL REDUCE_N_FS            ! KNND  -> KFFD
      CALL REDUCE_F_AO            ! KFFD  -> KAAD
      CALL REDUCE_A_LR            ! KAAD  -> KLLD

      RETURN

! **********************************************************************************************************************************
 9101 FORMAT(' *ERROR  9101: ',A,' was called with SOL_NAME = "',A,'" and LOAD_ISTEP = ',I0,                                       &
             '. This routine is only valid for BUCKLING step 2; ignoring call.')

      END SUBROUTINE REBUILD_KLLD_FROM_KGGD
