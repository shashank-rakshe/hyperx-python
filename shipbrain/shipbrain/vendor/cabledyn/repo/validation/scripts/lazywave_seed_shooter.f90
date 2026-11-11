! File: validation/scripts/lazywave_seed_shooter.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
!
! Provenance tool (NOT built by CMake): regenerates the committed suspended-span seeds
! tests/data/{gomex80,gomaine200,humboldt}_lazywave_seed.xyz used by the l3_lazywave_curvature
! gate for the three Lozon et al. (2025) lazy-wave power cables (80 / 200 / 800 m). OrcaFlex
! line-statics "step 1" piecewise-catenary shape (buoyancy-aware, flat seabed, no bending), shot
! on (H = horizontal tension, Lg = grounded length) with buoyancy continuation. The finite-EI
! Hermite static solve then adds bending via its own EI + buoyancy load continuation; only the
! converged solution is scored. Run from the repository root with no arguments: for each site it
! shoots the shape and VERIFIES it against the committed tests/data/ seed. An exact match (within a
! 1e-5 m node tolerance) leaves the committed file untouched and reports "verified"; any difference
! (a numerical regression or an intentional geometry change) writes a <seed>.new file and the tool
! aborts with a non-zero status -- it never silently clobbers a committed seed. To adopt a new
! geometry, run it, review the .new files, and promote them by hand.
PROGRAM lazywave_seed_shooter
  !! Generalized lazy-wave suspended-span seed shooter for the three reference-platform dynamic
  !! power cables. Marches from the touchdown (V=0, natural tangential liftoff) up to the hang-off
  !! and solves so the top lands on the hang-off point. No hand tuning, no bending -- the OrcaFlex
  !! step-1 idea, per site.
  USE CableDyn_Precision, ONLY: wp
  IMPLICIT NONE

  REAL(wp), PARAMETER :: RHO = 1025.0_wp, G = 9.80665_wp, EA = 4.69e8_wp
  REAL(wp), PARAMETER :: BARE_MASS = 36.7_wp, BARE_OD = 0.16_wp, PI = 3.141592653589793_wp
  INTEGER, PARAMETER :: NSUS = 240

  ! --- three sites (top-bare / buoy / bottom-bare; no local hang-off accessory is represented) ---
  INTEGER, PARAMETER :: NSITE = 3
  CHARACTER(32) :: names(NSITE) = [CHARACTER(32) :: 'gomex80', 'gomaine200', 'humboldt']
  REAL(wp) :: ltops(NSITE) = [68.114_wp, 171.978_wp, 372.449_wp]
  REAL(wp) :: lbuoys(NSITE) = [50.0_wp, 60.0_wp, 400.0_wp]
  REAL(wp) :: lbots(NSITE) = [52.101_wp, 121.527_wp, 597.981_wp]
  REAL(wp) :: sxs(NSITE) = [120.0_wp, 200.0_wp, 800.0_wp]         ! anchor horizontal span (m)
  REAL(wp) :: dds(NSITE) = [66.0_wp, 186.0_wp, 786.0_wp]          ! depth below the hang-off (m)
  REAL(wp) :: bods(NSITE) = [0.29_wp, 0.30_wp, 0.29_wp]
  REAL(wp) :: bmass(NSITE) = [59.53_wp, 60.85_wp, 59.17_wp]
  REAL(wp) :: lg0(NSITE) = [68.0_wp, 141.0_wp, 500.0_wp]          ! initial grounded-length guess
  ! seed-shape buoyancy [N/m]: 0 => use the true submerged buoy weight. The 800 m EI=0 shoot cannot
  ! fully arch at the true -83.7 N/m (stalls at lambda~0.84); a milder -60 N/m seed reaches lambda~1
  ! for a fuller starting arch. The finite-EI solve then applies the TRUE weight, so this sets only
  ! the STARTING shape (and the fixed touchdown location), never the scored physics.
  REAL(wp) :: seedbuoy(NSITE) = [0.0_wp, 0.0_wp, -60.0_wp]

  ! per-site host-associated state read by the CONTAINS routines
  REAL(wp) :: L_TOP, L_BUOY, L_BOT, SX, D, Ltot, bare_w, buoy_w, buoy_now
  INTEGER :: isite
  REAL(wp) :: H, Lg, xtop, ztop
  LOGICAL :: ok, any_mismatch

  bare_w = (BARE_MASS - RHO*(PI/4.0_wp)*BARE_OD**2)*G
  any_mismatch = .FALSE.
  WRITE (*, '(A,F7.2,A)') 'bare submerged weight = ', bare_w, ' N/m'

  DO isite = 1, NSITE
    L_TOP = ltops(isite); L_BUOY = lbuoys(isite); L_BOT = lbots(isite)
    SX = sxs(isite); D = dds(isite); Ltot = L_TOP + L_BUOY + L_BOT
    buoy_w = (bmass(isite) - RHO*(PI/4.0_wp)*bods(isite)**2)*G
    IF (seedbuoy(isite) /= 0.0_wp) buoy_w = seedbuoy(isite)   ! milder seed shape (see decl.)

    ! adaptive buoyancy continuation on the shooting solve (all-heavy seed -> buoyant arch)
    BLOCK
      REAL(wp) :: lam_cur, dlam, lam_try, Hgood, Lgood
      INTEGER :: nfail
      H = 5.0e4_wp; Lg = lg0(isite)
      buoy_now = bare_w; CALL newton2d(H, Lg, xtop, ztop, ok)
      ! Fail loudly (non-zero exit): the no-argument tool must rewrite ALL three committed seeds,
      ! so a skipped site would silently leave a seed missing/stale.
      IF (.NOT. ok) THEN
        WRITE (*, '(A)') TRIM(names(isite))//': all-heavy seed failed -- aborting seed regeneration'
        ERROR STOP 1
      END IF
      lam_cur = 0.0_wp; dlam = 0.05_wp; Hgood = H; Lgood = Lg; nfail = 0
      DO
        IF (lam_cur >= 1.0_wp) EXIT
        lam_try = MIN(1.0_wp, lam_cur + dlam)
        buoy_now = bare_w*(1.0_wp - lam_try) + buoy_w*lam_try
        H = Hgood; Lg = Lgood
        CALL newton2d(H, Lg, xtop, ztop, ok)
        IF (ok) THEN
          lam_cur = lam_try; Hgood = H; Lgood = Lg; dlam = MIN(0.1_wp, dlam*1.4_wp)
        ELSE
          dlam = 0.5_wp*dlam; nfail = nfail + 1
          IF (dlam < 1.0e-5_wp) THEN
            WRITE (*, '(A,F7.4)') TRIM(names(isite))//': continuation stuck at lambda=', lam_cur; EXIT
          END IF
        END IF
      END DO
      H = Hgood; Lg = Lgood
      buoy_now = bare_w*(1.0_wp - lam_cur) + buoy_w*lam_cur
      WRITE (*, '(A,F7.4,A,I0,A)') TRIM(names(isite))//': lambda=', lam_cur, ' (', nfail, ' retries)'
    END BLOCK

    ! Verify against (never silently overwrite) the committed seed: dump_suspended compares the
    ! freshly shot shape node-by-node with the committed file and, on any mismatch, writes a
    ! .new file + flags it instead of clobbering the reference.
    CALL dump_suspended(H, Lg, 'tests/data/'//TRIM(names(isite))//'_lazywave_seed.xyz', any_mismatch)
  END DO

  ! A regenerated seed that differs from its committed counterpart is either a regression or an
  ! intentional geometry change; either way, fail closed so it cannot land silently.
  IF (any_mismatch) THEN
    WRITE (*, '(A)') 'SEED MISMATCH: one or more committed seeds differ from the shot shape (see *.new); '// &
      'review the .new files and promote them only if the change is intended -- aborting with non-zero status'
    ERROR STOP 1
  END IF

CONTAINS

  FUNCTION wsec(a_h) RESULT(ww)
    REAL(wp), INTENT(IN) :: a_h
    REAL(wp) :: ww
    IF (a_h <= L_TOP) THEN; ww = bare_w
    ELSE IF (a_h <= L_TOP + L_BUOY) THEN; ww = buoy_now
    ELSE; ww = bare_w; END IF
  END FUNCTION wsec

  SUBROUTINE shoot(Hh, Lgg, xt, zt)
    REAL(wp), INTENT(IN) :: Hh, Lgg
    REAL(wp), INTENT(OUT) :: xt, zt
    INTEGER, PARAMETER :: N_INT = 1200
    REAL(wp) :: V, x, z, Vmid, Tel, len, th, x_td, Lsus, ds, s, a_h, wk
    INTEGER :: k
    Lsus = Ltot - Lgg; ds = Lsus/REAL(N_INT, wp)
    x_td = SX - Lgg*(1.0_wp + Hh/EA)
    x = x_td; z = -D; V = 0.0_wp
    DO k = 1, N_INT
      s = (REAL(k, wp) - 0.5_wp)*ds; a_h = Ltot - Lgg - s; wk = wsec(a_h)
      Vmid = V + 0.5_wp*wk*ds; Tel = SQRT(Hh*Hh + Vmid*Vmid)
      len = ds*(1.0_wp + Tel/EA); th = ATAN2(Vmid, Hh)
      x = x - len*COS(th); z = z + len*SIN(th); V = V + wk*ds
    END DO
    xt = x; zt = z
  END SUBROUTINE shoot

  SUBROUTINE newton2d(Hh, Lgg, xt, zt, ok_)
    REAL(wp), INTENT(INOUT) :: Hh, Lgg
    REAL(wp), INTENT(OUT) :: xt, zt
    LOGICAL, INTENT(OUT) :: ok_
    REAL(wp) :: r1, r2, j11, j12, j21, j22, det, dH, dL, x2, z2, dh_, dl_, nrm, nrm0, damp
    REAL(wp) :: Hbest, Lbest, nbest
    INTEGER :: it2
    ok_ = .FALSE.; Hbest = Hh; Lbest = Lgg; nbest = HUGE(1.0_wp)
    DO it2 = 1, 300
      CALL shoot(Hh, Lgg, xt, zt); r1 = xt; r2 = zt
      nrm = SQRT(r1*r1 + r2*r2)
      IF (nrm < nbest) THEN; nbest = nrm; Hbest = Hh; Lbest = Lgg; END IF
      IF (nrm < 1.0_wp) THEN; ok_ = .TRUE.; RETURN; END IF
      dh_ = 1.0e-3_wp*Hh; dl_ = 0.2_wp
      BLOCK
        REAL(wp) :: xa, za, xb, zb
        CALL shoot(Hh + dh_, Lgg, xa, za); CALL shoot(Hh - dh_, Lgg, xb, zb)
        j11 = (xa - xb)/(2.0_wp*dh_); j21 = (za - zb)/(2.0_wp*dh_)
        CALL shoot(Hh, Lgg + dl_, xa, za); CALL shoot(Hh, Lgg - dl_, xb, zb)
        j12 = (xa - xb)/(2.0_wp*dl_); j22 = (za - zb)/(2.0_wp*dl_)
      END BLOCK
      det = j11*j22 - j12*j21
      IF (ABS(det) < 1.0e-30_wp) RETURN
      dH = -(j22*r1 - j12*r2)/det; dL = -(-j21*r1 + j11*r2)/det
      damp = 1.0_wp; nrm0 = nrm
      DO
        IF (Hh + damp*dH > 1.0_wp .AND. Lgg + damp*dL > 0.0_wp .AND. Lgg + damp*dL < Ltot) THEN
          CALL shoot(Hh + damp*dH, Lgg + damp*dL, x2, z2)
          IF (SQRT(x2*x2 + z2*z2) < nrm0) EXIT
        END IF
        damp = 0.5_wp*damp
        IF (damp < 1.0e-6_wp) EXIT
      END DO
      Hh = Hh + damp*dH; Lgg = Lgg + damp*dL
    END DO
    Hh = Hbest; Lgg = Lbest
  END SUBROUTINE newton2d

  !> shoot the SUSPENDED shape (hang-off node 1 .. touchdown last, NSUS+1 arc-uniform nodes) and
  !! VERIFY it against the committed seed: identical (within TOL) -> leave the reference untouched;
  !! different -> write a .new file + set `mismatch` (never clobber the committed seed silently).
  SUBROUTINE dump_suspended(Hh, Lgg, fname, mismatch)
    REAL(wp), INTENT(IN) :: Hh, Lgg
    CHARACTER(*), INTENT(IN) :: fname
    LOGICAL, INTENT(INOUT) :: mismatch
    INTEGER, PARAMETER :: N_INT = 8000
    REAL(wp), PARAMETER :: TOL = 1.0e-5_wp    ! max node discrepancy (m) accepted as byte-for-byte
    REAL(wp), PARAMETER :: TOL_L = 1.0e-3_wp  ! max suspended-arc-length (Lsus header) discrepancy (m)
    REAL(wp) :: V, x, z, Vmid, Tel, len, th, x_td, Lsus, ds, s, a_h, wk, arc_from_ho, next_node
    REAL(wp) :: xs(NSUS + 1), zs(NSUS + 1), xr, yr, zr, dum, dmax, lsus_c
    INTEGER :: k, jn, u, ios, nn_c
    LOGICAL :: exists
    Lsus = Ltot - Lgg; ds = Lsus/REAL(N_INT, wp)
    x_td = SX - Lgg*(1.0_wp + Hh/EA)
    x = x_td; z = -D; V = 0.0_wp
    jn = NSUS + 1; next_node = 0.0_wp
    xs(NSUS + 1) = x_td; zs(NSUS + 1) = -D
    DO k = 1, N_INT
      s = (REAL(k, wp) - 0.5_wp)*ds; a_h = Ltot - Lgg - s; wk = wsec(a_h)
      Vmid = V + 0.5_wp*wk*ds; Tel = SQRT(Hh*Hh + Vmid*Vmid)
      len = ds*(1.0_wp + Tel/EA); th = ATAN2(Vmid, Hh)
      x = x - len*COS(th); z = z + len*SIN(th); V = V + wk*ds
      arc_from_ho = a_h
      DO WHILE (jn >= 1)
        next_node = REAL(jn - 1, wp)/REAL(NSUS, wp)*Lsus
        IF (arc_from_ho <= next_node) THEN; xs(jn) = x; zs(jn) = z; jn = jn - 1; ELSE; EXIT; END IF
      END DO
    END DO
    xs(1) = 0.0_wp; zs(1) = 0.0_wp

    ! First generation (no committed seed yet) -> just write it.
    INQUIRE (FILE=fname, EXIST=exists)
    IF (.NOT. exists) THEN
      CALL write_seed(fname, xs, zs, Lsus)
      WRITE (*, '(A,I0,A,F9.3,A)') '  generated '//TRIM(fname)//': ', NSUS + 1, ' nodes (arc ', Lsus, ' m)'
      RETURN
    END IF

    ! Compare node-by-node with the committed seed (list-directed READ is CRLF/LF-agnostic).
    OPEN (NEWUNIT=u, FILE=fname, STATUS='OLD', ACTION='READ', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'cannot read '//fname//' -- run this tool from the repository root'
      ERROR STOP 1
    END IF
    READ (u, *, IOSTAT=ios) nn_c, lsus_c          ! header: node count + suspended arc length (used by L3)
    IF (ios == 0) READ (u, *, IOSTAT=ios) dum, dum
    dmax = 0.0_wp
    DO k = 1, NSUS + 1
      IF (ios /= 0) THEN; dmax = HUGE(1.0_wp); EXIT; END IF
      READ (u, *, IOSTAT=ios) xr, yr, zr
      ! the L3 gate reads all three columns; the shot shape is planar so y must stay 0
      IF (ios == 0) dmax = MAX(dmax, ABS(xr - xs(k)), ABS(yr), ABS(zr - zs(k)))
    END DO
    CLOSE (u)

    ! Accept only if the node count, every node coordinate, AND the header arc length all match:
    ! the L3 gate derives l0e = Lsus/ne from that header, so a stale Lsus alone must fail too.
    IF (ios == 0 .AND. nn_c == NSUS + 1 .AND. dmax < TOL .AND. ABS(lsus_c - Lsus) < TOL_L) THEN
      WRITE (*, '(A,ES9.2,A,F10.5,A)') '  verified '//TRIM(fname)//' (node diff ', dmax, &
        ' m, arc ', lsus_c, ' m -- byte-for-byte reproducible)'
    ELSE
      CALL write_seed(fname//'.new', xs, zs, Lsus)
      WRITE (*, '(A,ES9.2,A,F10.5,A,F10.5,A)') '  MISMATCH '//TRIM(fname)//': node diff ', dmax, &
        ' m, committed arc ', lsus_c, ' vs shot ', Lsus, ' m -> wrote .new'
      mismatch = .TRUE.
    END IF
  END SUBROUTINE dump_suspended

  !> write NSUS+1 arc-uniform (x, 0, z) nodes to a seed file; abort if the path cannot be opened
  SUBROUTINE write_seed(path, xs, zs, Lsus)
    CHARACTER(*), INTENT(IN) :: path
    REAL(wp), INTENT(IN) :: xs(:), zs(:), Lsus
    INTEGER :: u, k, ios
    OPEN (NEWUNIT=u, FILE=path, STATUS='REPLACE', ACTION='WRITE', IOSTAT=ios)
    IF (ios /= 0) THEN
      WRITE (*, '(A)') 'cannot open '//path//' for writing -- run this tool from the repository root'
      ERROR STOP 1
    END IF
    WRITE (u, '(I0,1X,F12.5)') NSUS + 1, Lsus
    WRITE (u, '(2F12.5)') 0.0_wp, Lsus
    DO k = 1, NSUS + 1
      WRITE (u, '(3F14.6)') xs(k), 0.0_wp, zs(k)
    END DO
    CLOSE (u)
  END SUBROUTINE write_seed

END PROGRAM lazywave_seed_shooter
