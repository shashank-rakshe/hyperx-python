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

      SUBROUTINE WRITE_GRD_PRT_OUTPUTS ( JVEC, NUM, WHAT, IHDR, ALL_SAME_CID, WRITE_OGEL )

! Writes printed output for grid point related quantities (accels, displacements, eigenvectors, applied loads and SPC, MPC forces)

      USE PENTIUM_II_KIND, ONLY       :  BYTE, LONG, DOUBLE
      USE IOUNT1, ONLY                :  WRT_ERR, ERR, F06, PCH
      USE SCONTR, ONLY                :  BLNK_SUB_NAM, FATAL_ERR, INT_SC_NUM, MELGP, MOGEL, NDOFR, NVEC, NUM_CB_DOFS,              &
                                         SOL_NAME
      USE TIMDAT, ONLY                :  TSEC
      USE CONSTANTS_1, ONLY           :  ZERO
      USE DEBUG_PARAMETERS, ONLY      :  DEBUG
      USE NONLINEAR_PARAMS, ONLY      :  LOAD_ISTEP
      USE LINK9_STUFF, ONLY           :  GID_OUT_ARRAY, MAXREQ, OGEL
      USE MODEL_STUF, ONLY            :  SCNUM, SUBLOD
      USE MACHINE_PARAMS, ONLY        :  MACH_LARGE_NUM

      USE WRITE_GRD_PRT_OUTPUTS_USE_IFs

      IMPLICIT NONE

      CHARACTER(LEN=LEN(BLNK_SUB_NAM)):: SUBR_NAME = 'WRITE_GRD_PRT_OUTPUTS'
      CHARACTER(LEN=*) , INTENT(IN)   :: IHDR              ! Indicator of whether to write an output header in this use of this subr
      CHARACTER(LEN=*) , INTENT(IN)   :: WHAT              ! Indicator whether to process displ or force output requests
      CHARACTER(1*BYTE), INTENT(IN)   :: ALL_SAME_CID      ! Indicator of whether all grids, for the output set, have the same
!                                                            global coord sys
      CHARACTER(14*BYTE)              :: OGEL_CHAR(MOGEL)  ! Char representation of 1 row of OGEL outputs

      CHARACTER( 1*BYTE)              :: PRINT_TOTALS      ! This will be set to 'Y' if DEBUG(92) > 0 so OLOAD, SPCF, MPCF force
