! SPDX-License-Identifier: Apache-2.0
!
! cabctrl_discon.f90 -- a minimal Bladed-style ServoDyn controller DLL that
! commands ONLY the mooring cable-control channels with a deterministic,
! closed-form DeltaL(t) / DeltaLdot(t) schedule. It ignores every sensor input
! and every other control group (pitch, torque, yaw, HSS brake), so ServoDyn's
! own models handle those while this DLL supplies an identical active-tension
! command to whichever mooring module is active.
!
! Purpose: the CableDyn (CompMooring = 5) vs stock MoorDyn (CompMooring = 3)
! end-to-end active-tension A/B. Both runs load THIS DLL through ServoDyn, so
! the cable-control command is bit-identical between the two mooring solvers and
! any difference in the controlled line's tension response is attributable to the
! mooring module alone.
!
! avrSWAP layout used (ServoDyn BladedInterface_EX, cable block base 2601):
!   avrSWAP(2)    = current simulation time t (s)        [read]
!   avrSWAP(65)   = number of DLL logging channels        [write, 0]
!   avrSWAP(2601) = cable control channel 1 -- DeltaL     [write, m]
!   avrSWAP(2602) = cable control channel 1 -- DeltaLdot  [write, m/s]
! (ServoDyn reads records 2601/2602 back only because CCmode = 5; the pitch/
! torque/yaw records are ignored while those modes are not DLL-driven.)
!
! Schedule (fully C1 -- DeltaL and DeltaLdot continuous, both zero at every
! hold, so there is no velocity jump for either mooring solver to ring on):
!   t < T1              DeltaL = 0
!   T1 <= t < T2        pay out   0  -> A  via a smoothstep
!   T2 <= t < T3        hold A
!   T3 <= t < T4        haul in   A  -> B  via a smoothstep
!   t >= T4             hold B
! Positive DeltaL lengthens the fairlead-side segment (pays line out -> lower
! tension); negative DeltaL shortens it (hauls in -> higher tension). Both
! mooring modules apply l(N) = UnstrLen/N + DeltaL to the last segment.

SUBROUTINE DISCON(avrSWAP, aviFAIL, accINFILE, avcOUTNAME, avcMSG) BIND(C, NAME='DISCON')
  USE, INTRINSIC :: ISO_C_BINDING
  IMPLICIT NONE

  REAL(C_FLOAT), INTENT(INOUT) :: avrSWAP(*)
  INTEGER(C_INT), INTENT(INOUT) :: aviFAIL
  CHARACTER(KIND=C_CHAR), INTENT(IN)    :: accINFILE(*)
  CHARACTER(KIND=C_CHAR), INTENT(IN)    :: avcOUTNAME(*)
  CHARACTER(KIND=C_CHAR), INTENT(INOUT) :: avcMSG(*)

  ! Schedule constants (double precision internally; the swap array is single).
  REAL(C_DOUBLE), PARAMETER :: T1 = 40.0_C_DOUBLE, T2 = 100.0_C_DOUBLE
  REAL(C_DOUBLE), PARAMETER :: T3 = 160.0_C_DOUBLE, T4 = 220.0_C_DOUBLE
  REAL(C_DOUBLE), PARAMETER :: A_PAYOUT = 2.0_C_DOUBLE   ! m, pay out (lower tension)
  REAL(C_DOUBLE), PARAMETER :: B_HAULIN = -1.0_C_DOUBLE  ! m, haul in past baseline

  REAL(C_DOUBLE) :: t, dl, dld

  ! Silence unused-argument warnings; this controller consumes no file input.
  IF (.FALSE.) THEN
    IF (accINFILE(1) == C_NULL_CHAR .AND. avcOUTNAME(1) == C_NULL_CHAR) CONTINUE
  END IF

  aviFAIL = 0
  avcMSG(1) = C_NULL_CHAR

  t = REAL(avrSWAP(2), C_DOUBLE)

  CALL schedule(t, dl, dld)

  avrSWAP(65) = 0.0_C_FLOAT       ! no logging channels returned
  avrSWAP(2601) = REAL(dl, C_FLOAT)
  avrSWAP(2602) = REAL(dld, C_FLOAT)

CONTAINS

  !> Closed-form DeltaL(t) and its exact time derivative DeltaLdot(t).
  SUBROUTINE schedule(tt, deltal, deltaldot)
    REAL(C_DOUBLE), INTENT(IN)  :: tt
    REAL(C_DOUBLE), INTENT(OUT) :: deltal, deltaldot
    REAL(C_DOUBLE) :: x, span

    IF (tt < T1) THEN
      deltal = 0.0_C_DOUBLE
      deltaldot = 0.0_C_DOUBLE
    ELSE IF (tt < T2) THEN
      span = T2 - T1
      x = (tt - T1)/span
      deltal = A_PAYOUT*smoothstep(x)
      deltaldot = A_PAYOUT*smoothstep_deriv(x)/span
    ELSE IF (tt < T3) THEN
      deltal = A_PAYOUT
      deltaldot = 0.0_C_DOUBLE
    ELSE IF (tt < T4) THEN
      span = T4 - T3
      x = (tt - T3)/span
      deltal = A_PAYOUT + (B_HAULIN - A_PAYOUT)*smoothstep(x)
      deltaldot = (B_HAULIN - A_PAYOUT)*smoothstep_deriv(x)/span
    ELSE
      deltal = B_HAULIN
      deltaldot = 0.0_C_DOUBLE
    END IF
  END SUBROUTINE schedule

  !> Hermite smoothstep 3x^2 - 2x^3 on [0,1]; S(0)=0, S(1)=1, S'(0)=S'(1)=0.
  PURE REAL(C_DOUBLE) FUNCTION smoothstep(x) RESULT(s)
    REAL(C_DOUBLE), INTENT(IN) :: x
    s = x*x*(3.0_C_DOUBLE - 2.0_C_DOUBLE*x)
  END FUNCTION smoothstep

  !> d/dx of the smoothstep: 6x - 6x^2.
  PURE REAL(C_DOUBLE) FUNCTION smoothstep_deriv(x) RESULT(d)
    REAL(C_DOUBLE), INTENT(IN) :: x
    d = 6.0_C_DOUBLE*x*(1.0_C_DOUBLE - x)
  END FUNCTION smoothstep_deriv

END SUBROUTINE DISCON
