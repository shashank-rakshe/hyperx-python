! File: tests/test_lin_torsion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_lin_torsion
  !! OpenFAST linearisation of a cable restrained in torsion, on the aggregate surface the OpenFAST
  !! shell drives: the shell's lin_eval recipe (the mirror loaded with a perturbed state, the
  !! coupled point moved to a perturbed input, the parent's rates given to the torsion end frame
  !! (CD_HFMF_Set_Twist_Frame_Rates), the accelerations solved without a time step, the mirror
  !! restored), the linearisation states of the nodal twist from CD_HFMF_Twist_Lin_Slots, and A, B,
  !! C and D by central differences as CD_JacobianPContState and CD_JacobianPInput form them. The
  !! line is a straight, neutrally buoyant 100 m cable held taut at 0.5 % strain between a coupled
  !! fairlead (0, 0, -20) and a fixed anchor below it, pinned in bending and rigid in torsion at
  !! both ends, GJ = 5e4 N m^2, 50 elements.
  !!   F  torsional modes: with Irn = 2 kg m the twist block of A is decoupled from the line's
  !!      position and tangent states (its coupling entries vanish to the differences' round-off),
  !!      so its eigenvalues are eigenvalues of A: the frequencies of the first three twist modes
  !!      are n pi/L sqrt(GJ/Irn) of the continuum, within the lumped-inertia discretisation
  !!      error, and the lumped chain's own 2 sqrt(GJ/Irn)/h sin(n pi/(2N)) to 1e-6;
  !!   K  roll stiffness: the zero-frequency reduction -(D - C A^-1 B) of the fairlead moment about
  !!      the line axis per unit platform rotation about it is GJ/L (to 1e-6), with the twist
  !!      angles as states; the feedthrough D alone (the interior twist held, as a linearisation
  !!      without twist states would give it) is the end element's GJ/l_e, N times too stiff;
  !!   C  condensed torsion (the same line without Irn, its torque algebraic in q and the end
  !!      frames, no states of its own): the reduction gives GJ/L as well;
  !!   E  an elastic torsional end (spring kt at End B): its end angle is a state too, and the
  !!      reduction gives the series stiffness 1/(L/GJ + 1/kt);
  !!   R  frame rates: with the torsional damping Bt (GJ|0|Bt) the reduced moment per unit angular
  !!      velocity of the platform about the line axis is Bt/L, the steady-roll torque of the
  !!      march (test_nodal_twist_dynamic D), and it vanishes without the frame rates; the moment
  !!      per unit angular acceleration is the held end section's polar inertia Irn l_e/2.
  !!   O  one restrained end: the line of F free in torsion at End B (the anchor), then at End A
  !!      (the fairlead); the free end's angle is a state too (N of them), and the twist modes of
  !!      A are the clamped-free ones, the continuum's quarter-wave (2n - 1) pi/(2L) sqrt(GJ/Irn)
  !!      within the lumped-inertia error and the lumped chain's 2 sqrt(GJ/Irn)/h
  !!      sin((2n - 1) pi/(4N)) to 1e-6; a free end carries no torque, so the reduced roll
  !!      stiffness vanishes (to 1e-6 of GJ/L): with End B free the platform turns the line as a
  !!      whole (the feedthrough D, GJ/l_e, is cancelled by C A^-1 B), with End A free the platform
  !!      roll does not reach the line at all.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_OpenFAST_Aggregate, ONLY: CD_AGG_ModuleType, CD_AGG_Init_From_Deck, CD_AGG_NMovingPoints, &
                                         CD_AGG_GetMovingPointMesh, CD_AGG_UpdateStates_Moving, &
                                         CD_AGG_CalcOutput, CD_AGG_End, CD_AGG_OK
  USE CableDyn_OpenFAST_HermiteFMF, ONLY: CD_HFMF_MirrorSize, CD_HFMF_PackMirror, CD_HFMF_UnpackMirror, &
                                          CD_HFMF_Refresh_Acceleration, CD_HFMF_Set_Torsion, &
                                          CD_HFMF_Twist_Lin_Count, CD_HFMF_Twist_Lin_Slots, &
                                          CD_HFMF_Set_Twist_Frame_Rates, CD_HFMF_OK
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.14159265358979323846_wp, RHOW = 1025.0_wp, DT = 0.05_wp
  REAL(wp), PARAMETER :: GJ = 5.0e4_wp, L = 100.0_wp, IRN = 2.0_wp, BT = 1.0e3_wp
  INTEGER, PARAMETER :: NE = 50
  ! the linearisation steps of the OpenFAST shell (CD_InitVars): positions, tangents and twist
  ! angles 1e-6, velocities 0.1 m/s (tangent rates 0.1 m/s over the element length), twist rates
  ! 0.01 rad/s, rotations 1e-4 rad, angular velocities and accelerations 0.1
  REAL(wp), PARAMETER :: HX = 1.0e-6_wp, HV = 0.1_wp, HW = 1.0e-2_wp, HROT = 1.0e-4_wp, HOM = 0.1_wp
  INTEGER :: nfail = 0

  ! the shell's state of one cable: [r, m free; phi free; their rates], mirror slots and buffers
  TYPE(CD_AGG_ModuleType) :: agg
  INTEGER :: nf, ntw, nx2, msz
  INTEGER, ALLOCATABLE :: q_slot(:), v_slot(:), a_slot(:), tp(:), tr(:), ta(:), tn(:)
  REAL(wp), ALLOCATABLE :: buf0(:), wbuf(:)
  REAL(wp) :: pos0(3, 1), vel0(3, 1), acc0(3, 1), t0

  CALL check_modes_and_stiffness()
  CALL check_condensed()
  CALL check_elastic_end()
  CALL check_frame_rates()
  CALL check_free_end(2)
  CALL check_free_end(1)

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: linearisation of a line restrained in torsion (modes, roll stiffness, condensed, '// &
    'elastic end, frame rates, one restrained end)'

CONTAINS

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: '//TRIM(label)
  END SUBROUTINE require

  SUBROUTINE write_deck(path, irn_v, bt_v, tors_b, tors_a)
    !! The straight vertical line, neutrally buoyant (mass rhoW pi d^2/4) and without drag or
    !! added mass, so the 0.5 % strain is uniform; Irn irn_v, torsional damping bt_v, and the
    !! torsional restraints of End B tors_b and End A tors_a (default Rigid).
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: irn_v, bt_v
    CHARACTER(*), INTENT(IN), OPTIONAL :: tors_b, tors_a
    INTEGER :: u
    CHARACTER(240) :: ltype
    CHARACTER(40) :: gj_col
    gj_col = '5.0e4'
    IF (bt_v > 0.0_wp) WRITE (gj_col, '(A,ES10.4)') '5.0e4|0|', bt_v
    WRITE (ltype, '(A,ES24.16,A,A,A,ES12.5,A)') 'cab 0.2 ', RHOW*0.25_wp*PI*0.04_wp, &
      ' 1.0e7 0.0 1.0e6 1.0e8 ', TRIM(gj_col), ' 1.0 ', irn_v, ' 0.0 0.0 0.0 0.0'
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'linearisation of a line restrained in torsion'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)'
    WRITE (u, '(A)') TRIM(ltype)
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z Mass Vol CdA Ca'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)'
    WRITE (u, '(A)') '1 Coupled 0.0 0.0 -20.0 0 0 0 0'
    WRITE (u, '(A)') '2 Fixed 0.0 0.0 -120.5 0 0 0 0'
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 1 2 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    WRITE (u, '(A,I0)') '1 cab 100.0 ', NE
    WRITE (u, '(A)') '--- END CONNECTIONS ---'
    WRITE (u, '(A)') 'LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist'
    WRITE (u, '(A)') '(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)'
    IF (PRESENT(tors_a)) THEN
      WRITE (u, '(A)') '1 A Pinned 0 0 -1 '//tors_a//' 1 0 0 0'
    ELSE
      WRITE (u, '(A)') '1 A Pinned 0 0 -1 Rigid 1 0 0 0'
    END IF
    IF (PRESENT(tors_b)) THEN
      WRITE (u, '(A)') '1 B Pinned 0 0 -1 '//tors_b//' 1 0 0 0'
    ELSE
      WRITE (u, '(A)') '1 B Pinned 0 0 -1 Rigid 1 0 0 0'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'Torq1N1'
    WRITE (u, '(A)') '--- END ---'
    CLOSE (u)
  END SUBROUTINE write_deck

  SUBROUTINE setup(path, ok)
    !! Build the aggregate (host orientation, as the shell) and the shell's state map of its cable.
    CHARACTER(*), INTENT(IN) :: path
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: es, i, k
    CHARACTER(512) :: em
    REAL(wp) :: ld(3, 1)
    CALL CD_AGG_Init_From_Deck(agg, path, DT, es, em, host_orientation=.TRUE.)
    ok = es == CD_AGG_OK
    CALL require(ok, 'the torsion line builds on the aggregate: '//TRIM(em))
    IF (.NOT. ok) RETURN
    k = CD_AGG_NMovingPoints(agg, es, em)
    ok = agg%ncable == 1 .AND. k == 1
    CALL require(ok, 'the deck is one coupled cable')
    IF (.NOT. ok) RETURN
    CALL map_states()
    CALL CD_AGG_GetMovingPointMesh(agg, pos0, vel0, acc0, ld, es, em)
    t0 = agg%cables(1)%line%t
    ! the cable's r, m slots in its mirror [v_free; q_free; a_free]
    IF (ALLOCATED(q_slot)) DEALLOCATE (q_slot, v_slot, a_slot)
    ALLOCATE (q_slot(nf), v_slot(nf), a_slot(nf))
    k = 0
    DO i = 1, nf
      k = k + 1
      v_slot(k) = i
      q_slot(k) = nf + i
      a_slot(k) = 2*nf + i
    END DO
  END SUBROUTINE setup

  SUBROUTINE map_states()
    !! The state counts and the twist slots of the cable (re-read after a torsion change).
    INTEGER :: es
    CHARACTER(512) :: em
    nf = COUNT(agg%cables(1)%line%freemask)
    ntw = CD_HFMF_Twist_Lin_Count(agg%cables(1))
    nx2 = nf + ntw
    msz = CD_HFMF_MirrorSize(agg%cables(1))
    IF (ALLOCATED(tp)) DEALLOCATE (tp, tr, ta, tn)
    ALLOCATE (tp(ntw), tr(ntw), ta(ntw), tn(ntw))
    CALL CD_HFMF_Twist_Lin_Slots(agg%cables(1), tp, tr, ta, tn, es, em)
    CALL require(es == CD_HFMF_OK, 'the twist slots: '//TRIM(em))
    IF (ALLOCATED(buf0)) DEALLOCATE (buf0, wbuf)
    ALLOCATE (buf0(msz), wbuf(msz))
    CALL CD_HFMF_PackMirror(agg%cables(1), buf0, es, em)
    CALL require(es == CD_HFMF_OK, 'the committed mirror packs: '//TRIM(em))
  END SUBROUTINE map_states

  FUNCTION rot_dcm(axis, ang) RESULT(r)
    !! OpenFAST mesh orientation (global to local) of a turn ang about the global axis.
    INTEGER, INTENT(IN) :: axis
    REAL(wp), INTENT(IN) :: ang
    REAL(wp) :: r(3, 3), c, s
    INTEGER :: i, j
    c = COS(ang)
    s = SIN(ang)
    r = 0.0_wp
    r(axis, axis) = 1.0_wp
    i = MOD(axis, 3) + 1
    j = MOD(axis + 1, 3) + 1
    r(i, i) = c
    r(j, j) = c
    r(i, j) = s
    r(j, i) = -s
  END FUNCTION rot_dcm

  SUBROUTINE state_of(x)
    !! The linearisation state of the committed mirror: [q_free; phi_free; v_free; w_free].
    REAL(wp), INTENT(OUT) :: x(:)
    x(1:nf) = buf0(q_slot)
    x(nf + 1:nx2) = buf0(tp)
    x(nx2 + 1:nx2 + nf) = buf0(v_slot)
    x(nx2 + nf + 1:2*nx2) = buf0(tr)
  END SUBROUTINE state_of

  SUBROUTINE lin_eval(x, axis, ang, om, al, xdot, mom, rates)
    !! The shell's lin_eval on the cable: state x, the coupled point turned by ang about the global
    !! axis (0: not turned) with angular velocity om and acceleration al; xdot = dx/dt and the
    !! fairlead moment mom. rates = .FALSE. leaves out CD_HFMF_Set_Twist_Frame_Rates.
    REAL(wp), INTENT(IN) :: x(:), ang, om(3), al(3)
    INTEGER, INTENT(IN) :: axis
    REAL(wp), INTENT(OUT) :: xdot(:), mom(3)
    LOGICAL, INTENT(IN), OPTIONAL :: rates
    REAL(wp) :: orient(3, 3, 1), omg(3, 1), alp(3, 1), p(3, 1), v(3, 1), a(3, 1), ld(3, 1), mm(3, 1)
    INTEGER :: es
    LOGICAL :: with_rates
    CHARACTER(512) :: em
    with_rates = .TRUE.
    IF (PRESENT(rates)) with_rates = rates
    wbuf = buf0
    wbuf(q_slot) = x(1:nf)
    wbuf(tp) = x(nf + 1:nx2)
    wbuf(v_slot) = x(nx2 + 1:nx2 + nf)
    wbuf(tr) = x(nx2 + nf + 1:2*nx2)
    CALL CD_HFMF_UnpackMirror(agg%cables(1), wbuf, t0, es, em)
    CALL require(es == CD_HFMF_OK, 'lin_eval: the state loads: '//TRIM(em))
    orient(:, :, 1) = rot_dcm(MAX(axis, 1), MERGE(ang, 0.0_wp, axis > 0))
    omg(:, 1) = om
    alp(:, 1) = al
    CALL CD_AGG_UpdateStates_Moving(agg, pos0, vel0, acc0, es, em, output_probe=.FALSE., orientation=orient, &
                                    angular_velocity=omg, angular_acceleration=alp)
    CALL require(es == CD_AGG_OK, 'lin_eval: the input loads: '//TRIM(em))
    IF (with_rates) CALL CD_HFMF_Set_Twist_Frame_Rates(agg%cables(1), es, em)
    CALL CD_HFMF_Refresh_Acceleration(agg%cables(1), es, em)
    CALL require(es == CD_HFMF_OK, 'lin_eval: the accelerations: '//TRIM(em))
    CALL CD_HFMF_PackMirror(agg%cables(1), wbuf, es, em)
    xdot(1:nf) = wbuf(v_slot)
    xdot(nf + 1:nx2) = wbuf(tr)
    xdot(nx2 + 1:nx2 + nf) = wbuf(a_slot)
    xdot(nx2 + nf + 1:2*nx2) = wbuf(ta)
    CALL CD_AGG_CalcOutput(agg, es, em)
    CALL CD_AGG_GetMovingPointMesh(agg, p, v, a, ld, es, em, moment=mm)
    CALL require(es == CD_AGG_OK, 'lin_eval: the outputs: '//TRIM(em))
    mom = mm(:, 1)
    ! the committed state back
    orient(:, :, 1) = rot_dcm(1, 0.0_wp)
    omg = 0.0_wp
    alp = 0.0_wp
    CALL CD_AGG_UpdateStates_Moving(agg, pos0, vel0, acc0, es, em, output_probe=.TRUE., orientation=orient, &
                                    angular_velocity=omg, angular_acceleration=alp)
    CALL CD_HFMF_UnpackMirror(agg%cables(1), buf0, t0, es, em)
    CALL require(es == CD_HFMF_OK, 'lin_eval: the committed state restores: '//TRIM(em))
  END SUBROUTINE lin_eval

  SUBROUTINE state_matrix(amat, cmom)
    !! A = d xdot/dx and C = d M/dx (the fairlead moment) by central differences over the states.
    REAL(wp), INTENT(OUT) :: amat(:, :), cmom(:, :)
    REAL(wp) :: x0(2*nx2), x(2*nx2), fp(2*nx2), fm(2*nx2), mp(3), mn(3), h, z3(3)
    INTEGER :: j
    z3 = 0.0_wp
    CALL state_of(x0)
    DO j = 1, 2*nx2
      h = state_step(j)
      x = x0
      x(j) = x0(j) + h
      CALL lin_eval(x, 0, 0.0_wp, z3, z3, fp, mp)
      x(j) = x0(j) - h
      CALL lin_eval(x, 0, 0.0_wp, z3, z3, fm, mn)
      amat(:, j) = (fp - fm)/(2.0_wp*h)
      cmom(:, j) = (mp - mn)/(2.0_wp*h)
    END DO
  END SUBROUTINE state_matrix

  REAL(wp) FUNCTION state_step(j) RESULT(h)
    !! The shell's step of state j: positions, tangents and angles HX; velocities HV, tangent
    !! rates HV over the mean element length, twist rates HW.
    INTEGER, INTENT(IN) :: j
    INTEGER :: dof
    IF (j <= nx2) THEN
      h = HX
    ELSE IF (j <= nx2 + nf) THEN
      dof = 0
      h = HV
      ! a tangent DOF (4-6 of its node) takes the tangent-rate step
      dof = free_dof(j - nx2)
      IF (MOD(dof - 1, 6) >= 3) h = HV*REAL(NE, wp)/SUM(agg%cables(1)%line%l0)
    ELSE
      h = HW
    END IF
  END FUNCTION state_step

  INTEGER FUNCTION free_dof(k) RESULT(dof)
    !! The cable DOF of the k-th free DOF.
    INTEGER, INTENT(IN) :: k
    INTEGER :: i, c
    c = 0
    dof = 0
    DO i = 1, SIZE(agg%cables(1)%line%freemask)
      IF (.NOT. agg%cables(1)%line%freemask(i)) CYCLE
      c = c + 1
      IF (c == k) THEN
        dof = i
        RETURN
      END IF
    END DO
  END FUNCTION free_dof

  SUBROUTINE input_columns(axis, kind, b, dmom, rates)
    !! B = d xdot/du and D = d M/du for one input of the coupled point: kind 1 the rotation about
    !! the global axis, 2 its angular velocity, 3 its angular acceleration.
    INTEGER, INTENT(IN) :: axis, kind
    REAL(wp), INTENT(OUT) :: b(:), dmom(3)
    LOGICAL, INTENT(IN), OPTIONAL :: rates
    REAL(wp) :: x0(2*nx2), fp(2*nx2), fm(2*nx2), mp(3), mn(3), w(3), z3(3), h
    z3 = 0.0_wp
    CALL state_of(x0)
    SELECT CASE (kind)
    CASE (1)
      h = HROT
      CALL lin_eval(x0, axis, h, z3, z3, fp, mp, rates)
      CALL lin_eval(x0, axis, -h, z3, z3, fm, mn, rates)
    CASE (2)
      h = HOM
      w = 0.0_wp
      w(axis) = h
      CALL lin_eval(x0, 0, 0.0_wp, w, z3, fp, mp, rates)
      CALL lin_eval(x0, 0, 0.0_wp, -w, z3, fm, mn, rates)
    CASE DEFAULT
      h = HOM
      w = 0.0_wp
      w(axis) = h
      CALL lin_eval(x0, 0, 0.0_wp, z3, w, fp, mp, rates)
      CALL lin_eval(x0, 0, 0.0_wp, z3, -w, fm, mn, rates)
    END SELECT
    b = (fp - fm)/(2.0_wp*h)
    dmom = (mp - mn)/(2.0_wp*h)
  END SUBROUTINE input_columns

  REAL(wp) FUNCTION reduced(amat, cmom, b, dmom, row) RESULT(k)
    !! -(D - C A^-1 B) of the moment component row for one input column: A = [0 I; Kx Cx] and the
    !! top rows of B vanish, so A^-1 B = [Kx^-1 b_acc; 0] and C A^-1 B = C_x Kx^-1 b_acc.
    REAL(wp), INTENT(IN) :: amat(:, :), cmom(:, :), b(:), dmom(3)
    INTEGER, INTENT(IN) :: row
    REAL(wp), ALLOCATABLE :: kx(:, :), z(:, :)
    INTEGER, ALLOCATABLE :: ipiv(:)
    INTEGER :: info
    EXTERNAL :: DGESV
    ALLOCATE (kx(nx2, nx2), z(nx2, 1), ipiv(nx2))
    kx = amat(nx2 + 1:2*nx2, 1:nx2)
    z(:, 1) = b(nx2 + 1:2*nx2)
    CALL DGESV(nx2, 1, kx, nx2, ipiv, z, nx2, info)
    CALL require(info == 0, 'the position block of A is regular')
    k = -(dmom(row) - DOT_PRODUCT(cmom(row, 1:nx2), z(:, 1)))
  END FUNCTION reduced

  SUBROUTINE twist_eigen(amat, omega, coupling)
    !! The twist block of A, d a_phi/d phi = -M^-1 K with the lumped polar inertia M: omega^2 are
    !! the eigenvalues of M^(1/2) (-A_pp) M^(-1/2) (symmetric; cyclic Jacobi), ascending. coupling
    !! is the largest entry coupling the twist states to the r, m states, relative to the block.
    REAL(wp), INTENT(IN) :: amat(:, :)
    REAL(wp), INTENT(OUT) :: omega(:), coupling
    REAL(wp) :: s(ntw, ntw), mass(ntw), big
    INTEGER :: i, j
    DO i = 1, ntw
      mass(i) = agg%cables(1)%line%tw_mass(tn(i))
    END DO
    DO j = 1, ntw
      DO i = 1, ntw
        s(i, j) = -amat(nx2 + nf + i, nf + j)*SQRT(mass(i)/mass(j))
      END DO
    END DO
    big = MAXVAL(ABS(s))
    s = 0.5_wp*(s + TRANSPOSE(s))
    CALL jacobi(s, omega)
    omega = SQRT(MAX(omega, 0.0_wp))
    ! the twist rows against the r, m columns (positions and rates) and the r, m rows against the
    ! twist columns, each scaled by its row block
    ASSOCIATE (tw_rows => amat(nx2 + nf + 1:2*nx2, :), line_rows => amat(nx2 + 1:nx2 + nf, :))
      coupling = MAX(MAXVAL(ABS(tw_rows(:, 1:nf))), MAXVAL(ABS(tw_rows(:, nx2 + 1:nx2 + nf))))/ &
                 MAXVAL(ABS(tw_rows(:, nf + 1:nx2)))
      coupling = MAX(coupling, MAX(MAXVAL(ABS(line_rows(:, nf + 1:nx2))), &
                                   MAXVAL(ABS(line_rows(:, nx2 + nf + 1:2*nx2))))/MAXVAL(ABS(line_rows(:, 1:nf))))
    END ASSOCIATE
  END SUBROUTINE twist_eigen

  SUBROUTINE jacobi(s, ev)
    !! Eigenvalues of the symmetric matrix s by cyclic Jacobi rotations, ascending.
    REAL(wp), INTENT(INOUT) :: s(:, :)
    REAL(wp), INTENT(OUT) :: ev(:)
    INTEGER :: n, p, q, k, sweep
    REAL(wp) :: theta, t, c, sn, tau, off, apq, app, aqq, tmp
    n = SIZE(s, 1)
    DO sweep = 1, 100
      off = 0.0_wp
      DO q = 2, n
        DO p = 1, q - 1
          off = off + s(p, q)**2
        END DO
      END DO
      IF (off <= 1.0e-30_wp*SUM([(s(k, k)**2, k=1, n)])) EXIT
      DO q = 2, n
        DO p = 1, q - 1
          apq = s(p, q)
          IF (ABS(apq) <= TINY(1.0_wp)) CYCLE
          app = s(p, p)
          aqq = s(q, q)
          theta = (aqq - app)/(2.0_wp*apq)
          t = SIGN(1.0_wp, theta)/(ABS(theta) + SQRT(theta**2 + 1.0_wp))
          c = 1.0_wp/SQRT(t**2 + 1.0_wp)
          sn = t*c
          tau = sn/(1.0_wp + c)
          DO k = 1, n
            IF (k == p .OR. k == q) CYCLE
            tmp = s(k, p)
            s(k, p) = tmp - sn*(s(k, q) + tau*tmp)
            s(k, q) = s(k, q) + sn*(tmp - tau*s(k, q))
            s(p, k) = s(k, p)
            s(q, k) = s(k, q)
          END DO
          s(p, p) = app - t*apq
          s(q, q) = aqq + t*apq
          s(p, q) = 0.0_wp
          s(q, p) = 0.0_wp
        END DO
      END DO
    END DO
    DO k = 1, n
      ev(k) = s(k, k)
    END DO
    DO p = 1, n - 1
      DO q = p + 1, n
        IF (ev(q) < ev(p)) THEN
          tmp = ev(p)
          ev(p) = ev(q)
          ev(q) = tmp
        END IF
      END DO
    END DO
  END SUBROUTINE jacobi

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_modes_and_stiffness()
    REAL(wp), ALLOCATABLE :: amat(:, :), cmom(:, :), b(:), omega(:)
    REAL(wp) :: dmom(3), coupling, w_cont, w_disc, e_cont, e_disc, k_red, k_ft, k_ref, h, kxx
    INTEGER :: n, es, j
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_deck('lin_torsion_modes.dat', IRN, 0.0_wp)
    CALL setup('lin_torsion_modes.dat', ok)
    IF (.NOT. ok) RETURN
    ! rigid in torsion at both ends: the two end angles are held, the 49 interior ones are states
    CALL require(ntw == NE - 1, 'F: the free twist angles are the interior nodes''')
    ok = .TRUE.
    DO j = 2, ntw
      ok = ok .AND. tp(j) == tp(1) + j - 1 .AND. tr(j) == tr(1) + j - 1 .AND. ta(j) == ta(1) + j - 1
    END DO
    CALL require(ok, 'F: the twist slots are consecutive')
    CALL require(.NOT. (ANY(ABS(agg%cables(1)%line%tw_phi(tn) - buf0(tp)) > 0.0_wp) .OR. &
                        ANY(ABS(agg%cables(1)%line%tw_w(tn) - buf0(tr)) > 0.0_wp)), &
                 'F: the slots hold the committed angles and rates')
    ALLOCATE (amat(2*nx2, 2*nx2), cmom(3, 2*nx2), b(2*nx2), omega(ntw))
    CALL state_matrix(amat, cmom)
    CALL twist_eigen(amat, omega, coupling)
    h = L/REAL(NE, wp)
    WRITE (*, '(A,I0,A,I0,A,ES10.3)') 'F: ', 2*nx2, ' states (', 2*ntw, ' twist); twist-line coupling / block ', &
      coupling
    CALL require(coupling <= 1.0e-8_wp, 'F: the twist block is decoupled from the line states')
    DO n = 1, 3
      w_cont = REAL(n, wp)*PI/L*SQRT(GJ/IRN)
      w_disc = 2.0_wp/h*SQRT(GJ/IRN)*SIN(REAL(n, wp)*PI/(2.0_wp*REAL(NE, wp)))
      e_cont = omega(n)/w_cont - 1.0_wp
      e_disc = omega(n)/w_disc - 1.0_wp
      WRITE (*, '(A,I0,A,F12.8,A,F12.8,A,ES10.3,A,F12.8,A,ES10.3)') 'F: mode ', n, ' omega ', omega(n), &
        ' rad/s; continuum ', w_cont, ' (', e_cont, '); lumped chain ', w_disc, ' (', e_disc, ')'
      CALL require(ABS(e_disc) <= 1.0e-6_wp, 'F: the twist mode matches the lumped chain')
      ! the lumped-inertia chain lies (n pi/N)^2/24 below the continuum
      CALL require(ABS(e_cont) <= 1.2_wp*(REAL(n, wp)*PI/REAL(NE, wp))**2/24.0_wp + 1.0e-6_wp, &
                   'F: the twist mode matches n pi/L sqrt(GJ/Irn) within the discretisation error')
    END DO
    ! K: the roll stiffness about the line axis (global z)
    CALL input_columns(3, 1, b, dmom)
    k_red = reduced(amat, cmom, b, dmom, 3)
    k_ft = -dmom(3)
    k_ref = GJ/L
    WRITE (*, '(A,ES16.9,A,ES16.9,A,ES10.3,A,ES16.9,A,ES16.9)') 'K: -(D - C A^-1 B) ', k_red, ' N m/rad; GJ/L ', &
      k_ref, ' (', k_red/k_ref - 1.0_wp, '); feedthrough D alone ', k_ft, '; GJ/l_e ', GJ/h
    CALL require(ABS(k_red/k_ref - 1.0_wp) <= 1.0e-6_wp, 'K: the reduced roll stiffness is GJ/L')
    CALL require(ABS(k_ft/(GJ/h) - 1.0_wp) <= 1.0e-6_wp, 'K: the feedthrough alone is the end element''s GJ/l_e')
    ! a turn about an axis across the line does not load the straight pinned line
    CALL input_columns(1, 1, b, dmom)
    kxx = reduced(amat, cmom, b, dmom, 1)
    WRITE (*, '(A,ES10.3,A)') 'K: about x: ', kxx, ' N m/rad'
    CALL require(ABS(kxx) <= 1.0e-6_wp*k_ref, 'K: no roll stiffness across the straight pinned line')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_modes_and_stiffness

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_condensed()
    !! The line of F and K with its torsion installed again without the polar inertia: the
    !! condensed torsion, whose uniform torque has no state of its own.
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp), ALLOCATABLE :: amat(:, :), cmom(:, :), b(:)
    REAL(wp) :: dmom(3), k_red, k_ref, frame(3, 2), dcm(3, 3)
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_deck('lin_torsion_condensed.dat', IRN, 0.0_wp)
    CALL setup('lin_torsion_condensed.dat', ok)
    IF (.NOT. ok) RETURN
    tors = agg%cables(1)%line%torsion
    IF (ALLOCATED(tors%irn)) DEALLOCATE (tors%irn)
    frame = agg%cables(1)%tors_frame_parent
    dcm = agg%cables(1)%parent_dcm
    CALL CD_HFMF_Set_Torsion(agg%cables(1), tors, es, em, coupled_frame_parent=frame, parent_orientation=dcm)
    CALL require(es == CD_HFMF_OK, 'C: the condensed torsion installs: '//TRIM(em))
    IF (es /= CD_HFMF_OK) RETURN
    CALL map_states()
    CALL require(ntw == 0 .AND. .NOT. agg%cables(1)%line%tw_active, 'C: the condensed torsion has no twist states')
    ALLOCATE (amat(2*nx2, 2*nx2), cmom(3, 2*nx2), b(2*nx2))
    CALL state_matrix(amat, cmom)
    CALL input_columns(3, 1, b, dmom)
    k_red = reduced(amat, cmom, b, dmom, 3)
    k_ref = GJ/L
    WRITE (*, '(A,ES16.9,A,ES16.9,A,ES10.3,A,ES16.9)') 'C: -(D - C A^-1 B) ', k_red, ' N m/rad; GJ/L ', k_ref, &
      ' (', k_red/k_ref - 1.0_wp, '); D alone ', -dmom(3)
    CALL require(ABS(k_red/k_ref - 1.0_wp) <= 1.0e-6_wp, 'C: the condensed roll stiffness is GJ/L')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_condensed

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_elastic_end()
    !! The line of K with an elastic torsional spring kt at End B: its end angle is a state too,
    !! and the reduced roll stiffness is that of the series compliance, 1/(L/GJ + 1/kt).
    REAL(wp), PARAMETER :: KT = 2.0e3_wp
    REAL(wp), ALLOCATABLE :: amat(:, :), cmom(:, :), b(:)
    REAL(wp) :: dmom(3), k_red, k_ref
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_deck('lin_torsion_elastic.dat', IRN, 0.0_wp, tors_b='2.0e3')
    CALL setup('lin_torsion_elastic.dat', ok)
    IF (.NOT. ok) RETURN
    CALL require(ntw == NE, 'E: the elastic end''s angle is a state')
    ALLOCATE (amat(2*nx2, 2*nx2), cmom(3, 2*nx2), b(2*nx2))
    CALL state_matrix(amat, cmom)
    CALL input_columns(3, 1, b, dmom)
    k_red = reduced(amat, cmom, b, dmom, 3)
    k_ref = 1.0_wp/(L/GJ + 1.0_wp/KT)
    WRITE (*, '(A,ES16.9,A,ES16.9,A,ES10.3,A)') 'E: -(D - C A^-1 B) ', k_red, ' N m/rad; 1/(L/GJ + 1/kt) ', &
      k_ref, ' (', k_red/k_ref - 1.0_wp, ')'
    CALL require(ABS(k_red/k_ref - 1.0_wp) <= 1.0e-6_wp, 'E: the roll stiffness of the elastic end in series')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_elastic_end

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_frame_rates()
    REAL(wp), ALLOCATABLE :: amat(:, :), cmom(:, :), b(:)
    REAL(wp) :: dmom(3), k_om, k_om0, k_al, i_held, h
    INTEGER :: es
    LOGICAL :: ok
    CHARACTER(512) :: em
    CALL write_deck('lin_torsion_rates.dat', IRN, BT)
    CALL setup('lin_torsion_rates.dat', ok)
    IF (.NOT. ok) RETURN
    ALLOCATE (amat(2*nx2, 2*nx2), cmom(3, 2*nx2), b(2*nx2))
    CALL state_matrix(amat, cmom)
    CALL input_columns(3, 2, b, dmom)
    k_om = reduced(amat, cmom, b, dmom, 3)
    CALL input_columns(3, 2, b, dmom, rates=.FALSE.)
    k_om0 = reduced(amat, cmom, b, dmom, 3)
    WRITE (*, '(A,ES16.9,A,ES16.9,A,ES10.3,A,ES10.3)') 'R: moment per unit angular velocity ', k_om, &
      ' N m s/rad; Bt/L ', BT/L, ' (', k_om/(BT/L) - 1.0_wp, '); without the frame rates ', k_om0
    CALL require(ABS(k_om/(BT/L) - 1.0_wp) <= 1.0e-6_wp, 'R: the steady-roll damping torque Bt/L')
    CALL require(ABS(k_om0) <= 1.0e-9_wp*BT/L, 'R: without the frame rates the damping column vanishes')
    CALL input_columns(3, 3, b, dmom)
    k_al = -dmom(3)
    h = L/REAL(NE, wp)
    i_held = 0.5_wp*IRN*h
    WRITE (*, '(A,ES16.9,A,ES16.9,A,ES10.3)') 'R: moment per unit angular acceleration ', k_al, &
      ' kg m^2; Irn l_e/2 ', i_held, ' (', k_al/i_held - 1.0_wp, ')'
    CALL require(ABS(k_al/i_held - 1.0_wp) <= 1.0e-6_wp, 'R: the held end section''s polar inertia')
    CALL require(.NOT. MAXVAL(ABS(b)) > 0.0_wp, 'R: the angular acceleration does not drive the line states')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_frame_rates
  ! ------------------------------------------------------------------------------------------
  SUBROUTINE check_free_end(kfree)
    !! O: the line of F free in torsion at deck End kfree (1 = A, 2 = B).
    INTEGER, INTENT(IN) :: kfree
    REAL(wp), ALLOCATABLE :: amat(:, :), cmom(:, :), b(:), omega(:)
    REAL(wp) :: dmom(3), coupling, w_cont, w_disc, e_cont, e_disc, k_red, h, x
    INTEGER :: n, es
    LOGICAL :: ok
    CHARACTER(512) :: em
    CHARACTER(5) :: tag
    tag = MERGE('End A', 'End B', kfree == 1)
    IF (kfree == 1) THEN
      CALL write_deck('lin_torsion_free.dat', IRN, 0.0_wp, tors_a='Free')
    ELSE
      CALL write_deck('lin_torsion_free.dat', IRN, 0.0_wp, tors_b='Free')
    END IF
    CALL setup('lin_torsion_free.dat', ok)
    IF (.NOT. ok) RETURN
    CALL require(agg%cables(1)%line%torsion%end_free(3 - kfree), 'O ('//tag//' free): the line is solved free there')
    ! the held end's angle is not a state, the free end's is
    CALL require(ntw == NE, 'O ('//tag//' free): the free end''s angle is a state')
    IF (ntw /= NE) THEN
      CALL CD_AGG_End(agg, es, em)
      RETURN
    END IF
    ALLOCATE (amat(2*nx2, 2*nx2), cmom(3, 2*nx2), b(2*nx2), omega(ntw))
    CALL state_matrix(amat, cmom)
    CALL twist_eigen(amat, omega, coupling)
    h = L/REAL(NE, wp)
    WRITE (*, '(A,A,A,I0,A,I0,A,ES10.3)') 'O: ', tag, ' free: ', 2*nx2, ' states (', 2*ntw, &
      ' twist); twist-line coupling / block ', coupling
    CALL require(coupling <= 1.0e-8_wp, 'O: the twist block is decoupled from the line states')
    DO n = 1, 3
      x = REAL(2*n - 1, wp)*PI/(4.0_wp*REAL(NE, wp))
      w_cont = REAL(2*n - 1, wp)*PI/(2.0_wp*L)*SQRT(GJ/IRN)
      w_disc = 2.0_wp/h*SQRT(GJ/IRN)*SIN(x)
      e_cont = omega(n)/w_cont - 1.0_wp
      e_disc = omega(n)/w_disc - 1.0_wp
      WRITE (*, '(A,A,A,I0,A,F12.8,A,F12.8,A,ES10.3,A,F12.8,A,ES10.3,A)') 'O: ', tag, ' free: mode ', n, ' omega ', &
        omega(n), ' rad/s; quarter-wave ', w_cont, ' (', e_cont, '); clamped-free chain ', w_disc, ' (', e_disc, ')'
      CALL require(ABS(e_disc) <= 1.0e-6_wp, 'O: the twist mode matches the clamped-free chain')
      ! the lumped-inertia chain lies x^2/6 below the continuum
      CALL require(ABS(e_cont) <= 1.2_wp*x**2/6.0_wp + 1.0e-6_wp, &
                   'O: the twist mode matches the quarter-wave (2n - 1) pi/(2L) sqrt(GJ/Irn)')
    END DO
    CALL input_columns(3, 1, b, dmom)
    k_red = reduced(amat, cmom, b, dmom, 3)
    WRITE (*, '(A,A,A,ES12.4,A,ES16.9,A,ES16.9)') 'O: ', tag, ' free: -(D - C A^-1 B) ', k_red, &
      ' N m/rad (GJ/L ', GJ/L, '); feedthrough D alone ', -dmom(3)
    CALL require(ABS(k_red) <= 1.0e-6_wp*GJ/L, 'O: a line free at one end has no roll stiffness')
    CALL CD_AGG_End(agg, es, em)
  END SUBROUTINE check_free_end

END PROGRAM test_lin_torsion
