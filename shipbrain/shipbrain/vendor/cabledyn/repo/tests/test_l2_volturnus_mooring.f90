! File: tests/test_l2_volturnus_mooring.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
PROGRAM test_l2_volturnus_mooring
  !! L2 static parity on the reference platform: one 120-deg all-chain catenary line of the
  !! IEA-15 MW reference wind turbine atop the UMaine VolturnUS-S semi-submersible, at 200 m
  !! water depth. R4 studless chain (volume-equivalent diameter 0.333 m, dry mass 685 kg/m,
  !! EA 3.270e9 N, 850 m), fairlead at radius 58 m / z = -14 m, anchor on the seabed at radius
  !! 837.6 m / z = -200 m. CableDyn solves its own independent grounded-catenary equilibrium
  !! (no external solver state enters init) and the fairlead / anchor tensions are scored
  !! against the OrcaFlex 11.6c and MoorDyn values and the closed-form catenary identity.
  USE CableDyn_Precision, ONLY: wp
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Nodal_Seabed_Stiffness
  USE CableDyn_Static, ONLY: CableSolverConfig
  USE CableDyn_Dynamic, ONLY: GenAlphaConfig
  USE CableDyn_Model, ONLY: CD_ModelType, CD_Init_Line_Model, CD_Get_Model_State, &
                            CD_Model_NDOF, CD_End_Model, CD_MODEL_OK
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension
  IMPLICIT NONE

  REAL(wp), PARAMETER :: G = 9.80665_wp, RHO = 1025.0_wp, PI = 3.141592653589793_wp
  ! VolturnUS-S line geometry (relative frame: fairlead at origin, anchor at horizontal span/-depth)
  REAL(wp), PARAMETER :: HSPAN = 779.6_wp, DEPTH = 186.0_wp, KBOT = 3.0e6_wp, LEN = 850.0_wp
  REAL(wp), PARAMETER :: EAv = 3.27e9_wp, MPL = 685.0_wp, DIAMv = 0.333_wp
  INTEGER, PARAMETER :: NSEG = 50
  ! References (kN): OrcaFlex 11.6c and MoorDyn fairlead tension; anchor = T_fl - w*h (catenary)
  REAL(wp), PARAMETER :: FAIR_ORCA = 2427.0_wp, FAIR_MOOR = 2439.0_wp
  REAL(wp), PARAMETER :: GATE = 0.03_wp    ! 3% parity band
  REAL(wp), PARAMETER :: factors(4) = [0.25_wp, 0.5_wp, 0.75_wp, 1.0_wp]

  TYPE(CD_ModelType) :: model
  TYPE(CD_LineType) :: lts(1)
  TYPE(CD_LineSection) :: secs(1)
  TYPE(CableSolverConfig) :: scfg
  TYPE(GenAlphaConfig) :: dcfg
  REAL(wp), ALLOCATABLE :: q(:), v(:), a(:), l0(:), ea(:), diam(:), kn(:), tens(:), ba_arr(:)
  INTEGER, ALLOCATABLE :: conn(:, :)
  REAL(wp) :: anchor(3), fairlead(3), fair_kn, anch_kn, wsub, anch_ref, e_orca, e_moor, e_anch
  INTEGER :: ndof, es, i, ne, nfail
  CHARACTER(240) :: em

  nfail = 0
  ne = NSEG
  anchor = [HSPAN, 0.0_wp, -DEPTH]; fairlead = [0.0_wp, 0.0_wp, 0.0_wp]
  lts(1) = CD_LineType(ea=EAv, mass_per_length=MPL, diameter=DIAMv)
  secs(1) = CD_LineSection(line_type=1, length=LEN, n_segments=NSEG)
  ALLOCATE (l0(ne), diam(ne)); l0 = LEN/REAL(ne, wp); diam = DIAMv
  CALL CD_Nodal_Seabed_Stiffness(KBOT, diam, l0, kn, es, em)
  ALLOCATE (ba_arr(ne)); ba_arr = l0*SQRT(EAv*MPL)

  scfg%max_iter = 200
  CALL CD_Init_Line_Model(model, anchor, fairlead, lts, secs, G, RHO, .TRUE., scfg, dcfg, factors, &
                          es, em, seabed_z_floor=-DEPTH, seabed_kn=kn, ba=ba_arr)
  CALL require(es == CD_MODEL_OK, 'independent static equilibrium converged: '//TRIM(em))
  IF (es == CD_MODEL_OK) THEN
    ndof = CD_Model_NDOF(model, es, em)
    ALLOCATE (q(ndof), v(ndof), a(ndof))
    CALL CD_Get_Model_State(model, q, v, a, es, em)
    ALLOCATE (conn(2, ne), ea(ne), tens(ne))
    DO i = 1, ne; conn(:, i) = [i, i + 1]; ea(i) = EAv; END DO
    CALL CD_Compute_Cable_Tension(RESHAPE(q, [3, ne + 1]), conn, l0, ea, .TRUE., tens, es, em)
    fair_kn = tens(ne)*1.0e-3_wp
    anch_kn = tens(1)*1.0e-3_wp

    ! submerged weight per length (volume-equivalent diameter buoyancy) and catenary anchor reference
    wsub = (MPL - RHO*0.25_wp*PI*DIAMv**2)*G       ! N/m
    anch_ref = FAIR_ORCA - wsub*DEPTH*1.0e-3_wp     ! kN: T_anchor = T_fairlead - w*h

    e_orca = ABS(fair_kn - FAIR_ORCA)/FAIR_ORCA
    e_moor = ABS(fair_kn - FAIR_MOOR)/FAIR_MOOR
    e_anch = ABS(anch_kn - anch_ref)/anch_ref
    WRITE (*, '(A,F8.1,A,F8.1,A)') '  [VolturnUS-S] fairlead = ', fair_kn, ' kN   anchor = ', anch_kn, ' kN'
    WRITE (*, '(A,F6.3,A,F6.3,A,F6.3,A)') '  fairlead err vs OrcaFlex ', 100*e_orca, '% / MoorDyn ', &
      100*e_moor, '% ; anchor vs catenary H ', 100*e_anch, '%'
    CALL require(e_orca < GATE, 'fairlead tension within 3% of OrcaFlex 11.6c')
    CALL require(e_moor < GATE, 'fairlead tension within 3% of MoorDyn')
    CALL require(e_anch < GATE, 'anchor tension within 3% of the closed-form catenary horizontal force')
  END IF

  CALL finish()

CONTAINS

  SUBROUTINE finish()
    INTEGER :: es2
    CHARACTER(240) :: em2
    CALL CD_End_Model(model, es2, em2)
    IF (nfail > 0) THEN
      WRITE (*, '(A,I0,A)') 'FAIL: ', nfail, ' assertion(s) failed'
      ERROR STOP 1
    END IF
    WRITE (*, '(A)') 'PASS: IEA-15MW VolturnUS-S catenary mooring static parity'
  END SUBROUTINE finish

  SUBROUTINE require(cond, label)
    LOGICAL, INTENT(IN) :: cond
    CHARACTER(*), INTENT(IN) :: label
    IF (.NOT. cond) THEN
      WRITE (*, '(A,A)') 'MISMATCH: ', label
      nfail = nfail + 1
    END IF
  END SUBROUTINE require

END PROGRAM test_l2_volturnus_mooring
