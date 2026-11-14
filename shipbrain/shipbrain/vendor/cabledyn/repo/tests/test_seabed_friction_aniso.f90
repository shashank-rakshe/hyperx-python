! File: tests/test_seabed_friction_aniso.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_seabed_friction_aniso
  !! Anisotropic (axial/lateral) seabed friction:
  !!   1. The laws (CD_Seabed_Friction_Aniso): slip along the line resists with mu_axial,
  !!      across it with mu_lateral, obliquely with sqrt((mu_a cos)^2 + (mu_n sin)^2) and
  !!      collinear with the slip; the Jacobians match central differences; an equal pair
  !!      matches the isotropic laws; a vertical line takes mu_lateral.
  !!   2. An EI = 0 line laid on the seabed and dragged bodily along its axis, then across
  !!      it, loads its two driven ends with the Coulomb force mu*w*L of the sliding line
  !!      (axial and lateral coefficients swapped between two runs).
  !!   3. frictionMuAxial = frictionMuLateral = frictionMu reproduces the frictionMu run
  !!      bit-for-bit (EI = 0 chain under a sliding fairlead drive, finite-EI touchdown deck).
  !!   4. A line held at rest against a current by anisotropic friction does not drift
  !!      (EI = 0 and finite-EI).
  !!   5. A finite-EI touchdown cable pulled along its axis loads the anchor more with a low
  !!      axial coefficient than with a high one.
  !!   6. Deck rules: a pair with one zero coefficient is rejected.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_SeabedContact
  USE CableDyn_DeckDriver, ONLY: CD_Run_Deck_Driver, CD_DECKDRV_OK
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Model, CD_Step_Model, CD_Calc_Model_CoupledLoads, &
                            CD_End_Model, CD_Set_Model_Friction_Axial, CD_MODEL_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  INTEGER :: nfail

  nfail = 0
  CALL case_laws()
  CALL case_drag()
  CALL case_isotropic_identity()
  CALL case_at_rest()
  CALL case_hermite_pull()
  CALL case_rules()
  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'test_seabed_friction_aniso: ', nfail, ' failure(s)'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'test_seabed_friction_aniso: all checks passed'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A)') 'MISMATCH ['//label//']'
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

  SUBROUTINE case_laws()
    REAL(wp), PARAMETER :: K = 1.0e5_wp, N = 2.0e3_wp, MA = 0.3_wp, MN = 0.9_wp
    REAL(wp) :: axis(2), d(2), f(2), dfd(2, 2), dfn(2), fi(2), dfdi(2, 2), dfci(2)
    REAL(wp) :: fp(2), fm(2), dd(2, 2), dn(2), jfd(2, 2), jn(2), h, th, mu, q, gq(2), big
    INTEGER :: law, j, it
    axis = [3.0_wp, 4.0_wp]           ! any length; unit axis (0.6, 0.8)
    big = 10.0_wp                     ! far beyond the slip distance mu N/k
    ! pure axial / lateral / oblique slip with the stick-slip law
    d = big*[0.6_wp, 0.8_wp]
    CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d, K, N, MA, MN, axis, f, dfd, dfn)
    CALL require(ABS(NORM2(f) - MA*N) < 1.0e-10_wp*MA*N, 'law:axial-slip-mu_a')
    d = big*[-0.8_wp, 0.6_wp]
    CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d, K, N, MA, MN, axis, f, dfd, dfn)
    CALL require(ABS(NORM2(f) - MN*N) < 1.0e-10_wp*MN*N, 'law:lateral-slip-mu_n')
    DO it = 1, 7
      th = REAL(it, wp)*PI/8.0_wp
      d = big*(COS(th)*[0.6_wp, 0.8_wp] + SIN(th)*[-0.8_wp, 0.6_wp])
      CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d, K, N, MA, MN, axis, f, dfd, dfn)
      CALL require(ABS(NORM2(f) - N*SQRT((MA*COS(th))**2 + (MN*SIN(th))**2)) < 1.0e-10_wp*N, 'law:oblique-mu')
      CALL require(ABS(f(1)*d(2) - f(2)*d(1)) < 1.0e-9_wp*NORM2(f)*NORM2(d) .AND. DOT_PRODUCT(f, d) > 0.0_wp, &
                   'law:collinear-with-slip')
      ! the static spring tends to the same capacity far out
      CALL CD_Seabed_Friction_Aniso(CD_FRICTION_SPRING, 1.0e4_wp*d, K, N, MA, MN, axis, f, dfd, dfn)
      CALL require(ABS(NORM2(f)/(N*SQRT((MA*COS(th))**2 + (MN*SIN(th))**2)) - 1.0_wp) < 1.0e-6_wp, &
                   'law:spring-capacity')
    END DO
    ! sticking: linear spring
    d = [1.0e-4_wp, -2.0e-4_wp]
    CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, d, K, N, MA, MN, axis, f, dfd, dfn)
    CALL require(nan_max_abs(f - K*d) < 1.0e-12_wp .AND. nan_max_abs(dfn) <= 0.0_wp, 'law:stick-linear')
    ! vertical line axis: lateral coefficient in every direction
    CALL CD_Seabed_Friction_Aniso(CD_FRICTION_STICK_SLIP, big*[0.6_wp, 0.8_wp], K, N, MA, MN, [0.0_wp, 0.0_wp], &
                                  f, dfd, dfn)
    CALL require(ABS(NORM2(f) - MN*N) < 1.0e-10_wp*MN*N, 'law:vertical-axis-lateral')
    CALL CD_Seabed_Friction_Mu_Dir(big*[0.6_wp, 0.8_wp], MA, MN, axis, mu, q, gq)
    CALL require(ABS(mu - MA) < 1.0e-14_wp, 'law:mu-dir-axial')
    ! Jacobians against central differences (sliding and spring regimes)
    DO law = 1, 2
      d = [0.3_wp, -0.05_wp]
      IF (law == CD_FRICTION_STICK_SLIP) d = 50.0_wp*d
      CALL CD_Seabed_Friction_Aniso(law, d, K, N, MA, MN, axis, f, dfd, dfn)
      DO j = 1, 2
        h = 1.0e-6_wp*MAX(1.0_wp, ABS(d(j)))
        dd = 0.0_wp
        dd(j, j) = h
        CALL CD_Seabed_Friction_Aniso(law, d + dd(:, j), K, N, MA, MN, axis, fp, jfd, jn)
        CALL CD_Seabed_Friction_Aniso(law, d - dd(:, j), K, N, MA, MN, axis, fm, jfd, jn)
        CALL require(nan_max_abs((fp - fm)/(2.0_wp*h) - dfd(:, j)) < 1.0e-5_wp*MAX(1.0_wp, nan_max_abs(dfd)), &
                     'law:jacobian-d')
      END DO
      h = 1.0e-3_wp
      CALL CD_Seabed_Friction_Aniso(law, d, K, N + h, MA, MN, axis, fp, jfd, jn)
      CALL CD_Seabed_Friction_Aniso(law, d, K, N - h, MA, MN, axis, fm, jfd, jn)
      dn = (fp - fm)/(2.0_wp*h)
      CALL require(nan_max_abs(dn - dfn) < 1.0e-6_wp*MAX(1.0_wp, nan_max_abs(dfn)), 'law:jacobian-normal')
    END DO
    ! equal pair = isotropic laws
    DO law = 1, 2
      d = [0.3_wp, -0.05_wp]
      IF (law == CD_FRICTION_STICK_SLIP) d = 50.0_wp*d
      CALL CD_Seabed_Friction_Aniso(law, d, K, N, 0.6_wp, 0.6_wp, axis, f, dfd, dfn)
      IF (law == CD_FRICTION_SPRING) THEN
        CALL CD_Seabed_Friction_Spring(d, K, 0.6_wp*N, fi, dfdi, dfci)
      ELSE
        CALL CD_Seabed_Friction_Stick_Slip(d, K, 0.6_wp*N, fi, dfdi, dfci)
      END IF
      CALL require(nan_max_abs(f - fi) < 1.0e-12_wp*nan_max_abs(fi) .AND. &
                   nan_max_abs(dfd - dfdi) < 1.0e-10_wp*nan_max_abs(dfdi) .AND. &
                   nan_max_abs(dfn - 0.6_wp*dfci) < 1.0e-10_wp*MAX(1.0e-30_wp, nan_max_abs(dfci)), &
                   'law:equal-pair-is-isotropic')
    END DO
    jn = 0.0_wp
    jfd = 0.0_wp
  END SUBROUTINE case_laws

  ! ------------------------------------------------------------------ decks

  SUBROUTINE write_chain_deck(path, fric_rows, current, motion)
    !! The WD0050 grounded chain (410 m, 41 segments) from a Coupled fairlead, optionally in
    !! a current and driven by a motion file.
    CHARACTER(*), INTENT(IN) :: path, fric_rows(:), current, motion
    INTEGER :: u, i
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'grounded chain with anisotropic friction'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 400.0 0.0 -50.0'
    WRITE (u, '(A)') '2 Coupled 0.0 0.0 -5.0'
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
    WRITE (u, '(A)') '1.0e4 cBot'
    DO i = 1, SIZE(fric_rows)
      IF (LEN_TRIM(fric_rows(i)) > 0) WRITE (u, '(A)') TRIM(fric_rows(i))
    END DO
    IF (LEN_TRIM(current) > 0) WRITE (u, '(A)') TRIM(current)//' current'
    IF (LEN_TRIM(motion) > 0) WRITE (u, '(A)') TRIM(motion)//' motionFile'
    WRITE (u, '(A)') '0.05 dtM'
    WRITE (u, '(A)') '2.0 TMax'
    WRITE (u, '(A)') '--- OUTPUTS ---'
    WRITE (u, '(A)') 'FairTen1 AnchTen1 L1N30px L1N30py L1N30pz'
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_chain_deck

  SUBROUTINE write_surge_motion(path)
    !! Fairlead (point 2) surge-and-sway of 2 m over 2 s (half-cosine), enough to slide the
    !! grounded run.
    CHARACTER(*), INTENT(IN) :: path
    INTEGER :: u, i
    REAL(wp) :: t, x, v, a
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az'
    DO i = 0, 40
      t = 0.05_wp*REAL(i, wp)
      x = 1.0_wp*(1.0_wp - COS(PI*t/2.0_wp))
      v = 1.0_wp*(PI/2.0_wp)*SIN(PI*t/2.0_wp)
      a = 1.0_wp*(PI/2.0_wp)**2*COS(PI*t/2.0_wp)
      WRITE (u, '(ES17.10,1X,I0,9(1X,ES17.10))') t, 2, -x, x, -5.0_wp, -v, v, 0.0_wp, -a, a, 0.0_wp
    END DO
    CLOSE (u)
  END SUBROUTINE write_surge_motion

  SUBROUTINE read_out(path, data, nrow)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: data(:, :)
    INTEGER, INTENT(OUT) :: nrow
    INTEGER :: u, ios, ncol, k
    CHARACTER(4096) :: line
    LOGICAL :: header_seen
    REAL(wp), ALLOCATABLE :: grow(:, :)
    nrow = 0
    ncol = 0
    header_seen = .FALSE.
    ALLOCATE (data(0, 0))
    OPEN (NEWUNIT=u, FILE=path, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) RETURN
    DO
      READ (u, '(A)', IOSTAT=ios) line
      IF (ios /= 0) EXIT
      IF (line(1:1) == '#' .OR. LEN_TRIM(line) == 0) CYCLE
      IF (.NOT. header_seen) THEN
        header_seen = .TRUE.
        ncol = count_tokens(line)
        DEALLOCATE (data)
        ALLOCATE (data(ncol, 64))
        CYCLE
      END IF
      IF (nrow == SIZE(data, 2)) THEN
        ALLOCATE (grow(ncol, 2*SIZE(data, 2)))
        grow(:, 1:nrow) = data(:, 1:nrow)
        CALL MOVE_ALLOC(grow, data)
      END IF
      nrow = nrow + 1
      READ (line, *, IOSTAT=ios) (data(k, nrow), k=1, ncol)
      IF (ios /= 0) nrow = nrow - 1
    END DO
    CLOSE (u)
  END SUBROUTINE read_out

  INTEGER FUNCTION count_tokens(line) RESULT(n)
    CHARACTER(*), INTENT(IN) :: line
    INTEGER :: i
    LOGICAL :: inside
    n = 0
    inside = .FALSE.
    DO i = 1, LEN_TRIM(line)
      IF (line(i:i) == ' ' .OR. line(i:i) == CHAR(9)) THEN
        inside = .FALSE.
      ELSE IF (.NOT. inside) THEN
        inside = .TRUE.
        n = n + 1
      END IF
    END DO
  END FUNCTION count_tokens

  LOGICAL FUNCTION files_identical(a, b) RESULT(same)
    CHARACTER(*), INTENT(IN) :: a, b
    INTEGER :: ua, ub, ia, ib
    CHARACTER(4096) :: la, lb
    same = .FALSE.
    OPEN (NEWUNIT=ua, FILE=a, STATUS='OLD', ACTION='READ', IOSTAT=ia)
    OPEN (NEWUNIT=ub, FILE=b, STATUS='OLD', ACTION='READ', IOSTAT=ib)
    IF (ia /= 0 .OR. ib /= 0) RETURN
    DO
      READ (ua, '(A)', IOSTAT=ia) la
      READ (ub, '(A)', IOSTAT=ib) lb
      IF (ia /= 0 .OR. ib /= 0) EXIT
      IF (la /= lb) THEN
        CLOSE (ua)
        CLOSE (ub)
        RETURN
      END IF
    END DO
    same = (ia < 0 .AND. ib < 0)
    CLOSE (ua)
    CLOSE (ub)
  END FUNCTION files_identical

  SUBROUTINE run(tag, conv_ok)
    CHARACTER(*), INTENT(IN) :: tag
    LOGICAL, INTENT(OUT) :: conv_ok
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    CALL CD_Run_Deck_Driver(tag//'.dat', tag, conv, es, em)
    conv_ok = (es == CD_DECKDRV_OK .AND. conv)
    CALL require(conv_ok, tag//':runs: '//TRIM(em))
  END SUBROUTINE run

  SUBROUTINE case_drag()
    !! Bodily drag of a laid EI = 0 line (CableDyn_Model, 51 nodes, 100 m on a flat bed):
    !! both ends are driven at 0.3 m/s along the line axis, then across it. At constant speed
    !! the end loads balance the Coulomb force of the sliding line, mu w L (the end nodes'
    !! own friction included in their coupled loads), with mu the axial coefficient for the
    !! axial drag and the lateral one across; the pair is then swapped. A 0.1 % pre-strain
    !! gives the line the tension that carries a lateral drag across the span; the forces
    !! are averaged over the last 4 s (two periods of the lateral string mode).
    INTEGER, PARAMETER :: NN = 51, NAVG = 200
    REAL(wp), PARAMETER :: L = 100.0_wp, WPL = 900.0_wp, KN_PL = 1.0e6_wp, DT = 0.02_wp
    REAL(wp), PARAMETER :: V = 0.3_wp, TR = 1.5_wp, TEND = 12.0_wp, PRESTRAIN = 1.0e-3_wp
    TYPE(CD_ModelType) :: model
    TYPE(GenAlphaConfig) :: cfg
    INTEGER :: conn(2, NN - 1), fixed(6), es, i, ic, axis, k, nstep, nit
    REAL(wp) :: q0(3*NN), v0(3*NN), fext(3*NN), l0(NN - 1), ea(NN - 1), rho_a(NN - 1), kn(NN), cn(NN)
    REAL(wp) :: qp(3*NN), vp(3*NN), ap(3*NN), loads(6), mu_a(2), mu_n(2), t, s, pos, vel, acc, got, expect, trib
    LOGICAL :: conv, stalled
    CHARACTER(256) :: em
    CHARACTER(32) :: tag
    mu_a = [0.3_wp, 0.9_wp]
    mu_n = [0.9_wp, 0.3_wp]
    DO i = 1, NN - 1
      conn(:, i) = [i, i + 1]
    END DO
    l0 = L/REAL(NN - 1, wp)
    ea = 1.0e9_wp
    rho_a = 100.0_wp
    fixed = [1, 2, 3, 3*NN - 2, 3*NN - 1, 3*NN]
    DO ic = 1, 2
      DO axis = 1, 2
        WRITE (tag, '(A,I0,A,I0)') 'drag-', ic, '-', axis
        fext = 0.0_wp
        DO i = 1, NN
          trib = l0(1)*MERGE(0.5_wp, 1.0_wp, i == 1 .OR. i == NN)
          kn(i) = KN_PL*trib
          cn(i) = 0.01_wp*kn(i)
          fext(3*i) = -WPL*trib
          ! resting penetration: the normal spring carries the nodal weight
          q0(3*i - 2:3*i) = [REAL(i - 1, wp)*l0(1)*(1.0_wp + PRESTRAIN), 0.0_wp, -WPL*trib/kn(i)]
        END DO
        v0 = 0.0_wp
        CALL CD_Init_Model(model, q0, v0, conn, l0, ea, rho_a, .FALSE., fext, fixed, cfg, es, em, &
                           seabed_z_floor=0.0_wp, seabed_kn=kn, seabed_cn=cn, seabed_mu=mu_n(ic))
        CALL require(es == CD_MODEL_OK, TRIM(tag)//':init: '//TRIM(em))
        IF (es /= CD_MODEL_OK) CYCLE
        CALL CD_Set_Model_Friction_Axial(model, mu_a(ic), es, em)
        CALL require(es == CD_MODEL_OK, TRIM(tag)//':set-axial: '//TRIM(em))
        nstep = NINT(TEND/DT)
        got = 0.0_wp
        DO k = 1, nstep
          t = REAL(k, wp)*DT
          IF (t < TR) THEN
            s = t/TR
            pos = V*TR*(2.5_wp*s**4 - 3.0_wp*s**5 + s**6)
            vel = V*(10.0_wp*s**3 - 15.0_wp*s**4 + 6.0_wp*s**5)
            acc = V*(30.0_wp*s**2 - 60.0_wp*s**3 + 30.0_wp*s**4)/TR
          ELSE
            pos = 0.5_wp*V*TR + V*(t - TR)
            vel = V
            acc = 0.0_wp
          END IF
          qp = q0
          vp = 0.0_wp
          ap = 0.0_wp
          DO i = 1, NN, NN - 1
            qp(3*i - 3 + axis) = q0(3*i - 3 + axis) + pos
            vp(3*i - 3 + axis) = vel
            ap(3*i - 3 + axis) = acc
          END DO
          CALL CD_Step_Model(model, DT, conv, stalled, nit, es, em, prescribed_q=qp, prescribed_v=vp, &
                             prescribed_a=ap)
          IF (es /= CD_MODEL_OK .OR. .NOT. conv) EXIT
          IF (k > nstep - NAVG) THEN
            CALL CD_Calc_Model_CoupledLoads(model, loads, es, em)
            got = got + loads(axis) + loads(3 + axis)
          END IF
        END DO
        CALL require(es == CD_MODEL_OK .AND. conv, TRIM(tag)//':march: '//TRIM(em))
        got = -got/REAL(NAVG, wp)
        expect = MERGE(mu_a(ic), mu_n(ic), axis == 1)*WPL*L
        WRITE (*, '(A,A,2ES14.6,F10.6)') TRIM(tag), ' friction force got/expected/ratio: ', got, expect, got/expect
        CALL require(ABS(got/expect - 1.0_wp) < 0.01_wp, TRIM(tag)//':coulomb-force')
        CALL CD_End_Model(model, es, em)
      END DO
    END DO
  END SUBROUTINE case_drag

  SUBROUTINE case_isotropic_identity()
    CHARACTER(80) :: rows(3)
    LOGICAL :: ok1, ok2
    CALL write_surge_motion('franiso_surge.txt')
    rows = ''
    rows(1) = '0.6 frictionMu'
    CALL write_chain_deck('franiso_iso_a.dat', rows, '', 'franiso_surge.txt')
    rows(2) = '0.6 frictionMuAxial'
    rows(3) = '0.6 frictionMuLateral'
    CALL write_chain_deck('franiso_iso_b.dat', rows, '', 'franiso_surge.txt')
    CALL run('franiso_iso_a', ok1)
    CALL run('franiso_iso_b', ok2)
    IF (ok1 .AND. ok2) CALL require(files_identical('franiso_iso_a.out', 'franiso_iso_b.out'), &
                                    'identity:ei0-equal-pair-bit-identical')
    ! finite-EI touchdown cable (Hermite route)
    CALL write_touchdown_deck('franiso_fei_a.dat', ['0.8 frictionMu     ', '                   '])
    CALL write_touchdown_deck('franiso_fei_b.dat', ['0.8 frictionMuAxial', '0.8 frictionMu     '])
    CALL run('franiso_fei_a', ok1)
    CALL run('franiso_fei_b', ok2)
    IF (ok1 .AND. ok2) CALL require(files_identical('franiso_fei_a.out', 'franiso_fei_b.out'), &
                                    'identity:finite-ei-equal-pair-bit-identical')
  END SUBROUTINE case_isotropic_identity

  SUBROUTINE write_touchdown_deck(path, fric_rows, current, motion, long_run)
    !! Finite-EI touchdown cable (Hermite route), optionally in a lateral current or driven
    !! by a motion file; long_run: a 90 m cable with a long grounded run.
    CHARACTER(*), INTENT(IN) :: path, fric_rows(:)
    CHARACTER(*), INTENT(IN), OPTIONAL :: current, motion
    LOGICAL, INTENT(IN), OPTIONAL :: long_run
    INTEGER :: u, i
    LOGICAL :: long
    long = .FALSE.
    IF (PRESENT(long_run)) long = long_run
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') 'finite-EI touchdown cable with anisotropic friction'
    WRITE (u, '(A)') '--- LINE TYPES ---'
    WRITE (u, '(A)') 'Name Diam Mass EA BA EI Cdn Cdt Can Cat'
    WRITE (u, '(A)') '(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)'
    WRITE (u, '(A)') 'pcable 0.20 250 8.0e8 0.0 2.0e5 1.0 0.0 1.0 0.0'
    WRITE (u, '(A)') '--- POINTS ---'
    WRITE (u, '(A)') 'ID Type X Y Z'
    WRITE (u, '(A)') '(-) (-) (m) (m) (m)'
    WRITE (u, '(A)') '1 Fixed 0 0 -80.0'
    IF (long) THEN
      WRITE (u, '(A)') '2 Coupled 70 0 -50.0'
    ELSE
      WRITE (u, '(A)') '2 Coupled 40 0 -70.0'
    END IF
    WRITE (u, '(A)') '--- LINES ---'
    WRITE (u, '(A)') 'ID NodeA NodeB Outputs'
    WRITE (u, '(A)') '(-) (-) (-) (-)'
    WRITE (u, '(A)') '1 2 1 -'
    WRITE (u, '(A)') '--- SECTIONS ---'
    WRITE (u, '(A)') 'LineID LineType Length NumSegs'
    WRITE (u, '(A)') '(-) (-) (m) (-)'
    IF (long) THEN
      WRITE (u, '(A)') '1 pcable 90 45'
    ELSE
      WRITE (u, '(A)') '1 pcable 45 20'
    END IF
    WRITE (u, '(A)') '--- OPTIONS ---'
    WRITE (u, '(A)') '9.80665 g'
    WRITE (u, '(A)') '1025.0 rhoW'
    WRITE (u, '(A)') '80.0 WtrDpth'
    WRITE (u, '(A)') '1.0e5 kBot'
    WRITE (u, '(A)') '1.0e4 cBot'
    DO i = 1, SIZE(fric_rows)
      IF (LEN_TRIM(fric_rows(i)) > 0) WRITE (u, '(A)') TRIM(fric_rows(i))
    END DO
    IF (PRESENT(current)) WRITE (u, '(A)') TRIM(current)//' current'
    IF (PRESENT(motion)) WRITE (u, '(A)') TRIM(motion)//' motionFile'
    WRITE (u, '(A)') 'True adaptive_mesh'
    WRITE (u, '(A)') '0.02 dtM'
    IF (PRESENT(motion)) THEN
      WRITE (u, '(A)') '4.0 TMax'
    ELSE
      WRITE (u, '(A)') '1.0 TMax'
    END IF
    WRITE (u, '(A)') '--- OUTPUTS ---'
    IF (long) THEN
      WRITE (u, '(A)') 'FairTen1 AnchTen1 L1N5px L1N5py L1N5pz L1N30px L1N30py L1N30pz L1N17py L1N20py L1N21py'
    ELSE
      WRITE (u, '(A)') 'FairTen1 AnchTen1 L1N5px L1N5py L1N5pz'
    END IF
    WRITE (u, '(A)') '--- end ---'
    CLOSE (u)
  END SUBROUTINE write_touchdown_deck

  SUBROUTINE check_at_rest(tag)
    CHARACTER(*), INTENT(IN) :: tag
    REAL(wp), ALLOCATABLE :: dat(:, :)
    INTEGER :: nrow, k
    REAL(wp) :: dten, dpos
    CALL read_out(tag//'.out', dat, nrow)
    CALL require(nrow >= 10, tag//':rows')
    IF (nrow < 10) RETURN
    dten = 0.0_wp
    dpos = 0.0_wp
    DO k = 2, nrow
      dten = MAX(dten, ABS(dat(2, k) - dat(2, 1))/ABS(dat(2, 1)))
      dpos = MAX(dpos, nan_max_abs(dat(4:SIZE(dat, 1), k) - dat(4:SIZE(dat, 1), 1)))
    END DO
    WRITE (*, '(A,A,2ES12.4)') tag, ' at-rest max tension change (rel), node drift (m): ', dten, dpos
    CALL require(dten < 1.0e-6_wp .AND. dpos < 1.0e-6_wp, tag//':no-drift-at-rest')
  END SUBROUTINE check_at_rest

  SUBROUTINE case_at_rest()
    !! Lines held at rest against a lateral current by anisotropic friction do not drift.
    CHARACTER(80) :: rows(2)
    LOGICAL :: ok
    rows(1) = '0.3 frictionMuAxial'
    rows(2) = '1.0 frictionMuLateral'
    CALL write_chain_deck('franiso_rest_chain.dat', rows, 'uniform 0.0 0.4 0.0', '')
    CALL run('franiso_rest_chain', ok)
    IF (ok) CALL check_at_rest('franiso_rest_chain')
    CALL write_touchdown_deck('franiso_rest_cable.dat', rows, 'uniform 0.0 0.3 0.0')
    CALL run('franiso_rest_cable', ok)
    IF (ok) CALL check_at_rest('franiso_rest_cable')
  END SUBROUTINE case_at_rest

  SUBROUTINE case_hermite_pull()
    !! Finite-EI (Hermite) touchdown cable whose fairlead is pulled 5 m sideways: the
    !! grounded run is dragged across its axis, so grounded nodes follow further with a
    !! low lateral coefficient than with a high one (axial
    !! coefficient swapped). (An axial pull cannot show the axial coefficient here: the
    !! grounded run is held by the anchor and does not slide.)
    CHARACTER(80) :: rows(2)
    REAL(wp), ALLOCATABLE :: da(:, :), db(:, :)
    INTEGER :: na, nb, u, i
    LOGICAL :: ok1, ok2
    REAL(wp) :: t, x, v, a, s
    OPEN (NEWUNIT=u, FILE='franiso_pull.txt', STATUS='REPLACE', ACTION='WRITE')
    WRITE (u, '(A)') '# time id x y z vx vy vz ax ay az'
    ! a quasi-static 5 m sideways pull: C2 quintic over 4 s
    DO i = 0, 200
      t = 0.02_wp*REAL(i, wp)
      s = t/4.0_wp
      x = 5.0_wp*(10.0_wp*s**3 - 15.0_wp*s**4 + 6.0_wp*s**5)
      v = 5.0_wp*(30.0_wp*s**2 - 60.0_wp*s**3 + 30.0_wp*s**4)/4.0_wp
      a = 5.0_wp*(60.0_wp*s - 180.0_wp*s**2 + 120.0_wp*s**3)/16.0_wp
      WRITE (u, '(ES17.10,1X,I0,9(1X,ES17.10))') t, 2, 70.0_wp, x, -50.0_wp, 0.0_wp, v, 0.0_wp, &
        0.0_wp, a, 0.0_wp
    END DO
    CLOSE (u)
    rows(1) = '0.8 frictionMuAxial'
    rows(2) = '0.1 frictionMuLateral'
    CALL write_touchdown_deck('franiso_pull_lowlat.dat', rows, motion='franiso_pull.txt', long_run=.TRUE.)
    rows(1) = '0.1 frictionMuAxial'
    rows(2) = '0.8 frictionMuLateral'
    CALL write_touchdown_deck('franiso_pull_highlat.dat', rows, motion='franiso_pull.txt', long_run=.TRUE.)
    CALL run('franiso_pull_lowlat', ok1)
    CALL run('franiso_pull_highlat', ok2)
    IF (.NOT. (ok1 .AND. ok2)) RETURN
    CALL read_out('franiso_pull_lowlat.out', da, na)
    CALL read_out('franiso_pull_highlat.out', db, nb)
    CALL require(na == nb .AND. na > 10, 'hermite-pull:rows')
    IF (na /= nb .OR. na <= 10) RETURN
    ! grounded deck nodes 20 and 21 (of 46, node 1 at the fairlead), 38 and 40 m along the line
    WRITE (*, '(A,4ES14.6)') 'hermite sideways pull: grounded-node sway N20, N21 at low / high lateral mu (m): ', &
      da(11, na), da(12, na), db(11, nb), db(12, nb)
    CALL require(da(11, na) > 1.1_wp*db(11, nb) .AND. da(12, na) > 1.1_wp*db(12, nb) .AND. db(12, nb) > 0.0_wp, &
                 'hermite-pull:low-lateral-friction-lets-the-grounded-run-sway-more')
  END SUBROUTINE case_hermite_pull

  SUBROUTINE case_rules()
    CHARACTER(80) :: rows(2)
    LOGICAL :: conv
    INTEGER :: es
    CHARACTER(512) :: em
    rows(1) = '0.5 frictionMuAxial'
    rows(2) = ''
    CALL write_chain_deck('franiso_bad1.dat', rows, '', '')
    CALL CD_Run_Deck_Driver('franiso_bad1.dat', 'franiso_bad1', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'rules:axial-without-lateral-rejected')
    rows(2) = '0.5 frictionMu'
    rows(1) = '0.0 frictionMuLateral'
    CALL write_chain_deck('franiso_bad2.dat', rows, '', '')
    CALL CD_Run_Deck_Driver('franiso_bad2.dat', 'franiso_bad2', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'rules:zero-lateral-rejected')
    rows(1) = '-0.5 frictionMuAxial'
    CALL write_chain_deck('franiso_bad3.dat', rows, '', '')
    CALL CD_Run_Deck_Driver('franiso_bad3.dat', 'franiso_bad3', conv, es, em)
    CALL require(es /= CD_DECKDRV_OK, 'rules:negative-rejected')
  END SUBROUTINE case_rules

END PROGRAM test_seabed_friction_aniso
