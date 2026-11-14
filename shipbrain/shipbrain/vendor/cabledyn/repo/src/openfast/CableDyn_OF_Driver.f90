! File: src/openfast/CableDyn_OF_Driver.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM CableDyn_OF_Driver
   !! Standalone driver for the CableDyn OpenFAST module (CompMooring = 5) -- the
   !! MoorDyn_Driver peer. It exercises the REAL registry module (CD_Init /
   !! CD_UpdateStates / CD_CalcOutput / CD_End over the registry-generated types and the
   !! NWTC point-mesh coupling surface) without the full aero-servo-hydro glue, so the
   !! module gets its own committable, fast regression cases inside the OpenFAST tree.
   !!
   !!    cabledyn_of_driver <driver-input-file>
   !!
   !! Driver input (value-first lines, MoorDyn-driver style; '---'/'#'/'!' lines and
   !! blanks are skipped):
   !!
   !!    --- CableDyn OpenFAST module driver ---
   !!    --- ENVIRONMENT ---
   !!    9.80665     Gravity     (m/s^2)
   !!    1025.0      rhoW        (kg/m^3)
   !!    200.0       WtrDpth     (m)
   !!    --- CABLEDYN ---
   !!    "deck.dat"  CDInputFile (the CableDyn deck)
   !!    "cd_case"   OutRootName
   !!    60.0        TMax        (s)
   !!    0.025       dtC         (s, glue step)
   !!    0           InputsMode  {0: platform held at rest; 1: prescribed motion}
   !!    "motion.dat" InputsFile (MODE 1 ONLY -- a held-rest input ends after
   !!                             InputsMode; rows contain t, surge, sway, heave,
   !!                             theta_x, theta_y, theta_z in SI units and radians;
   !!                             NWTC 1-2-3 Euler sequence;
   !!                             pose linearly interpolated to the glue grid;
   !!                             translational rates by central differences; ANGULAR
   !!                             velocity/acceleration from the rotation matrices,
   !!                             omega^ = Rdot R^T -- angle rates are not omega)
   !!
   !! The prescribed 6-DOF platform pose is rigid-transformed to every coupled point of
   !! the module kinematics mesh about the platform origin (0,0,0): with R the
   !! body-to-global rotation (transpose of the NWTC global-to-body DCM from
   !! EulerConstruct), x_i = r + R p_i, v_i = v + omega x (R p_i),
   !! a_i = a + alpha x (R p_i) + omega x (omega x (R p_i)).
   !!
   !! FAIL-LOUD CONTRACT: any module error, non-finite output channel, or non-finite
   !! coupled load aborts with a nonzero exit code -- the CTest cases key on it.
   USE NWTC_Library
   USE CableDyn_Types
   USE CableDyn, ONLY: CD_Init, CD_UpdateStates, CD_CalcOutput, CD_End
   USE CableDyn_Conventions, ONLY: CD_NATIVE_CHANNEL_FMT
   USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
   IMPLICIT NONE

   TYPE(CD_InitInputType)          :: InitInp
   TYPE(CD_InputType), ALLOCATABLE :: u(:)
   TYPE(CD_ParameterType)          :: p
   TYPE(CD_ContinuousStateType)    :: x
   TYPE(CD_DiscreteStateType)      :: xd
   TYPE(CD_ConstraintStateType)    :: z
   TYPE(CD_OtherStateType)         :: other
   TYPE(CD_OutputType)             :: y
   TYPE(CD_MiscVarType)            :: m
   TYPE(CD_InitOutputType)         :: InitOut

   CHARACTER(1024) :: drv_file, cd_file, out_root, motion_file, drv_dir
   REAL(DbKi) :: gravity, rho_w, wtr_dpth, tmax, dtc, t
   REAL(DbKi) :: t_array(2)
   INTEGER(IntKi) :: inputs_mode, nglue, istep, ic, es, un_out, un_drv, nch, i
   CHARACTER(ErrMsgLen) :: em
   ! prescribed motion table (mode 1): pose/vel/acc on the glue grid
   REAL(DbKi), ALLOCATABLE :: pose(:, :), pvel(:, :), pacc(:, :)

   CALL NWTC_Init( ProgNameIn='CableDyn_OF_Driver', ProgVerIn='(driver)' )

   IF (COMMAND_ARGUMENT_COUNT() < 1) CALL fail_out('usage: cabledyn_of_driver <driver-input-file>')
   CALL GET_COMMAND_ARGUMENT(1, drv_file)

   ! ---- driver input --------------------------------------------------------------
   ! NWTC Open*File routines OPEN a caller-supplied unit; they do not allocate one
   CALL GetNewUnit(un_drv, es, em)
   IF (es /= ErrID_None) CALL fail_out('no free unit: '//TRIM(em))
   CALL OpenFInpFile(un_drv, TRIM(drv_file), es, em)
   IF (es /= ErrID_None) CALL fail_out('cannot open driver input: '//TRIM(em))
   CALL read_value_line(un_drv, gravity)
   CALL read_value_line(un_drv, rho_w)
   CALL read_value_line(un_drv, wtr_dpth)
   CALL read_string_line(un_drv, cd_file)
   CALL read_string_line(un_drv, out_root)
   CALL read_value_line(un_drv, tmax)
   CALL read_value_line(un_drv, dtc)
   CALL read_int_line(un_drv, inputs_mode)
   IF (inputs_mode /= 0 .AND. inputs_mode /= 1) CALL fail_out('InputsMode must be 0 or 1')
   ! the motion-file line exists only for mode 1: a held-rest input legitimately ends
   ! after InputsMode (a trailing line in a mode-0 file is ignored as unread content)
   motion_file = ''
   IF (inputs_mode == 1) CALL read_string_line(un_drv, motion_file)
   CLOSE (un_drv)
   IF (dtc <= 0.0_DbKi .OR. tmax <= 0.0_DbKi) CALL fail_out('TMax and dtC must be positive')
   ! fail closed on a non-integral run length: NINT would silently change the requested
   ! duration (e.g. TMax = 1.06 at dtC = 0.1 would march to 1.1 s)
   nglue = NINT(tmax/dtc)
   IF (ABS(REAL(nglue, DbKi)*dtc - tmax) > 1.0E-6_DbKi*MAX(dtc, tmax)) &
      CALL fail_out('TMax must be a whole number of dtC steps')

   ! resolve deck/motion paths RELATIVE TO THE DRIVER FILE, not the process cwd, so a
   ! case directory is portable however the executable is launched
   CALL GetPath(drv_file, drv_dir)
   IF (PathIsRelative(cd_file)) cd_file = TRIM(drv_dir)//TRIM(cd_file)
   IF (inputs_mode == 1) THEN
      IF (PathIsRelative(motion_file)) motion_file = TRIM(drv_dir)//TRIM(motion_file)
   END IF

   ! ---- module init ----------------------------------------------------------------
   InitInp%g = REAL(gravity, ReKi)
   InitInp%rhoW = REAL(rho_w, ReKi)
   InitInp%WtrDepth = REAL(wtr_dpth, ReKi)
   InitInp%FileName = cd_file
   InitInp%RootName = TRIM(out_root)
   InitInp%Tmax = tmax
   InitInp%Echo = .FALSE.
   InitInp%Linearize = .FALSE.

   ALLOCATE (u(2))
   CALL CD_Init(InitInp, u(1), p, x, xd, z, other, y, m, dtc, InitOut, es, em)
   IF (es >= AbortErrLev) CALL fail_out('CD_Init: '//TRIM(em))
   CALL CD_CopyInput(u(1), u(2), MESH_NEWCOPY, es, em)
   IF (es >= AbortErrLev) CALL fail_out('CD_CopyInput: '//TRIM(em))

   ! ---- prescribed motion table ----------------------------------------------------
   ALLOCATE (pose(6, 0:nglue), pvel(6, 0:nglue), pacc(6, 0:nglue))
   pose = 0.0_DbKi; pvel = 0.0_DbKi; pacc = 0.0_DbKi
   IF (inputs_mode == 1) CALL load_motion(TRIM(motion_file), dtc, nglue, pose, pvel, pacc)

   ! ---- output file ----------------------------------------------------------------
   nch = 0
   IF (ALLOCATED(y%WriteOutput)) nch = SIZE(y%WriteOutput)
   CALL GetNewUnit(un_out, es, em)
   IF (es /= ErrID_None) CALL fail_out('no free unit: '//TRIM(em))
   CALL OpenFOutFile(un_out, TRIM(out_root)//'.out', es, em)
   IF (es /= ErrID_None) CALL fail_out('cannot open output: '//TRIM(em))
   WRITE (un_out, '(A)', ADVANCE='NO') 'Time'
   DO ic = 1, nch
      WRITE (un_out, '(A)', ADVANCE='NO') TAB//TRIM(InitOut%WriteOutputHdr(ic))
   END DO
   WRITE (un_out, '()')
   WRITE (un_out, '(A)', ADVANCE='NO') '(s)'
   DO ic = 1, nch
      WRITE (un_out, '(A)', ADVANCE='NO') TAB//TRIM(InitOut%WriteOutputUnt(ic))
   END DO
   WRITE (un_out, '()')

   ! ---- time marching ----------------------------------------------------------------
   CALL set_mesh_pose(u(1), pose(:, 0), pvel(:, 0), pacc(:, 0))
   DO istep = 0, nglue - 1
      t = REAL(istep, DbKi)*dtc
      ! u(1) at t+dt (newest first, the OpenFAST convention), u(2) at t
      CALL set_mesh_pose(u(2), pose(:, istep), pvel(:, istep), pacc(:, istep))
      CALL set_mesh_pose(u(1), pose(:, istep + 1), pvel(:, istep + 1), pacc(:, istep + 1))
      t_array = [t + dtc, t]
      CALL CD_UpdateStates(t, istep, u, t_array, p, x, xd, z, other, m, es, em)
      IF (es >= AbortErrLev) CALL fail_out('CD_UpdateStates: '//TRIM(em))
      CALL CD_CalcOutput(t + dtc, u(1), p, x, xd, z, other, y, m, es, em)
      IF (es >= AbortErrLev) CALL fail_out('CD_CalcOutput: '//TRIM(em))
      ! fail loud on any non-finite observable
      IF (nch > 0) THEN
         IF (.NOT. ALL(IEEE_IS_FINITE(y%WriteOutput))) CALL fail_out('non-finite output channel')
      END IF
      IF (.NOT. ALL(IEEE_IS_FINITE(y%CoupledLoads(1)%Force))) CALL fail_out('non-finite coupled load')
      IF (.NOT. ALL(IEEE_IS_FINITE(y%CoupledLoads(1)%Moment))) CALL fail_out('non-finite coupled moment')
      WRITE (un_out, '(F12.4)', ADVANCE='NO') t + dtc
      DO ic = 1, nch
         WRITE (un_out, CD_NATIVE_CHANNEL_FMT, ADVANCE='NO') TAB, y%WriteOutput(ic)
      END DO
      WRITE (un_out, '()')
   END DO
   CLOSE (un_out)

   m%HostComplete = .TRUE.
   CALL CD_End(u(1), p, x, xd, z, other, y, m, es, em)
   IF (es >= AbortErrLev) CALL fail_out('CD_End: '//TRIM(em))
   CALL WrScr('CableDyn_OF_Driver: completed '//TRIM(Num2LStr(nglue))//' steps.')

CONTAINS

   SUBROUTINE fail_out(msg)
      CHARACTER(*), INTENT(IN) :: msg
      CALL WrScr('CableDyn_OF_Driver FAILED: '//msg)
      CALL ProgAbort('CableDyn_OF_Driver aborted.')
   END SUBROUTINE fail_out

   SUBROUTINE next_line(un, line)
      !! Next content line: skips blanks and lines starting with ---, #, or !.
      INTEGER(IntKi), INTENT(IN) :: un
      CHARACTER(*), INTENT(OUT) :: line
      INTEGER :: ios
      CHARACTER(1024) :: raw
      DO
         READ (un, '(A)', IOSTAT=ios) raw
         IF (ios /= 0) CALL fail_out('driver input ended early')
         raw = ADJUSTL(raw)
         IF (LEN_TRIM(raw) == 0) CYCLE
         IF (raw(1:1) == '#' .OR. raw(1:1) == '!' .OR. raw(1:3) == '---') CYCLE
         line = raw
         RETURN
      END DO
   END SUBROUTINE next_line

   SUBROUTINE read_value_line(un, val)
      INTEGER(IntKi), INTENT(IN) :: un
      REAL(DbKi), INTENT(OUT) :: val
      CHARACTER(1024) :: line
      INTEGER :: ios
      CALL next_line(un, line)
      READ (line, *, IOSTAT=ios) val
      IF (ios /= 0) CALL fail_out('cannot parse value from: '//TRIM(line))
   END SUBROUTINE read_value_line

   SUBROUTINE read_int_line(un, val)
      INTEGER(IntKi), INTENT(IN) :: un
      INTEGER(IntKi), INTENT(OUT) :: val
      CHARACTER(1024) :: line
      INTEGER :: ios
      CALL next_line(un, line)
      READ (line, *, IOSTAT=ios) val
      IF (ios /= 0) CALL fail_out('cannot parse integer from: '//TRIM(line))
   END SUBROUTINE read_int_line

   SUBROUTINE read_string_line(un, val)
      INTEGER(IntKi), INTENT(IN) :: un
      CHARACTER(*), INTENT(OUT) :: val
      CHARACTER(1024) :: line
      INTEGER :: ios
      CALL next_line(un, line)
      READ (line, *, IOSTAT=ios) val   ! list-directed read handles the quotes
      IF (ios /= 0) CALL fail_out('cannot parse string from: '//TRIM(line))
   END SUBROUTINE read_string_line

   SUBROUTINE load_motion(fname, dt, nsteps, ps, vl, ac)
      !! Read "t x y z theta_x theta_y theta_z" rows (angles = the NWTC 1-2-3 Euler
      !! sequence, radians), linearly interpolate the pose onto the glue grid, then build
      !! the kinematics on that grid: translational velocity/acceleration by per-DOF
      !! central differences, and the TRUE angular velocity/acceleration by
      !! differentiating the rotation matrices themselves (omega^ = Rdot R^T) -- Euler-
      !! angle rates are not the angular-velocity vector under combined finite rotations.
      !! One-sided differences at the ends. Rows must be time-ascending and cover
      !! [0, TMax]. On return vl(4:6,:)/ac(4:6,:) carry the angular velocity/acceleration
      !! VECTORS, not angle rates.
      CHARACTER(*), INTENT(IN) :: fname
      REAL(DbKi), INTENT(IN) :: dt
      INTEGER(IntKi), INTENT(IN) :: nsteps
      REAL(DbKi), INTENT(OUT) :: ps(6, 0:nsteps), vl(6, 0:nsteps), ac(6, 0:nsteps)
      REAL(DbKi), ALLOCATABLE :: traw(:), praw(:, :), rmat(:, :, :)
      REAL(DbKi) :: row(7), tg, w, rdot(3, 3), skew(3, 3)
      INTEGER :: un_m, ios, nrow, ir, k, j
      CALL GetNewUnit(un_m, es, em)
      IF (es /= ErrID_None) CALL fail_out('no free unit: '//TRIM(em))
      CALL OpenFInpFile(un_m, fname, es, em)
      IF (es /= ErrID_None) CALL fail_out('cannot open motion file: '//TRIM(em))
      nrow = 0
      DO
         READ (un_m, *, IOSTAT=ios) row
         IF (ios /= 0) EXIT
         nrow = nrow + 1
      END DO
      IF (nrow < 2) CALL fail_out('motion file needs at least two rows')
      ALLOCATE (traw(nrow), praw(6, nrow))
      REWIND (un_m)
      DO ir = 1, nrow
         READ (un_m, *, IOSTAT=ios) row
         IF (ios /= 0) CALL fail_out('motion file read error')
         traw(ir) = row(1)
         praw(:, ir) = row(2:7)
         IF (ir > 1) THEN
            IF (traw(ir) <= traw(ir - 1)) CALL fail_out('motion times must be ascending')
         END IF
      END DO
      CLOSE (un_m)
      IF (traw(1) > 0.0_DbKi .OR. traw(nrow) < REAL(nsteps, DbKi)*dt) &
         CALL fail_out('motion file must cover [0, TMax]')
      ALLOCATE (rmat(3, 3, 0:nsteps))
      ir = 1
      DO k = 0, nsteps
         tg = REAL(k, DbKi)*dt
         DO WHILE (ir < nrow - 1 .AND. traw(ir + 1) < tg)
            ir = ir + 1
         END DO
         w = (tg - traw(ir))/(traw(ir + 1) - traw(ir))
         w = MIN(MAX(w, 0.0_DbKi), 1.0_DbKi)
         ps(:, k) = (1.0_DbKi - w)*praw(:, ir) + w*praw(:, ir + 1)
      END DO
      ! translational velocity/acceleration: per-DOF finite differences
      DO k = 0, nsteps
         DO j = 1, 3
            IF (k == 0) THEN
               vl(j, k) = (ps(j, 1) - ps(j, 0))/dt
            ELSE IF (k == nsteps) THEN
               vl(j, k) = (ps(j, nsteps) - ps(j, nsteps - 1))/dt
            ELSE
               vl(j, k) = (ps(j, k + 1) - ps(j, k - 1))/(2.0_DbKi*dt)
            END IF
         END DO
      END DO
      ! rotational kinematics: Euler-ANGLE rates are NOT the angular-velocity vector
      ! under combined finite rotations, so differentiate the ROTATION MATRICES
      ! themselves -- omega^ = Rdot R^T with R the body-to-global rotation -- which is
      ! exact to FD order under any angle convention; alpha then by differencing omega
      DO k = 0, nsteps
         rmat(:, :, k) = TRANSPOSE(REAL(EulerConstruct( &
                          [REAL(ps(4, k), R8Ki), REAL(ps(5, k), R8Ki), REAL(ps(6, k), R8Ki)]), DbKi))
      END DO
      DO k = 0, nsteps
         IF (k == 0) THEN
            rdot = (rmat(:, :, 1) - rmat(:, :, 0))/dt
         ELSE IF (k == nsteps) THEN
            rdot = (rmat(:, :, nsteps) - rmat(:, :, nsteps - 1))/dt
         ELSE
            rdot = (rmat(:, :, k + 1) - rmat(:, :, k - 1))/(2.0_DbKi*dt)
         END IF
         skew = MATMUL(rdot, TRANSPOSE(rmat(:, :, k)))
         skew = 0.5_DbKi*(skew - TRANSPOSE(skew))   ! antisymmetrize away FD round-off
         vl(4:6, k) = [skew(3, 2), skew(1, 3), skew(2, 1)]
      END DO
      DO k = 0, nsteps
         IF (k == 0) THEN
            ac(:, k) = (vl(:, 1) - vl(:, 0))/dt
         ELSE IF (k == nsteps) THEN
            ac(:, k) = (vl(:, nsteps) - vl(:, nsteps - 1))/dt
         ELSE
            ac(:, k) = (vl(:, k + 1) - vl(:, k - 1))/(2.0_DbKi*dt)
         END IF
      END DO
   END SUBROUTINE load_motion

   SUBROUTINE set_mesh_pose(uu, r6, v6, a6)
      !! Rigid-transform the platform pose to every coupled point about the origin.
      !! v6(4:6)/a6(4:6) are the angular velocity/acceleration VECTORS (load_motion
      !! provides them by DCM differencing), so omega x (R p) is exact.
      TYPE(CD_InputType), INTENT(INOUT) :: uu
      REAL(DbKi), INTENT(IN) :: r6(6), v6(6), a6(6)
      REAL(R8Ki) :: dcm(3, 3)
      REAL(DbKi) :: rel(3), rot(3), omg(3), alp(3), rr(3), vv(3), aa(3)
      INTEGER :: ip
      dcm = EulerConstruct([REAL(r6(4), R8Ki), REAL(r6(5), R8Ki), REAL(r6(6), R8Ki)])
      omg = v6(4:6)
      alp = a6(4:6)
      DO ip = 1, uu%CoupledKinematics(1)%Nnodes
         rel = REAL(uu%CoupledKinematics(1)%Position(:, ip), DbKi)
         rot = MATMUL(TRANSPOSE(REAL(dcm, DbKi)), rel)
         rr = r6(1:3) + rot - rel
         vv = v6(1:3) + cross3(omg, rot)
         aa = a6(1:3) + cross3(alp, rot) + cross3(omg, cross3(omg, rot))
         uu%CoupledKinematics(1)%TranslationDisp(:, ip) = REAL(rr, ReKi)
         uu%CoupledKinematics(1)%TranslationVel(:, ip) = REAL(vv, ReKi)
         uu%CoupledKinematics(1)%TranslationAcc(:, ip) = REAL(aa, ReKi)
         uu%CoupledKinematics(1)%Orientation(:, :, ip) = dcm
         uu%CoupledKinematics(1)%RotationVel(:, ip) = REAL(omg, ReKi)
         uu%CoupledKinematics(1)%RotationAcc(:, ip) = REAL(alp, ReKi)
      END DO
   END SUBROUTINE set_mesh_pose

   PURE FUNCTION cross3(a, b) RESULT(c)
      REAL(DbKi), INTENT(IN) :: a(3), b(3)
      REAL(DbKi) :: c(3)
      c = [a(2)*b(3) - a(3)*b(2), a(3)*b(1) - a(1)*b(3), a(1)*b(2) - a(2)*b(1)]
   END FUNCTION cross3

END PROGRAM CableDyn_OF_Driver
