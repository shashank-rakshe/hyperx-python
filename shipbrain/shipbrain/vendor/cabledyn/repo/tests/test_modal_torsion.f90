! File: tests/test_modal_torsion.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_modal_torsion
  !! Modal analysis of a cubic-Hermite line restrained in torsion (CD_Modal_Hermite_Line: the
  !! twist angle of every node joins the modes, with the lumped polar inertia Irn l0 as its mass
  !! and the second variation of the twist energy as its stiffness), on a 10 m line along +x:
  !!   T  torsional modes of a straight taut line clamped at both ends (bending Rigid):
  !!      T1 rigid torsional ends: omega_n = n pi/L0 sqrt(GJ/Irn) (continuum; the lumped chain's
  !!         error 1 - sin(x)/x, x = n pi/(2 NE), bounds it) and the chain's own
  !!         2 sqrt(GJ/Irn)/l0 sin(n pi/(2 NE)) to 1e-9; every other mode (bending, axial) equal to
  !!         the same line without torsion to 1e-9 and free of twist;
  !!      T2 elastic torsional ends k: the continuum's ((GJ b)^2 - k^2) sin(b L0) = 2 k GJ b cos(b L0),
  !!         omega = b sqrt(GJ/Irn), and the lumped chain with the end springs (dense solve);
  !!      T3 torque-tension coupling K (energy 1/2 EA e^2 + K e tau + 1/2 GJ tau^2): the coupled
  !!         axial-torsional modes omega^2 = (n pi/L0)^2 eig([[EA, K], [K, GJ]], diag(m, Irn));
  !!   C  the condensed limit (negligible Irn) of a line under a torque M:
  !!      C1 the lateral modes of the straight taut clamped line under the torque M. Linearised
  !!         about the straight state, u = y + i z (s0 the unstretched arc length, stretch lambda),
  !!           (EI/lambda^4) u'''' - i (M/lambda^2) u''' - (T/lambda) u'' = m omega^2 u
  !!         (the shaft under torque of Greenhill, Proc. Inst. Mech. Eng., 1883, and Ziegler,
  !!         Principles of Structural Stability, 1968, with the tension of a taut cable; the twist
  !!         energy -M Theta, Theta = 1/2 int (y'z'' - z'y'')/lambda^2 the parallel-transport
  !!         holonomy of the centreline). u = sum c_j
  !!         exp(i k_j s0) with EIe k^4 - Me k^3 + Te k^2 = m omega^2, clamped (u = u' = 0) at both
  !!         ends: the 4 x 4 determinant, times exp(-i L0 sum k_j/2) purely imaginary, vanishes
  !!         at the frequencies (each a pair of real modes, a helix and its mirror). With
  !!         9 Me^2 < 32 EIe Te the quartic has no double root at omega > 0. The torque lowers
  !!         every lateral frequency (M = 4 EI/L0: -5.5 % on the first);
  !!      C2 the Schur complement of the twist angles in the modal stiffness, K_qq -
  !!         K_qphi K_phiphi^-1 K_phiq, is the condensed static tangent of the statics at the same
  !!         state, the element Hessians + M_t d2(-Theta)/dq2 + (1/C) g g^T (CD_HermiteTorsion_Line,
  !!         M_t = (Phi - Theta)/C), and the central difference of the condensed static residual
  !!         sum f_int - M_t dTheta/dq: on a bowed, twisted line with bending-pinned ends (rigid
  !!         and elastic torsional ends), clamped ends, and torque-tension coupling.
  !!   E  the end connections the modes take from the model: a finite bending spring k at both
  !!      ends of the straight taut line (no torsion) puts its first lateral frequency between the
  !!      pinned (k = 0) and the clamped (Rigid) line's, rising with k and within 1e-4 of the
  !!      clamped one at k = 1e5 EI/L0.
  !! The modal analysis without the twist (the old route: CD_Modal_Hermite_Band, no twist
  !! DOFs, the end connections ignored) is reported beside each gate for comparison.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Modal, ONLY: CD_Modal_Hermite_Line, CD_Modal_Hermite_Line_Band, CD_Modal_Hermite_Band, &
                            CD_Modal_Solve_Band, CD_Modal_Solve, CD_MODAL_OK
  USE CableDyn_EndConnection, ONLY: CD_ENDCONN_RIGID, CD_ENDCONN_FINITE, CD_EndConn_Basis
  USE CableDyn_HermiteCable, ONLY: CD_HermiteCable_Element
  USE CableDyn_HermiteTorsion, ONLY: CD_HermiteTorsionType, CD_HermiteTorsion_Line, CD_HermiteTorsion_Unwrap, &
                                     CD_HermiteTorsion_Compliance, CD_HTORS_OK, CD_HTORS_KBAND
  USE CableDyn_HermiteCableDynamic, ONLY: CD_HermiteCableDynType, CD_HermiteCable_Dyn_Init, &
                                          CD_HermiteCable_Dyn_Set_EndConnection, CD_HermiteCable_Dyn_Set_Torsion, &
                                          CD_HermiteCable_Dyn_End, CD_HCDYN_OK
  IMPLICIT NONE

  REAL(wp), PARAMETER :: PI = 3.141592653589793238462643383279502884197_wp
  REAL(wp), PARAMETER :: L0 = 10.0_wp, EI = 100.0_wp, GJ = 80.0_wp, RHOA = 1.0_wp, TENSION = 10.0_wp
  INTEGER :: nfail = 0

  CALL gate_t1()
  CALL gate_t2()
  CALL gate_t3()
  CALL gate_c1()
  CALL gate_c2('pinned, rigid torsion', .FALSE., 0.0_wp, 0.0_wp)
  CALL gate_c2('pinned, elastic torsion', .FALSE., 0.05_wp, 0.0_wp)
  CALL gate_c2('clamped, rigid torsion', .TRUE., 0.0_wp, 0.0_wp)
  CALL gate_c2('clamped, elastic torsion, coupling K', .TRUE., 0.02_wp, 300.0_wp)
  CALL gate_e()

  IF (nfail > 0) THEN
    WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
    ERROR STOP 1
  END IF
  WRITE (*, '(A)') 'PASS: modal analysis with torsion'

CONTAINS

  INCLUDE 'nan_max_abs.inc'

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (cond) RETURN
    nfail = nfail + 1
    WRITE (*, '(A)') 'FAIL: '//TRIM(label)
  END SUBROUTINE require

  SUBROUTINE straight(ne, stretch, q)
    !! Straight line along +x of ne elements, unstretched length L0 stretched by lambda.
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(IN) :: stretch
    REAL(wp), INTENT(OUT) :: q(:)
    INTEGER :: k
    q = 0.0_wp
    DO k = 1, ne + 1
      q(6*k - 5) = stretch*L0*REAL(k - 1, wp)/REAL(ne, wp)
      q(6*k - 2) = stretch
    END DO
  END SUBROUTINE straight

  SUBROUTINE bowed(ne, q)
    !! A line along +x bowed by y = 0.3 sin^2(pi s/L0), z = 0.1 sin^2(2 pi s/L0) (end tangents
    !! along +x) and stretched by 1 %.
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(OUT) :: q(:)
    INTEGER :: k
    REAL(wp) :: s
    q = 0.0_wp
    DO k = 1, ne + 1
      s = L0*REAL(k - 1, wp)/REAL(ne, wp)
      q(6*k - 5) = 1.01_wp*s
      q(6*k - 4) = 0.3_wp*SIN(PI*s/L0)**2
      q(6*k - 3) = 0.1_wp*SIN(2.0_wp*PI*s/L0)**2
      q(6*k - 2) = 1.01_wp
      q(6*k - 1) = 0.3_wp*(PI/L0)*SIN(2.0_wp*PI*s/L0)
      q(6*k) = 0.1_wp*(2.0_wp*PI/L0)*SIN(4.0_wp*PI*s/L0)
    END DO
  END SUBROUTINE bowed

  SUBROUTINE build(model, ne, q, ea, clamped, torsion, phi, irn, compliance, ktt)
    !! Dynamic line model on q, both end positions held; Rigid bending connections along +x at both
    !! ends when clamped; with torsion, both ends restrained (frames +x / +z, imposed twist phi,
    !! end compliance, polar inertia irn, torque-tension coupling ktt with EA - ktt^2/GJ as the
    !! line's own axial stiffness).
    TYPE(CD_HermiteCableDynType), INTENT(OUT) :: model
    INTEGER, INTENT(IN) :: ne
    REAL(wp), INTENT(IN) :: q(:), ea, phi, irn, compliance, ktt
    LOGICAL, INTENT(IN) :: clamped, torsion
    TYPE(CD_HermiteTorsionType) :: tors
    REAL(wp) :: le(ne), g(SIZE(q)), raw, ea_line
    INTEGER :: es, ndof
    CHARACTER(512) :: em
    ndof = SIZE(q)
    le = L0/REAL(ne, wp)
    ea_line = ea
    IF (torsion) ea_line = ea - ktt**2/GJ
    CALL CD_HermiteCable_Dyn_Init(model, le, [(ea_line, es=1, ne)], [(EI, es=1, ne)], [(RHOA, es=1, ne)], &
                                  [(0.0_wp, es=1, ne)], q, [1, 2, 3, ndof - 5, ndof - 4, ndof - 3], -1.0e3_wp, &
                                  0.0_wp, 0.8_wp, es, em)
    CALL require(es == CD_HCDYN_OK, 'model init: '//TRIM(em))
    IF (clamped) THEN
      CALL CD_HermiteCable_Dyn_Set_EndConnection(model, [0.0_wp, 0.0_wp], &
                                                 RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], [3, 2]), &
                                                 es, em, connection_mode=[CD_ENDCONN_RIGID, CD_ENDCONN_RIGID])
      CALL require(es == CD_HCDYN_OK, 'end connections: '//TRIM(em))
    END IF
    IF (.NOT. torsion) RETURN
    tors%active = .TRUE.
    tors%phi = phi
    tors%ends = RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 1.0_wp, 0.0_wp, 0.0_wp, &
                         0.0_wp, 0.0_wp, 1.0_wp], [3, 4])
    tors%end_compliance = compliance
    ALLOCATE (tors%gj(ne), tors%irn(ne))
    tors%gj = GJ
    tors%irn = irn
    IF (ABS(ktt) > 0.0_wp) THEN
      ALLOCATE (tors%couple(ne))
      tors%couple = ktt/GJ
      CALL CD_HermiteTorsion_Line(q, le, tors%ends, raw, g, es, em, couple=tors%couple)
    ELSE
      CALL CD_HermiteTorsion_Line(q, le, tors%ends, raw, g, es, em)
    END IF
    CALL require(es == CD_HTORS_OK, 'seed twist: '//TRIM(em))
    tors%theta = CD_HermiteTorsion_Unwrap(raw, 0.0_wp)
    tors%has_theta = .TRUE.
    CALL CD_HermiteCable_Dyn_Set_Torsion(model, tors, es, em)
    CALL require(es == CD_HCDYN_OK .AND. model%tw_active, 'torsion: '//TRIM(em))
  END SUBROUTINE build

  SUBROUTINE modes(model, nm, om, polar, nf, label)
    !! The nm lowest modes of model: omega (rad/s) and polar share.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: nm
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: om(:), polar(:)
    INTEGER, INTENT(OUT) :: nf
    CHARACTER(*), INTENT(IN) :: label
    REAL(wp), ALLOCATABLE :: om2(:), sh(:, :)
    INTEGER :: es, dpn
    CHARACTER(1024) :: em
    CALL CD_Modal_Hermite_Line(model, nm, om2, sh, nf, dpn, polar, es, em)
    CALL require(es == CD_MODAL_OK .AND. nf == nm, label//': modal solve: '//TRIM(em))
    ALLOCATE (om(MAX(nf, 1)))
    om = SQRT(MAX(om2, 0.0_wp))
  END SUBROUTINE modes

  SUBROUTINE old_modes(model, nm, om)
    !! The modal route without the twist: CD_Modal_Hermite_Band, the cable's freemask (the end
    !! connections ignored), no twist DOFs.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    INTEGER, INTENT(IN) :: nm
    REAL(wp), INTENT(OUT) :: om(nm)
    REAL(wp), ALLOCATABLE :: kb(:, :), mb(:, :), om2(:), sh(:, :)
    INTEGER :: kd, es, nf
    CHARACTER(1024) :: em
    om = 0.0_wp
    CALL CD_Modal_Hermite_Band(model%q, model%l0, model%EA, model%EI, model%rho_a, kd, kb, mb, es, em)
    ALLOCATE (om2(nm), sh(model%ndof, nm))
    IF (es == CD_MODAL_OK) CALL CD_Modal_Solve_Band(kb, mb, kd, model%freemask, nm, om2, sh, nf, es, em)
    IF (es == CD_MODAL_OK) om = SQRT(MAX(om2, 0.0_wp))
  END SUBROUTINE old_modes

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE gate_t1()
    !! T1: rigid torsional ends, Phi = 0, Irn = 0.04 (torsional modes at 14.05 and 28.10 rad/s,
    !! between the bending pairs; EA = 1e4 puts the first axial mode at 31.4 rad/s).
    INTEGER, PARAMETER :: NE = 40, NM = 13
    REAL(wp), PARAMETER :: IRN = 0.04_wp, EA = 1.0e4_wp
    TYPE(CD_HermiteCableDynType) :: mt, mf
    REAL(wp), ALLOCATABLE :: om(:), pol(:), omf(:), polf(:)
    REAL(wp) :: q(6*(NE + 1)), cont, chain, err_c, err_d, bound, err_nt, mix, oold(NM)
    INTEGER :: nf, nff, j, n, jn
    CALL straight(NE, 1.0_wp + TENSION/EA, q)
    CALL build(mt, NE, q, EA, .TRUE., .TRUE., 0.0_wp, IRN, 0.0_wp, 0.0_wp)
    CALL build(mf, NE, q, EA, .TRUE., .FALSE., 0.0_wp, IRN, 0.0_wp, 0.0_wp)
    CALL modes(mt, NM, om, pol, nf, 'T1 torsion')
    CALL modes(mf, NM, omf, polf, nff, 'T1 free')
    IF (nf /= NM .OR. nff /= NM) RETURN
    n = 0
    jn = 0
    err_nt = 0.0_wp
    mix = 0.0_wp
    DO j = 1, NM
      IF (pol(j) > 0.5_wp) THEN
        n = n + 1
        cont = REAL(n, wp)*PI/L0*SQRT(GJ/IRN)
        chain = 2.0_wp*SQRT(GJ/IRN)/(L0/REAL(NE, wp))*SIN(REAL(n, wp)*PI/(2.0_wp*REAL(NE, wp)))
        err_c = ABS(om(j)/cont - 1.0_wp)
        err_d = ABS(om(j)/chain - 1.0_wp)
        bound = 1.0_wp - SIN(REAL(n, wp)*PI/(2.0_wp*REAL(NE, wp)))/(REAL(n, wp)*PI/(2.0_wp*REAL(NE, wp)))
        WRITE (*, '(A,I0,A,F10.5,A,F10.5,A,ES9.2,A,ES9.2,A,ES9.2,A,ES9.2)') '  T1 torsional mode ', n, &
          ': omega ', om(j), ' continuum ', cont, ' error ', err_c, ' (bound ', 1.01_wp*bound, '), chain error ', &
          err_d, ', polar share 1 - ', 1.0_wp - pol(j)
        CALL require(err_c <= 1.01_wp*bound + 1.0e-9_wp, 'T1: torsional mode against the continuum')
        CALL require(err_d <= 1.0e-9_wp, 'T1: torsional mode against the lumped chain')
        CALL require(1.0_wp - pol(j) <= 1.0e-9_wp, 'T1: a torsional mode carries no translation')
      ELSE
        jn = jn + 1
        IF (jn > nff) CYCLE
        err_nt = MAX(err_nt, ABS(om(j)/omf(jn) - 1.0_wp))
        mix = MAX(mix, pol(j))
      END IF
    END DO
    WRITE (*, '(A,I0,A,ES9.2,A,ES9.2)') '  T1 ', jn, ' bending/axial modes against the line without torsion: ', &
      err_nt, ', largest polar share ', mix
    CALL require(n == 2, 'T1: two torsional modes among the 13 lowest')
    CALL require(err_nt <= 1.0e-9_wp, 'T1: the bending and axial modes are those of the line without torsion')
    CALL require(mix <= 1.0e-9_wp, 'T1: the bending and axial modes carry no twist')
    CALL old_modes(mt, NM, oold)
    WRITE (*, '(A,F10.5,A,F10.5,A)') '  T1 old route: no torsional mode; its first mode ', oold(1), &
      ' rad/s against ', omf(1), ' rad/s of the clamped line (end connections ignored)'
    CALL CD_HermiteCable_Dyn_End(mt)
    CALL CD_HermiteCable_Dyn_End(mf)
  END SUBROUTINE gate_t1

  SUBROUTINE gate_t2()
    !! T2: elastic torsional ends k = 2 GJ/L0 at both ends (Phi = 0, Irn = 0.04).
    INTEGER, PARAMETER :: NE = 40, NM = 16, NT = 2
    REAL(wp), PARAMETER :: IRN = 0.04_wp, EA = 1.0e4_wp, KT = 2.0_wp*GJ/L0
    TYPE(CD_HermiteCableDynType) :: mt
    REAL(wp), ALLOCATABLE :: om(:), pol(:)
    REAL(wp) :: q(6*(NE + 1)), cont(NT), chain(NT), err_c, err_d, h
    REAL(wp) :: kc(NE + 1, NE + 1), mc(NE + 1, NE + 1), w2(NE + 1), sh(NE + 1, NE + 1)
    LOGICAL :: fr(NE + 1)
    INTEGER :: nf, j, n, e, es
    CHARACTER(512) :: em
    CALL straight(NE, 1.0_wp + TENSION/EA, q)
    CALL build(mt, NE, q, EA, .TRUE., .TRUE., 0.0_wp, IRN, 1.0_wp/KT, 0.0_wp)
    CALL modes(mt, NM, om, pol, nf, 'T2')
    IF (nf /= NM) RETURN
    ! continuum: ((GJ b)^2 - k^2) sin(b L0) - 2 k GJ b cos(b L0) = 0, bracketed on a fine grid
    CALL elastic_roots(KT, IRN, cont)
    ! the lumped chain with its end springs (dense reference solve)
    h = L0/REAL(NE, wp)
    kc = 0.0_wp
    mc = 0.0_wp
    DO e = 1, NE
      kc(e, e) = kc(e, e) + GJ/h
      kc(e + 1, e + 1) = kc(e + 1, e + 1) + GJ/h
      kc(e, e + 1) = kc(e, e + 1) - GJ/h
      kc(e + 1, e) = kc(e + 1, e) - GJ/h
      mc(e, e) = mc(e, e) + 0.5_wp*IRN*h
      mc(e + 1, e + 1) = mc(e + 1, e + 1) + 0.5_wp*IRN*h
    END DO
    kc(1, 1) = kc(1, 1) + KT
    kc(NE + 1, NE + 1) = kc(NE + 1, NE + 1) + KT
    fr = .TRUE.
    CALL CD_Modal_Solve(kc, mc, fr, NE + 1, w2, sh, n, es, em)
    CALL require(es == CD_MODAL_OK, 'T2: chain reference solve: '//TRIM(em))
    chain = SQRT(w2(1:NT))
    n = 0
    DO j = 1, NM
      IF (pol(j) <= 0.5_wp .OR. n >= NT) CYCLE
      n = n + 1
      err_c = ABS(om(j)/cont(n) - 1.0_wp)
      err_d = ABS(om(j)/chain(n) - 1.0_wp)
      WRITE (*, '(A,I0,A,F10.5,A,F10.5,A,ES9.2,A,ES9.2)') '  T2 elastic-end torsional mode ', n, ': omega ', &
        om(j), ' continuum ', cont(n), ' error ', err_c, ', lumped chain error ', err_d
      CALL require(err_c <= 1.0e-3_wp, 'T2: elastic-end torsional mode against the continuum')
      CALL require(err_d <= 1.0e-9_wp, 'T2: elastic-end torsional mode against the lumped chain')
    END DO
    CALL require(n == NT, 'T2: two torsional modes found')
    CALL CD_HermiteCable_Dyn_End(mt)
  END SUBROUTINE gate_t2

  SUBROUTINE elastic_roots(kt, irn, roots)
    !! The lowest roots b of ((GJ b)^2 - k^2) sin(b L0) - 2 k GJ b cos(b L0), as omega.
    REAL(wp), INTENT(IN) :: kt, irn
    REAL(wp), INTENT(OUT) :: roots(:)
    INTEGER, PARAMETER :: NGRID = 20000
    REAL(wp) :: b0, b1, f0, f1, bm, fm
    INTEGER :: i, n, it
    n = 0
    b0 = 1.0e-6_wp
    f0 = elastic_char(kt, b0)
    DO i = 1, NGRID
      b1 = REAL(i, wp)*(REAL(SIZE(roots) + 1, wp)*PI/L0)/REAL(NGRID, wp)
      f1 = elastic_char(kt, b1)
      IF (f0*f1 < 0.0_wp) THEN
        DO it = 1, 200
          bm = 0.5_wp*(b0 + b1)
          fm = elastic_char(kt, bm)
          IF (fm*f0 > 0.0_wp) THEN
            b0 = bm
            f0 = fm
          ELSE
            b1 = bm
          END IF
        END DO
        n = n + 1
        roots(n) = 0.5_wp*(b0 + b1)*SQRT(GJ/irn)
        IF (n == SIZE(roots)) RETURN
        b1 = REAL(i, wp)*(REAL(SIZE(roots) + 1, wp)*PI/L0)/REAL(NGRID, wp)
        f1 = elastic_char(kt, b1)
      END IF
      b0 = b1
      f0 = f1
    END DO
  END SUBROUTINE elastic_roots

  REAL(wp) FUNCTION elastic_char(kt, b) RESULT(f)
    !! ((GJ b)^2 - k^2) sin(b L0) - 2 k GJ b cos(b L0): zero at a torsional mode with end springs k.
    REAL(wp), INTENT(IN) :: kt, b
    f = ((GJ*b)**2 - kt**2)*SIN(b*L0) - 2.0_wp*kt*GJ*b*COS(b*L0)
  END FUNCTION elastic_char

  SUBROUTINE gate_t3()
    !! T3: torque-tension coupling K = 300 N m (K^2 < EA GJ), Phi = 0, Irn = 0.04: the coupled
    !! axial-torsional modes of the clamped (axially and torsionally held) bar.
    INTEGER, PARAMETER :: NE = 60, NM = 24, NT = 4
    REAL(wp), PARAMETER :: IRN = 0.04_wp, EA = 1.0e4_wp, KTT = 300.0_wp
    TYPE(CD_HermiteCableDynType) :: mt
    REAL(wp), ALLOCATABLE :: om(:), pol(:)
    REAL(wp) :: q(6*(NE + 1)), tr, det, c2(2), ref(2*NT), err, bound, x
    INTEGER :: nf, j, n, i
    CALL straight(NE, 1.0_wp + TENSION/EA, q)
    CALL build(mt, NE, q, EA, .TRUE., .TRUE., 0.0_wp, IRN, 0.0_wp, KTT)
    CALL modes(mt, NM, om, pol, nf, 'T3')
    IF (nf /= NM) RETURN
    ! eig(diag(m, Irn)^-1 [[EA, K], [K, GJ]]): the two wave speeds squared
    tr = EA/RHOA + GJ/IRN
    det = (EA*GJ - KTT**2)/(RHOA*IRN)
    c2(1) = 0.5_wp*(tr - SQRT(tr*tr - 4.0_wp*det))
    c2(2) = 0.5_wp*(tr + SQRT(tr*tr - 4.0_wp*det))
    DO i = 1, NT
      ref(2*i - 1) = REAL(i, wp)*PI/L0*SQRT(c2(1))
      ref(2*i) = REAL(i, wp)*PI/L0*SQRT(c2(2))
    END DO
    CALL sort(ref)
    n = 0
    DO j = 1, NM
      IF (pol(j) <= 1.0e-6_wp) CYCLE
      n = n + 1
      IF (n > NT) EXIT
      err = ABS(om(j)/ref(n) - 1.0_wp)
      ! the lumped twist's error 1 - sin(x)/x, x = n pi/(2 NE), at the mode's larger wavenumber
      ! (the slow family's, n omega/c_slow) bounds the coupled one
      x = REAL(CEILING(ref(n)/SQRT(c2(1))*L0/PI - 1.0e-9_wp), wp)*PI/(2.0_wp*REAL(NE, wp))
      bound = 1.0_wp - SIN(x)/x
      WRITE (*, '(A,I0,A,F10.5,A,F10.5,A,ES9.2,A,ES9.2,A,F6.3)') '  T3 coupled axial-torsional mode ', n, &
        ': omega ', om(j), ' continuum ', ref(n), ' error ', err, ' (bound ', bound, '), polar share ', pol(j)
      CALL require(err <= bound + 1.0e-6_wp, 'T3: coupled axial-torsional mode against the continuum')
      CALL require(pol(j) > 0.01_wp .AND. pol(j) < 0.99_wp, 'T3: the coupling mixes stretch and twist')
    END DO
    CALL require(n >= NT, 'T3: four coupled modes found')
    CALL CD_HermiteCable_Dyn_End(mt)
  END SUBROUTINE gate_t3

  SUBROUTINE sort(x)
    REAL(wp), INTENT(INOUT) :: x(:)
    INTEGER :: i, j
    REAL(wp) :: t
    DO i = 2, SIZE(x)
      DO j = i, 2, -1
        IF (x(j) >= x(j - 1)) EXIT
        t = x(j)
        x(j) = x(j - 1)
        x(j - 1) = t
      END DO
    END DO
  END SUBROUTINE sort

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE gate_c1()
    !! C1: the straight taut clamped line (T = 10 N, EA = 1e4) under M = 4 EI/L0 = 40 N m with a
    !! negligible Irn = 1e-6 (torsional modes above 2800 rad/s), against the Greenhill-cable
    !! determinant; the untwisted line (Phi = 0) against the same determinant at M = 0.
    INTEGER, PARAMETER :: NE = 100, NROOT = 4, NM = 2*NROOT
    REAL(wp), PARAMETER :: EA = 1.0e4_wp, MT = 40.0_wp, IRN = 1.0e-6_wp
    TYPE(CD_HermiteCableDynType) :: m1, m0
    REAL(wp), ALLOCATABLE :: om(:), pol(:), om0(:), pol0(:)
    REAL(wp) :: q(6*(NE + 1)), lam, ref(NROOT), ref0(NROOT), err, err0, pair, shift_fe, shift_th, oold(NM), mt_model
    INTEGER :: nf, nf0, j
    lam = 1.0_wp + TENSION/EA
    CALL straight(NE, lam, q)
    CALL build(m1, NE, q, EA, .TRUE., .TRUE., MT*L0/GJ, IRN, 0.0_wp, 0.0_wp)
    CALL build(m0, NE, q, EA, .TRUE., .TRUE., 0.0_wp, IRN, 0.0_wp, 0.0_wp)
    mt_model = m1%torsion%torque
    WRITE (*, '(A,F12.8,A)') '  C1 torque of the twisted state ', mt_model, ' N m'
    CALL require(ABS(mt_model - MT) <= 1.0e-9_wp*MT, 'C1: the twisted state carries M = Phi GJ/L0')
    CALL modes(m1, NM, om, pol, nf, 'C1 twisted')
    CALL modes(m0, NM, om0, pol0, nf0, 'C1 untwisted')
    IF (nf /= NM .OR. nf0 /= NM) RETURN
    CALL greenhill_roots(EI/lam**4, MT/lam**2, TENSION/lam, NROOT, ref)
    CALL greenhill_roots(EI/lam**4, 0.0_wp, TENSION/lam, NROOT, ref0)
    DO j = 1, NROOT
      err = MAX(ABS(om(2*j - 1)/ref(j) - 1.0_wp), ABS(om(2*j)/ref(j) - 1.0_wp))
      err0 = MAX(ABS(om0(2*j - 1)/ref0(j) - 1.0_wp), ABS(om0(2*j)/ref0(j) - 1.0_wp))
      pair = ABS(om(2*j)/om(2*j - 1) - 1.0_wp)
      shift_th = ref(j)/ref0(j) - 1.0_wp
      shift_fe = 0.5_wp*(om(2*j - 1) + om(2*j))/(0.5_wp*(om0(2*j - 1) + om0(2*j))) - 1.0_wp
      WRITE (*, '(A,I0,A,F10.6,A,F10.6,A,ES9.2,A,ES9.2,A,F8.4,A,F8.4,A)') '  C1 lateral pair ', j, ': omega ', &
        om(2*j - 1), ' Greenhill cable ', ref(j), ' error ', err, ' (untwisted ', err0, '), shift ', &
        100.0_wp*shift_fe, ' % (theory ', 100.0_wp*shift_th, ' %)'
      CALL require(err <= 1.0e-6_wp, 'C1: lateral frequency under torque against the Greenhill cable')
      CALL require(err0 <= 1.0e-6_wp, 'C1: untwisted lateral frequency against the clamped tensioned beam')
      CALL require(pair <= 1.0e-8_wp, 'C1: the lateral modes under torque come in pairs')
      CALL require(shift_th < 0.0_wp .AND. ABS(shift_fe - shift_th) <= 1.0e-4_wp*ABS(shift_th), &
                   'C1: the torque lowers the frequency by the shift theory gives')
      CALL require(MAXVAL(pol(2*j - 1:2*j)) <= 1.0e-9_wp, 'C1: the lateral modes carry no twist')
    END DO
    CALL old_modes(m1, NM, oold)
    WRITE (*, '(A,ES9.2,A)') '  C1 old route (pinned, untwisted): first lateral pair error ', &
      ABS(oold(1)/ref(1) - 1.0_wp), ' against the Greenhill cable'
    CALL CD_HermiteCable_Dyn_End(m1)
    CALL CD_HermiteCable_Dyn_End(m0)
  END SUBROUTINE gate_c1

  SUBROUTINE greenhill_roots(eie, me, te, nroot, om)
    !! The nroot lowest omega of the clamped Greenhill cable eie u'''' - i me u''' - te u'' = m omega^2 u
    !! on [0, L0]: sign changes of Im(D exp(-i L0 sum k/2)) over omega^2, refined by bisection.
    REAL(wp), INTENT(IN) :: eie, me, te
    INTEGER, INTENT(IN) :: nroot
    REAL(wp), INTENT(OUT) :: om(nroot)
    INTEGER, PARAMETER :: NGRID = 40000
    REAL(wp) :: lmax, l0g, l1g, f0, f1, lm, fm, re_max, im_max
    COMPLEX(wp) :: d
    INTEGER :: i, n, it
    ! an upper bound of the nroot-th root: the clamped beam's (n + 1/2) pi/L0 wavenumber with
    ! tension, enlarged
    lmax = 2.0_wp*(eie*((REAL(nroot, wp) + 0.5_wp)*PI/L0)**4 + te*((REAL(nroot, wp) + 0.5_wp)*PI/L0)**2)/RHOA
    re_max = 0.0_wp
    im_max = 0.0_wp
    n = 0
    om = 0.0_wp
    l0g = 1.0e-9_wp*lmax
    d = det_norm(eie, me, te, RHOA*l0g)
    f0 = AIMAG(d)
    DO i = 1, NGRID
      l1g = lmax*REAL(i, wp)/REAL(NGRID, wp)
      d = det_norm(eie, me, te, RHOA*l1g)
      re_max = MAX(re_max, ABS(REAL(d, wp)))
      im_max = MAX(im_max, ABS(AIMAG(d)))
      f1 = AIMAG(d)
      IF (f0*f1 < 0.0_wp .AND. n < nroot) THEN
        DO it = 1, 200
          lm = 0.5_wp*(l0g + l1g)
          fm = AIMAG(det_norm(eie, me, te, RHOA*lm))
          IF (fm*f0 > 0.0_wp) THEN
            l0g = lm
            f0 = fm
          ELSE
            l1g = lm
          END IF
        END DO
        n = n + 1
        om(n) = SQRT(0.5_wp*(l0g + l1g))
        l1g = lmax*REAL(i, wp)/REAL(NGRID, wp)
        f1 = AIMAG(det_norm(eie, me, te, RHOA*l1g))
      END IF
      l0g = l1g
      f0 = f1
    END DO
    CALL require(n == nroot, 'C1: the Greenhill determinant has the expected roots')
    ! the normalised determinant is purely imaginary (the oracle's own consistency)
    CALL require(re_max <= 1.0e-8_wp*im_max, 'C1: the normalised Greenhill determinant is imaginary')
  END SUBROUTINE greenhill_roots

  COMPLEX(wp) FUNCTION det_norm(eie, me, te, lambda) RESULT(dn)
    !! The clamped-clamped determinant of the Greenhill cable at m omega^2 = lambda, times
    !! exp(-i L0 sum k_j/2): rows u(0), u'(0)/i, u(L0), u'(L0)/i of the four exp(i k_j s0).
    REAL(wp), INTENT(IN) :: eie, me, te, lambda
    COMPLEX(wp) :: k(4), a(4, 4)
    INTEGER :: j
    CALL quartic_roots([CMPLX(-lambda/eie, 0.0_wp, wp), (0.0_wp, 0.0_wp), CMPLX(te/eie, 0.0_wp, wp), &
                        CMPLX(-me/eie, 0.0_wp, wp)], k)
    DO j = 1, 4
      a(1, j) = (1.0_wp, 0.0_wp)
      a(2, j) = k(j)
      a(3, j) = EXP((0.0_wp, 1.0_wp)*k(j)*L0)
      a(4, j) = k(j)*a(3, j)
    END DO
    dn = det4(a)*EXP(-(0.0_wp, 0.5_wp)*L0*SUM(k))
  END FUNCTION det_norm

  SUBROUTINE quartic_roots(c, z)
    !! Roots of z^4 + c(4) z^3 + c(3) z^2 + c(2) z + c(1) (Durand-Kerner, then Newton polish).
    COMPLEX(wp), INTENT(IN) :: c(4)
    COMPLEX(wp), INTENT(OUT) :: z(4)
    COMPLEX(wp) :: den, dz, p, dp
    REAL(wp) :: r
    INTEGER :: it, i, j
    r = 1.0_wp + MAXVAL(ABS(c))
    DO i = 1, 4
      z(i) = r*(0.4_wp, 0.9_wp)**i
    END DO
    DO it = 1, 2000
      dz = (0.0_wp, 0.0_wp)
      DO i = 1, 4
        den = (1.0_wp, 0.0_wp)
        DO j = 1, 4
          IF (j /= i) den = den*(z(i) - z(j))
        END DO
        p = (((z(i) + c(4))*z(i) + c(3))*z(i) + c(2))*z(i) + c(1)
        z(i) = z(i) - p/den
        dz = dz + ABS(p/den)
      END DO
      IF (ABS(dz) <= 1.0e-15_wp*r) EXIT
    END DO
    DO i = 1, 4
      DO it = 1, 3
        p = (((z(i) + c(4))*z(i) + c(3))*z(i) + c(2))*z(i) + c(1)
        dp = ((4.0_wp*z(i) + 3.0_wp*c(4))*z(i) + 2.0_wp*c(3))*z(i) + c(2)
        IF (ABS(dp) > 0.0_wp) z(i) = z(i) - p/dp
      END DO
    END DO
  END SUBROUTINE quartic_roots

  COMPLEX(wp) FUNCTION det4(a0) RESULT(d)
    !! Determinant of a complex 4 x 4 matrix (Gaussian elimination, partial pivoting).
    COMPLEX(wp), INTENT(IN) :: a0(4, 4)
    COMPLEX(wp) :: a(4, 4), t(4), f
    INTEGER :: i, j, p
    a = a0
    d = (1.0_wp, 0.0_wp)
    DO j = 1, 4
      p = j - 1 + MAXLOC(ABS(a(j:4, j)), 1)
      IF (p /= j) THEN
        t = a(j, :)
        a(j, :) = a(p, :)
        a(p, :) = t
        d = -d
      END IF
      d = d*a(j, j)
      IF (.NOT. ABS(a(j, j)) > 0.0_wp) RETURN
      DO i = j + 1, 4
        f = a(i, j)/a(j, j)
        a(i, j:4) = a(i, j:4) - f*a(j, j:4)
      END DO
    END DO
  END FUNCTION det4

  ! ------------------------------------------------------------------------------------------
  SUBROUTINE gate_c2(label, clamped, compliance, ktt)
    !! C2: Schur complement of the twist angles against the condensed static tangent, analytic
    !! and by central differences of the condensed static residual, on the bowed line (NE = 12,
    !! Phi = 1 rad, Irn = 1).
    CHARACTER(*), INTENT(IN) :: label
    LOGICAL, INTENT(IN) :: clamped
    REAL(wp), INTENT(IN) :: compliance, ktt
    INTEGER, PARAMETER :: NE = 12, NN = NE + 1, N6 = 6*NN, N7 = 7*NN
    REAL(wp), PARAMETER :: EA = 1.0e4_wp, PHI = 1.0_wp
    TYPE(CD_HermiteCableDynType) :: model
    REAL(wp), ALLOCATABLE :: kb(:, :), mb(:, :)
    LOGICAL, ALLOCATABLE :: free(:)
    REAL(wp) :: q(N6), k7(N7, N7), kc(N6, N6), kel(N6, N6), tr(N6, N6), s(N6, N6), dq(N6), dl(N6), gp(N6)
    REAL(wp) :: gm(N6), fd(N6)
    REAL(wp) :: sd(N6), kpp(NN, NN), kpq(NN, N6), x(NN, N6), basis(3, 3), h, err_a, err_f, scale, old_err, g0
    INTEGER, ALLOCATABLE :: iq(:), ip(:)
    LOGICAL :: qfree(N6)
    INTEGER :: kd, dpn, es, i, j, nq, np, i6, iend, b0, seed
    CHARACTER(1024) :: em
    CALL bowed(NE, q)
    CALL build(model, NE, q, EA, clamped, .TRUE., PHI, 1.0_wp, compliance, ktt)
    IF (.NOT. model%tw_active) RETURN
    CALL CD_Modal_Hermite_Line_Band(model, kd, kb, mb, free, dpn, es, em)
    CALL require(es == CD_MODAL_OK .AND. dpn == 7, 'C2 '//label//': band: '//TRIM(em))
    IF (es /= CD_MODAL_OK) RETURN
    k7 = 0.0_wp
    DO j = 1, N7
      DO i = MAX(1, j - kd), j
        k7(i, j) = kb(kd + 1 + i - j, j)
        k7(j, i) = k7(i, j)
      END DO
    END DO
    ! free q DOFs (cable numbering) and free angles
    DO i6 = 1, N6
      qfree(i6) = free(i6 + (i6 - 1)/6)
    END DO
    nq = COUNT(qfree)
    np = COUNT(free(7:N7:7))
    ALLOCATE (iq(nq), ip(np))
    iq = PACK([(i6, i6=1, N6)], qfree)
    ip = PACK([(i, i=1, NN)], free(7:N7:7))
    ! Schur complement on the free set: S = K_qq - K_qp K_pp^-1 K_pq
    DO j = 1, np
      DO i = 1, np
        kpp(i, j) = k7(7*ip(i), 7*ip(j))
      END DO
      DO i = 1, nq
        kpq(j, i) = k7(7*ip(j), iq(i) + (iq(i) - 1)/6)
      END DO
    END DO
    x(1:np, 1:nq) = kpq(1:np, 1:nq)
    CALL spd_solve(kpp(1:np, 1:np), x(1:np, 1:nq))
    s = 0.0_wp
    DO j = 1, nq
      DO i = 1, nq
        s(iq(i), iq(j)) = k7(iq(i) + (iq(i) - 1)/6, iq(j) + (iq(j) - 1)/6) - DOT_PRODUCT(kpq(1:np, i), x(1:np, j))
      END DO
    END DO
    ! the rigid ends' basis (identity elsewhere)
    tr = 0.0_wp
    DO i = 1, N6
      tr(i, i) = 1.0_wp
    END DO
    IF (clamped) THEN
      DO iend = 1, 2
        CALL CD_EndConn_Basis(model%endconn_d0(:, iend), basis, es, em)
        b0 = 6*(MERGE(1, NN, iend == 1) - 1) + 3
        tr(b0 + 1:b0 + 3, b0 + 1:b0 + 3) = basis
      END DO
    END IF
    ! the condensed static tangent in the same coordinates
    CALL condensed(model, q, kc, g0, kel)
    kc = MATMUL(TRANSPOSE(tr), MATMUL(kc, tr))
    kel = MATMUL(TRANSPOSE(tr), MATMUL(kel, tr))
    scale = 0.0_wp
    err_a = 0.0_wp
    old_err = 0.0_wp
    DO j = 1, nq
      DO i = 1, nq
        scale = MAX(scale, ABS(kc(iq(i), iq(j))))
        err_a = MAX(err_a, ABS(s(iq(i), iq(j)) - kc(iq(i), iq(j))))
        old_err = MAX(old_err, ABS(kel(iq(i), iq(j)) - kc(iq(i), iq(j))))
      END DO
    END DO
    err_a = err_a/scale
    ! central differences of the condensed residual along a pseudo-random free direction
    seed = 4242
    dl = 0.0_wp
    DO i = 1, nq
      seed = MOD(69069*seed + 1, 2147483647)
      dl(iq(i)) = REAL(MOD(seed, 2001) - 1000, wp)/1000.0_wp
    END DO
    dq = MATMUL(tr, dl)
    h = 1.0e-6_wp
    CALL condensed_residual(model, q + h*dq, gp)
    CALL condensed_residual(model, q - h*dq, gm)
    fd = MATMUL(TRANSPOSE(tr), (gp - gm)/(2.0_wp*h))
    sd = MATMUL(s, dl)
    err_f = 0.0_wp
    DO i = 1, nq
      err_f = MAX(err_f, ABS(fd(iq(i)) - sd(iq(i))))
    END DO
    err_f = err_f/MAX(nan_max_abs(sd), TINY(1.0_wp))
    WRITE (*, '(A,A,A,F9.4,A,ES9.2,A,ES9.2,A,ES9.2)') '  C2 ', label, ': torque ', model%torsion%torque, &
      ' N m; Schur complement against the condensed tangent ', err_a, ', against central differences ', err_f, &
      '; old route (no twist) ', old_err/scale
    CALL require(err_a <= 1.0e-9_wp, 'C2 '//label//': Schur complement against the condensed static tangent')
    CALL require(err_f <= 1.0e-6_wp, 'C2 '//label//': Schur complement against the condensed residual')
    CALL CD_HermiteCable_Dyn_End(model)
  END SUBROUTINE gate_c2

  SUBROUTINE gate_e()
    !! E: finite bending springs k at both ends, between pinned and clamped.
    INTEGER, PARAMETER :: NE = 40, NK = 4
    REAL(wp), PARAMETER :: EA = 1.0e4_wp
    REAL(wp), PARAMETER :: KS(NK) = [1.0e-1_wp, 1.0e1_wp, 1.0e3_wp, 1.0e5_wp]*EI/L0
    TYPE(CD_HermiteCableDynType) :: mp, mc, mk
    REAL(wp), ALLOCATABLE :: om(:), pol(:)
    REAL(wp) :: q(6*(NE + 1)), w_pin, w_clamp, w_prev
    INTEGER :: nf, i, es
    CHARACTER(512) :: em
    LOGICAL :: ordered
    CALL straight(NE, 1.0_wp + TENSION/EA, q)
    CALL build(mp, NE, q, EA, .FALSE., .FALSE., 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp)
    CALL build(mc, NE, q, EA, .TRUE., .FALSE., 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp)
    CALL modes(mp, 2, om, pol, nf, 'E pinned')
    w_pin = om(1)
    CALL modes(mc, 2, om, pol, nf, 'E clamped')
    w_clamp = om(1)
    w_prev = w_pin
    ordered = .TRUE.
    DO i = 1, NK
      CALL build(mk, NE, q, EA, .FALSE., .FALSE., 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp)
      CALL CD_HermiteCable_Dyn_Set_EndConnection(mk, [KS(i), KS(i)], &
                                                 RESHAPE([1.0_wp, 0.0_wp, 0.0_wp, 1.0_wp, 0.0_wp, 0.0_wp], [3, 2]), &
                                                 es, em, connection_mode=[CD_ENDCONN_FINITE, CD_ENDCONN_FINITE])
      CALL require(es == CD_HCDYN_OK, 'E: finite end connections: '//TRIM(em))
      CALL modes(mk, 2, om, pol, nf, 'E finite')
      WRITE (*, '(A,ES9.2,A,F10.6,A,F10.6,A,F10.6,A)') '  E end springs k L0/EI = ', KS(i)*L0/EI, ': omega_1 ', &
        om(1), ' (pinned ', w_pin, ', clamped ', w_clamp, ')'
      ordered = ordered .AND. om(1) > w_prev .AND. om(1) < w_clamp
      w_prev = om(1)
      CALL CD_HermiteCable_Dyn_End(mk)
    END DO
    CALL require(ordered, 'E: the end springs put the frequency between pinned and clamped, rising with k')
    CALL require(ABS(w_prev/w_clamp - 1.0_wp) <= 1.0e-4_wp, 'E: a stiff end spring approaches the clamp')
    CALL CD_HermiteCable_Dyn_End(mp)
    CALL CD_HermiteCable_Dyn_End(mc)
  END SUBROUTINE gate_e

  SUBROUTINE condensed(model, qc, kc, mt, kel)
    !! The condensed static tangent at qc: the element Hessians (kel) + M_t d2(-Theta)/dq2 +
    !! (1/C) g g^T, M_t = (Phi - Theta)/C (Theta unwrapped against the model's accepted value).
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: qc(:)
    REAL(wp), INTENT(OUT) :: kc(:, :), mt, kel(:, :)
    REAL(wp) :: ee, fe(12), ke(12, 12), raw, th, c, g(SIZE(qc)), hb(2*CD_HTORS_KBAND + 1, SIZE(qc))
    INTEGER :: e, es, i, j, n
    CHARACTER(512) :: em
    n = SIZE(qc)
    kc = 0.0_wp
    DO e = 1, model%ne
      CALL CD_HermiteCable_Element(qc(6*e - 5:6*e + 6), model%l0(e), model%EA(e), model%EI(e), ee, fe, ke, es, em)
      kc(6*e - 5:6*e + 6, 6*e - 5:6*e + 6) = kc(6*e - 5:6*e + 6, 6*e - 5:6*e + 6) + ke
    END DO
    hb = 0.0_wp
    IF (ALLOCATED(model%torsion%couple)) THEN
      CALL CD_HermiteTorsion_Line(qc, model%l0, model%torsion%ends, raw, g, es, em, hband=hb, &
                                  couple=model%torsion%couple)
    ELSE
      CALL CD_HermiteTorsion_Line(qc, model%l0, model%torsion%ends, raw, g, es, em, hband=hb)
    END IF
    CALL require(es == CD_HTORS_OK, 'C2: condensed twist: '//TRIM(em))
    kel = kc
    th = CD_HermiteTorsion_Unwrap(raw, model%torsion%theta)
    c = CD_HermiteTorsion_Compliance(model%torsion, model%l0)
    mt = (model%torsion%phi - th)/c
    DO j = 1, n
      DO i = MAX(1, j - CD_HTORS_KBAND), MIN(n, j + CD_HTORS_KBAND)
        kc(i, j) = kc(i, j) - mt*hb(CD_HTORS_KBAND + 1 + i - j, j)
      END DO
      kc(:, j) = kc(:, j) + g*g(j)/c
    END DO
  END SUBROUTINE condensed

  SUBROUTINE condensed_residual(model, qc, r)
    !! The condensed static residual (no external load): sum_e f_int - M_t dTheta/dq.
    TYPE(CD_HermiteCableDynType), INTENT(IN) :: model
    REAL(wp), INTENT(IN) :: qc(:)
    REAL(wp), INTENT(OUT) :: r(:)
    REAL(wp) :: ee, fe(12), raw, th, c, g(SIZE(qc))
    INTEGER :: e, es
    CHARACTER(512) :: em
    r = 0.0_wp
    DO e = 1, model%ne
      CALL CD_HermiteCable_Element(qc(6*e - 5:6*e + 6), model%l0(e), model%EA(e), model%EI(e), ee, fe, &
                                   ErrStat=es, ErrMsg=em)
      r(6*e - 5:6*e + 6) = r(6*e - 5:6*e + 6) + fe
    END DO
    IF (ALLOCATED(model%torsion%couple)) THEN
      CALL CD_HermiteTorsion_Line(qc, model%l0, model%torsion%ends, raw, g, es, em, couple=model%torsion%couple)
    ELSE
      CALL CD_HermiteTorsion_Line(qc, model%l0, model%torsion%ends, raw, g, es, em)
    END IF
    th = CD_HermiteTorsion_Unwrap(raw, model%torsion%theta)
    c = CD_HermiteTorsion_Compliance(model%torsion, model%l0)
    r = r - (model%torsion%phi - th)/c*g
  END SUBROUTINE condensed_residual

  SUBROUTINE spd_solve(a, b)
    !! b <- a^-1 b for a small symmetric positive definite a (Cholesky).
    REAL(wp), INTENT(IN) :: a(:, :)
    REAL(wp), INTENT(INOUT) :: b(:, :)
    REAL(wp) :: l(SIZE(a, 1), SIZE(a, 1))
    INTEGER :: n, i, j
    n = SIZE(a, 1)
    l = 0.0_wp
    DO j = 1, n
      l(j, j) = SQRT(a(j, j) - DOT_PRODUCT(l(j, 1:j - 1), l(j, 1:j - 1)))
      DO i = j + 1, n
        l(i, j) = (a(i, j) - DOT_PRODUCT(l(i, 1:j - 1), l(j, 1:j - 1)))/l(j, j)
      END DO
    END DO
    DO j = 1, SIZE(b, 2)
      DO i = 1, n
        b(i, j) = (b(i, j) - DOT_PRODUCT(l(i, 1:i - 1), b(1:i - 1, j)))/l(i, i)
      END DO
      DO i = n, 1, -1
        b(i, j) = (b(i, j) - DOT_PRODUCT(l(i + 1:n, i), b(i + 1:n, j)))/l(i, i)
      END DO
    END DO
  END SUBROUTINE spd_solve

END PROGRAM test_modal_torsion