!                                                            totals will be printed even if ALL_SAME_CID = 'N'
      CHARACTER(14*BYTE)              :: ABS_ANS_CHAR(6)   ! Character variable that contains the 6 grid abs  outputs
      CHARACTER(14*BYTE)              :: MAX_ANS_CHAR(6)   ! Character variable that contains the 6 grid max  outputs
      CHARACTER(14*BYTE)              :: MIN_ANS_CHAR(6)   ! Character variable that contains the 6 grid min  outputs
      CHARACTER(14*BYTE)              :: TOTALS_CHAR(6)    ! Character variable that contains the 6 grid tot  outputs
      CHARACTER(108*BYTE)             :: LINE_BUF          ! Pre-assembled per-grid output line (matches FORMAT 9902 layout)

      INTEGER(LONG), INTENT(IN)       :: JVEC              ! Sol'n vector num. Can be internal subcase number or eigenvector number
      INTEGER(LONG), INTENT(IN)       :: NUM               ! The number of rows of OGEL to write out
      INTEGER(LONG)                   :: BDY_COMP          ! Component (1-6) for a boundary DOF in CB analyses
      INTEGER(LONG)                   :: BDY_GRID          ! Grid for a boundary DOF in CB analyses
      INTEGER(LONG)                   :: BDY_DOF_NUM       ! DOF number for BDY_GRID/BDY_COMP
      INTEGER(LONG)                   :: I,J               ! DO loop indices
      INTEGER(LONG)                   :: LINES_WRITTEN     ! Number of lines written for the grids


      REAL(DOUBLE)                    :: ABS_ANS(6)        ! Max Abs for all grids output for each of the 6 disp components
      REAL(DOUBLE)                    :: MAX_ANS(6)        ! Max for all grids output for each of the 6 disp components
      REAL(DOUBLE)                    :: MIN_ANS(6)        ! Min for all grids output for each of the 6 disp components
      REAL(DOUBLE)                    :: TOTALS(6)         ! Totals of each of the 6 components output

      CHARACTER(1*BYTE), INTENT(IN)   :: WRITE_OGEL(NUM)   ! 'Y'/'N' as to whether to write OGEL for a grid (used to avoid writing
!                                                            constr forces in subr this subr for grids that have no constr force
      INTRINSIC                       :: MAX, MIN, DABS



! **********************************************************************************************************************************
!  Make sure that WHAT is a valid value

      IF ((WHAT == 'ACCE') .OR. (WHAT == 'DISP') .OR. (WHAT == 'OLOAD') .OR. (WHAT == 'SPCF') .OR. (WHAT == 'MPCF')) THEN
         CONTINUE
      ELSE
         WRITE(ERR,9100) WHAT
         WRITE(F06,9100) WHAT
         FATAL_ERR = FATAL_ERR + 1
         CALL OUTA_HERE ( 'Y' )
      ENDIF

! Write output headers.

      IF (IHDR == 'Y') THEN

         CALL WRITE_SUBCASE_EIGENVEC_HEADER(JVEC, .TRUE.)
         IF (SOL_NAME(1:12) == 'GEN CB MODEL') THEN   ! Write info on what CB DOF the output is for

            IF ((JVEC <= NDOFR) .OR. (JVEC >= NDOFR+NVEC)) THEN
               IF (JVEC <= NDOFR) THEN
                  BDY_DOF_NUM = JVEC
               ELSE
                  BDY_DOF_NUM = JVEC-(NDOFR+NVEC)
               ENDIF
               CALL GET_GRID_AND_COMP ( 'R ', BDY_DOF_NUM, BDY_GRID, BDY_COMP  )
            ENDIF

               IF       (JVEC <= NDOFR) THEN
                  WRITE(F06,9013) JVEC, NUM_CB_DOFS, 'acceleration', BDY_GRID, BDY_COMP
               ELSE IF ((JVEC > NDOFR) .AND. (JVEC <= NDOFR+NVEC)) THEN
                  WRITE(F06,9015) JVEC, NUM_CB_DOFS, JVEC-NDOFR
               ELSE
                  WRITE(F06,9013) JVEC, NUM_CB_DOFS, 'displacement', BDY_GRID, BDY_COMP
               ENDIF
         ENDIF

         IF (WHAT == 'ACCE') THEN
            IF (SOL_NAME(1:12) == 'GEN CB MODEL') THEN
               WRITE(F06,9314)
            ENDIF

         ELSE IF (WHAT == 'DISP') THEN
            IF    ((SOL_NAME(1:7) == 'STATICS') .OR. (SOL_NAME(1:8) == 'NLSTATIC')) THEN
               WRITE(F06,9322)
            ELSE IF ((SOL_NAME(1:8) == 'BUCKLING') .AND. (LOAD_ISTEP == 1)) THEN
               WRITE(F06,9322)
            ELSE IF ((SOL_NAME(1:8) == 'BUCKLING') .AND. (LOAD_ISTEP == 2)) THEN
               WRITE(F06,9323)
            ELSE IF (SOL_NAME(1:5) == 'MODES') THEN
               WRITE(F06,9323)
            ELSE IF (SOL_NAME(1:12) == 'GEN CB MODEL') THEN
               WRITE(F06,9324)
            ENDIF

         ELSE IF (WHAT == 'OLOAD') THEN
            WRITE(F06,9331)
            IF (SUBLOD(INT_SC_NUM,2) > 0) THEN
               WRITE(F06,9332)
            ENDIF

         ELSE IF (WHAT == 'SPCF') THEN
            IF (SOL_NAME(1:12) == 'GEN CB MODEL') THEN
               WRITE(F06,9342)
            ELSE
               WRITE(F06,9341)
            ENDIF

         ELSE IF (WHAT == 'MPCF') THEN
            IF (SOL_NAME(1:12) == 'GEN CB MODEL') THEN
               WRITE(F06,9352)
            ELSE
               WRITE(F06,9351)
            ENDIF
         ENDIF
         WRITE(F06,9501)


      ENDIF

! Get MAX, MIN, ABS values

      DO J=1,6
         MAX_ANS(J) = -MACH_LARGE_NUM
      ENDDO

      DO I=1,NUM
         DO J=1,6
            IF (OGEL(I,J) > MAX_ANS(J)) THEN
               MAX_ANS(J) = OGEL(I,J)
            ENDIF
         ENDDO
      ENDDO

      DO J=1,6
         MIN_ANS(J) = MAX_ANS(J)
      ENDDO

      DO I=1,NUM
         DO J=1,6
            IF (OGEL(I,J) < MIN_ANS(J)) THEN
               MIN_ANS(J) = OGEL(I,J)
            ENDIF
         ENDDO
      ENDDO

      DO I=1,6
         ABS_ANS(I) = MAX( DABS(MAX_ANS(I)), DABS(MIN_ANS(I)) )
      ENDDO

      DO I=1,6
         IF (ABS(ABS_ANS(I)) == ZERO) THEN
            ABS_ANS_CHAR(I) = '  0.0         '
         ELSE
            CALL FMT_ES14_6 ( ABS_ANS(I), ABS_ANS_CHAR(I) )
         ENDIF
         IF (ABS(MAX_ANS(I)) == ZERO) THEN
            MAX_ANS_CHAR(I) = '  0.0         '
         ELSE
            CALL FMT_ES14_6 ( MAX_ANS(I), MAX_ANS_CHAR(I) )
         ENDIF
         IF (ABS(MIN_ANS(I)) == ZERO) THEN
            MIN_ANS_CHAR(I) = '  0.0         '
         ELSE
            CALL FMT_ES14_6 ( MIN_ANS(I), MIN_ANS_CHAR(I) )
         ENDIF
      ENDDO

! Write accels, displ's, applied forces or SPC forces (also calc TOTALS for forces if that is being output)
! TOTALS(J) is summation of G.P. values of applied forces, SPC forces, or MFC forces, for each of the J=1,6 components.

      TOTALS = ZERO

! Pre-fill the fixed-whitespace positions of LINE_BUF that match FORMAT 9902 = (6X,2(1X,I8),6A).
! Variable fields (GID, COORD, 6x14-char values) are overwritten per iteration in the loop below.
      LINE_BUF = ' '

      LINES_WRITTEN = 0
      DO I=1,NUM

         IF ((WHAT == 'OLOAD') .OR. (WHAT == 'SPCF') .OR. (WHAT == 'MPCF')) THEN
            DO J=1,6
               TOTALS(J) = TOTALS(J) + OGEL(I,J)
               IF (ABS(TOTALS(J)) == ZERO) THEN
                  TOTALS_CHAR(J) = '  0.0         '
               ELSE
                  CALL FMT_ES14_6 ( TOTALS(J), TOTALS_CHAR(J) )
               ENDIF
            ENDDO
         ENDIF

         IF (WRITE_OGEL(I) == 'Y') THEN

!           Assemble the per-grid output line directly into LINE_BUF, then emit with a single A-format WRITE.
!           Layout (matches FORMAT 9902): 6X | 1X | I8 | 1X | I8 | 6 * A14  ==> 108 chars total.
            CALL FMT_I8_RJ ( GID_OUT_ARRAY(I,1), LINE_BUF( 8:15) )
            CALL FMT_I8_RJ ( GID_OUT_ARRAY(I,2), LINE_BUF(17:24) )
            DO J=1,6
               IF (ABS(OGEL(I,J)) == ZERO) THEN
                  LINE_BUF(25 + (J-1)*14 : 24 + J*14) = '  0.0         '
               ELSE
                  CALL FMT_ES14_6 ( OGEL(I,J), LINE_BUF(25 + (J-1)*14 : 24 + J*14) )
               ENDIF
            ENDDO
            WRITE(F06,'(A)') LINE_BUF

            IF (GID_OUT_ARRAY(I,MELGP+1) > 0) THEN
               DO J=1,GID_OUT_ARRAY(I,MELGP+1)
                  WRITE(F06,*)
               ENDDO
            ENDIF

            LINES_WRITTEN = LINES_WRITTEN + 1

         ENDIF

      ENDDO

      IF (LINES_WRITTEN > 2) THEN
         WRITE(F06,9601) (MAX_ANS_CHAR(J),J=1,6), (MIN_ANS_CHAR(J),J=1,6), (ABS_ANS_CHAR(J),J=1,6)
      ENDIF

      IF (DEBUG(92) == 0) THEN
         PRINT_TOTALS = ALL_SAME_CID
      ELSE
         PRINT_TOTALS = 'Y'
      ENDIF

      IF (LINES_WRITTEN > 1) THEN
         IF (PRINT_TOTALS == 'Y') THEN
            IF (WHAT == 'OLOAD') THEN
               WRITE(F06,9701) (TOTALS_CHAR(J),J=1,6)
            ELSE IF (WHAT == 'SPCF' ) THEN
               WRITE(F06,9702) (TOTALS_CHAR(J),J=1,6)
            ELSE IF (WHAT == 'MPCF' ) THEN
               WRITE(F06,9703) (TOTALS_CHAR(J),J=1,6)
            ENDIF
         ELSE
            IF (WHAT == 'OLOAD') THEN
               WRITE(F06,9711)
            ELSE IF (WHAT == 'SPCF' ) THEN
               WRITE(F06,9712)
            ELSE IF (WHAT == 'MPCF' ) THEN
               WRITE(F06,9713)
            ENDIF
         ENDIF
      ENDIF



      RETURN

! **********************************************************************************************************************************
 9009 FORMAT(1X,A)

 9011 FORMAT(' OUTPUT FOR SUBCASE ',I8)

 9012 FORMAT(' OUTPUT FOR EIGENVECTOR ',I8)

 9013 FORMAT(' OUTPUT FOR CRAIG-BAMPTON DOF ',I8,' OF ',I8,' (boundary ',A,' for grid',I8,' component',I2,')')

 9015 FORMAT(' OUTPUT FOR CRAIG-BAMPTON DOF ',I8,' OF ',I8,' (modal acceleration for mode ',I8,')')

 9100 FORMAT(' *ERROR  9100: PROGRAMMING ERROR IN SUBROUTINE ',A                                                                   &
                    ,/,14X,' ILLEGAL INPUT FOR VARIABLE "WHAT" = ',A)

 9314 FORMAT(1X,'                                                C B   A C C E L E R A T I O N   O T M',/,                         &
             1X,'                                             (in global coordinate system at each grid)')

 9322 FORMAT(1X,'                                                      D I S P L A C E M E N T S',/,                               &
             1X,'                                             (in global coordinate system at each grid)')

 9323 FORMAT(1X,'                                                        E I G E N V E C T O R',/,                                 &
             1X,'                                             (in global coordinate system at each grid)')

 9324 FORMAT(1X,'                                                C B   D I S P L A C E M E N T   O T M',/,                         &
             1X,'                                             (in global coordinate system at each grid)')

 9331 FORMAT(1X,'                                                    A P P L I E D    F O R C E S',/,                              &
             1X,'                                             (in global coordinate system at each grid)')

 9332 FORMAT(1X,'                                                (including equivalent thermal loads)')

 9341 FORMAT(1X,'                                                         S P C   F O R C E S',/,                                  &
             1X,'                                             (in global coordinate system at each grid)')

 9342 FORMAT(1X,'                                                   C B   S P C   F O R C E   O T M',/,                            &
             1X,'                                             (in global coordinate system at each grid)')

 9351 FORMAT(1X,'                                                         M P C   F O R C E S',/,                                  &
             1X,'                                             (in global coordinate system at each grid)')

 9352 FORMAT(1X,'                                                   C B   M P C   F O R C E   O T M',/,                            &
             1X,'                                             (in global coordinate system at each grid)')

 9501 FORMAT(11X,'GRID     COORD      T1            T2            T3            R1            R2            R3',/,                 &
             11X,'          SYS')

 9601 FORMAT(11X,'              ------------- ------------- ------------- ------------- ------------- -------------',/,            &
             16X,'MAX* :  ',6A14,/,                                                                                                &
             16X,'MIN* :  ',6A14,//,                                                                                               &
             16X,'ABS* :  ',6A14,/,                                                                                                &
             16X,'*for output set')

 9701 FORMAT(11X,'              ------------- ------------- ------------- ------------- ------------- -------------',/,            &
             1X,'APPLIED FORCE TOTALS:  ',6A14,/,3X,'(for output set)')

 9702 FORMAT(11X,'              ------------- ------------- ------------- ------------- ------------- -------------',/,            &
             1X,'    SPC FORCE TOTALS:  ',6A14,/,5X,'(for output set)')

 9703 FORMAT(11X,'              ------------- ------------- ------------- ------------- ------------- -------------',/,            &
             1X,'    MPC FORCE TOTALS:  ',6A14,/,5X,'(for output set)')

 9711 FORMAT(11X,'              ------------- ------------- ------------- ------------- ------------- -------------',/,            &
             1X,'APPLIED FORCE TOTALS: not printed since all grids do not have the same global coordinate system')

 9712 FORMAT(11X,'              ------------- ------------- ------------- ------------- ------------- -------------',/,            &
             1X,'    SPC FORCE TOTALS: not printed since all grids do not have the same global coordinate system')

 9713 FORMAT(11X,'              ------------- ------------- ------------- ------------- ------------- -------------',/,            &
             1X,'    MPC FORCE TOTALS: not printed since all grids do not have the same global coordinate system')

 9902 FORMAT(6X,2(1X,I8),6A)

! **********************************************************************************************************************************

      END SUBROUTINE WRITE_GRD_PRT_OUTPUTS
