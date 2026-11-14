! File: src/CableDyn_RangeOutput.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_RangeOutput
  !! Along-arc range graphs and touchdown-point (TDP) channels of the deck driver.
  !!
  !! A route samples a line at an output row by filling the line's scratch arrays in
  !! public node order (End A -> End B): positions r(3, nn) in the global frame and the
  !! node values of the Ten, Curv, BendMom and L<L>N<J>Dec channels (and, on a line with
  !! condensed torsion, of Torq<L>N<J> and Twist<L>N<J>). This module then
  !! adds the seabed clearance, keeps the range envelopes (minimum, maximum and running
  !! sum per node, allocation-free after setup) and evaluates the touchdown point.
  !!
  !! The touchdown point follows cabledyn.touchdown_history: a node is grounded when its
  !! centreline is at most CD_SEABED_CONTACT_BLEND above the seabed (the height at which
  !! the normal contact law activates). The grounded end is the end grounded in the
  !! initial state; walking from it, the TDP lies between the last grounded node and the
  !! next one, where the parabola through the last grounded node and the next two (clearance
  !! against chord arc), its curvature limited so that it rises monotonically over the
  !! element, crosses that height; it reaches a node exactly when the node does, from either
  !! side, so the TDP moves continuously as nodes ground
  !! and lift off (linear clearance when there is no such crossing). The TDP sits on that
  !! height. Arc length is the deformed chord
  !! length from End A, layback the horizontal distance from the TDP to the suspended end,
  !! the excursion the horizontal TDP displacement from its initial position projected
  !! on the initial horizontal direction from the TDP to the suspended end, and the grounded
  !! length the deformed chord length from the grounded end to the TDP (0 while no node
  !! beyond the grounded end node is grounded).
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE
  USE CableDyn_PathIO, ONLY: CD_Open_Write, CD_Path_Openable
  USE CableDyn_Bathymetry, ONLY: CD_BathymetryType, CD_Bathymetry_Floor, CD_Bathymetry_Is_Initialized, &
                                 CD_BATHY_OK
  USE CableDyn_SeabedContact, ONLY: CD_SEABED_CONTACT_BLEND
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_RangeLine, CD_RangeSet
  PUBLIC :: CD_Range_Setup, CD_Range_End, CD_Range_Needs_Sample, CD_Range_Commit_Sample
  PUBLIC :: CD_Range_Clearance, CD_Range_TDP_Evaluate, CD_Range_TDP_Reference
  PUBLIC :: CD_Range_Write_Files, CD_Range_Discard_Files, CD_Range_Discard_File
  PUBLIC :: CD_Range_Has_Graph, CD_Range_Mirror_Size, CD_Range_Get_State, CD_Range_Set_State
  PUBLIC :: CD_Is_TDP_Channel, CD_Parse_TDP_Channel

  INTEGER, PARAMETER, PUBLIC :: CD_RANGE_OK = 0, CD_RANGE_BADINPUT = 1, CD_RANGE_SOLVEFAIL = 2
  ! Node quantities of a sample (rows of CD_RangeLine%val).
  INTEGER, PARAMETER, PUBLIC :: CD_RQ_TENSION = 1, CD_RQ_CURVATURE = 2, CD_RQ_BEND = 3, &
                                CD_RQ_DECLINATION = 4, CD_RQ_CLEARANCE = 5, CD_RQ_TORQUE = 6, CD_RQ_TWIST = 7, &
                                CD_RQ_N = 7
  ! Components of the TDP channels (TDP<L>s, x, y, z, Lay, Exc, Grd).
  INTEGER, PARAMETER, PUBLIC :: CD_TDP_S = 1, CD_TDP_X = 2, CD_TDP_Y = 3, CD_TDP_Z = 4, CD_TDP_LAY = 5, &
                                CD_TDP_EXC = 6, CD_TDP_GRD = 7, CD_TDP_N = 7

  ! Leading reals of a line in CD_Range_Get_State: sample count, t_first, t_last, arc-ready flag.
  INTEGER, PARAMETER :: RANGE_MIRROR_HEAD = 4

  TYPE :: CD_RangeLine
    INTEGER :: line_id = 0
    INTEGER :: nn = 0
    LOGICAL :: want_range = .FALSE.
    LOGICAL :: want_tdp = .FALSE.
    ! The line carries condensed torsion: the route also fills the torque and twist rows, and
    ! the range file gets their columns (zero rows otherwise, and no columns).
    LOGICAL :: has_torsion = .FALSE.
    ! Sample scratch filled by the route (public order End A -> End B).
    REAL(wp), ALLOCATABLE :: r(:, :)          ! (3, nn) global node positions
    REAL(wp), ALLOCATABLE :: val(:, :)        ! (CD_RQ_N, nn) node values
    ! Route scratch for state queries (sized for the widest state, 6 reals per node).
    REAL(wp), ALLOCATABLE :: qs(:), vs(:), as(:), ten_e(:)
    ! Envelopes over the window.
    REAL(wp), ALLOCATABLE :: arc(:)           ! (nn) deformed chord arc at the first sample
    REAL(wp), ALLOCATABLE :: vmin(:, :), vmax(:, :), vsum(:, :)
    LOGICAL :: arc_ready = .FALSE.
    INTEGER :: nsample = 0
    REAL(wp) :: t_first = CD_ZERO, t_last = CD_ZERO
    ! Touchdown reference, fixed at the first (initial-state) evaluation.
    LOGICAL :: tdp_ready = .FALSE.
    INTEGER :: tdp_end = 0                    ! 1 = End A grounded, 2 = End B grounded
    REAL(wp) :: ref_arc = CD_ZERO, ref_xy(2) = CD_ZERO, ref_dir(2) = CD_ZERO
    REAL(wp) :: tdp(CD_TDP_N) = CD_ZERO       ! latest evaluation
  END TYPE CD_RangeLine

  TYPE :: CD_RangeSet
    LOGICAL :: active = .FALSE.               ! some line wants a range file or a TDP channel
    REAL(wp) :: t_start = CD_ZERO             ! range window start [s]
    LOGICAL :: has_floor = .FALSE.
    LOGICAL :: has_bathymetry = .FALSE.
    REAL(wp) :: z_floor = CD_ZERO
    TYPE(CD_BathymetryType) :: bathymetry
    TYPE(CD_RangeLine), ALLOCATABLE :: lines(:)   ! deck line order
  END TYPE CD_RangeSet

CONTAINS

  SUBROUTINE CD_Range_Setup(set, line_ids, nnodes, want_range, want_tdp, t_start, has_floor, z_floor, &
                            ErrStat, ErrMsg, bathymetry)
    !! Size the range set once, before the first sample. `line_ids`, `nnodes` and the
    !! request flags are in deck line order. The seabed is structured `bathymetry` when it
    !! is initialized, otherwise the flat floor z_floor when has_floor.
    TYPE(CD_RangeSet), INTENT(INOUT) :: set
    INTEGER, INTENT(IN) :: line_ids(:), nnodes(:)
    LOGICAL, INTENT(IN) :: want_range(:), want_tdp(:)
    REAL(wp), INTENT(IN) :: t_start, z_floor
    LOGICAL, INTENT(IN) :: has_floor
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    TYPE(CD_BathymetryType), INTENT(IN), OPTIONAL :: bathymetry
    INTEGER :: il, nn, nl, istat
    LOGICAL :: bathy_ready

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    CALL CD_Range_End(set)
    nl = SIZE(line_ids)
    IF (SIZE(nnodes) /= nl .OR. SIZE(want_range) /= nl .OR. SIZE(want_tdp) /= nl) THEN
      ErrStat = CD_RANGE_BADINPUT
      ErrMsg = 'CableDyn_RangeOutput: setup arrays differ in length'
      RETURN
    END IF
    set%t_start = t_start
    bathy_ready = .FALSE.
    IF (PRESENT(bathymetry)) bathy_ready = CD_Bathymetry_Is_Initialized(bathymetry)
    IF (bathy_ready) THEN
      set%bathymetry = bathymetry
      set%has_bathymetry = .TRUE.
      set%has_floor = .TRUE.
    ELSE
      set%has_floor = has_floor
      set%z_floor = z_floor
    END IF
    ALLOCATE (set%lines(nl), STAT=istat)
    IF (istat /= 0) GOTO 900
    DO il = 1, nl
      set%lines(il)%line_id = line_ids(il)
      set%lines(il)%want_range = want_range(il)
      set%lines(il)%want_tdp = want_tdp(il)
      IF (.NOT. (want_range(il) .OR. want_tdp(il))) CYCLE
      nn = nnodes(il)
      IF (nn < 2) THEN
        ErrStat = CD_RANGE_BADINPUT
        BLOCK
          ! Local buffer: a record longer than the caller's ErrMsg truncates
          ! instead of aborting the internal write.
          CHARACTER(1024) :: wmsg
          INTEGER :: wios
          wmsg = ''
          WRITE (wmsg, '(A,I0,A)', IOSTAT=wios) 'CableDyn_RangeOutput: line ', line_ids(il), &
            ' has fewer than two nodes for range or touchdown output'
          ErrMsg = wmsg
        END BLOCK
        RETURN
      END IF
      IF (want_tdp(il) .AND. .NOT. set%has_floor) THEN
        ErrStat = CD_RANGE_BADINPUT
        BLOCK
          ! Local buffer: a record longer than the caller's ErrMsg truncates
          ! instead of aborting the internal write.
          CHARACTER(1024) :: wmsg
          INTEGER :: wios
          wmsg = ''
          WRITE (wmsg, '(A,I0,A)', IOSTAT=wios) 'CableDyn_RangeOutput: TDP channels of line ', line_ids(il), &
            ' need a seabed (WtrDpth or a bathymetry file)'
          ErrMsg = wmsg
        END BLOCK
        RETURN
      END IF
      set%lines(il)%nn = nn
      ALLOCATE (set%lines(il)%r(3, nn), set%lines(il)%val(CD_RQ_N, nn), set%lines(il)%qs(6*nn), &
                set%lines(il)%vs(6*nn), set%lines(il)%as(6*nn), set%lines(il)%ten_e(nn - 1), &
                set%lines(il)%arc(nn), set%lines(il)%vmin(CD_RQ_N, nn), set%lines(il)%vmax(CD_RQ_N, nn), &
                set%lines(il)%vsum(CD_RQ_N, nn), STAT=istat)
      IF (istat /= 0) GOTO 900
      set%lines(il)%r = CD_ZERO
      set%lines(il)%val = CD_ZERO
      set%lines(il)%arc = CD_ZERO
      set%lines(il)%vmin = HUGE(CD_ONE)
      set%lines(il)%vmax = -HUGE(CD_ONE)
      set%lines(il)%vsum = CD_ZERO
      set%active = .TRUE.
    END DO
    RETURN
900 ErrStat = CD_RANGE_SOLVEFAIL
    ErrMsg = 'CableDyn_RangeOutput: cannot allocate the range-graph workspace'
    CALL CD_Range_End(set)
  END SUBROUTINE CD_Range_Setup

  SUBROUTINE CD_Range_End(set)
    TYPE(CD_RangeSet), INTENT(INOUT) :: set
    TYPE(CD_RangeSet) :: empty
    set = empty
  END SUBROUTINE CD_Range_End

  PURE LOGICAL FUNCTION CD_Range_Needs_Sample(set, il) RESULT(yes)
    !! True when deck line il (array position) must be sampled at an output row.
    TYPE(CD_RangeSet), INTENT(IN) :: set
    INTEGER, INTENT(IN) :: il
    yes = .FALSE.
    IF (.NOT. set%active) RETURN
    IF (il < 1 .OR. il > SIZE(set%lines)) RETURN
    yes = set%lines(il)%want_range .OR. set%lines(il)%want_tdp
  END FUNCTION CD_Range_Needs_Sample

  PURE LOGICAL FUNCTION CD_Range_Has_Graph(set) RESULT(yes)
    !! True when some line of the set accumulates a range graph (LINES flag r), not only
    !! touchdown channels.
    TYPE(CD_RangeSet), INTENT(IN) :: set
    INTEGER :: il
    yes = .FALSE.
    IF (.NOT. set%active) RETURN
    DO il = 1, SIZE(set%lines)
      IF (set%lines(il)%want_range) yes = .TRUE.
    END DO
  END FUNCTION CD_Range_Has_Graph

  PURE INTEGER FUNCTION CD_Range_Mirror_Size(set) RESULT(n)
    !! Reals of the accumulated range graphs (CD_Range_Get_State): per line with a range file,
    !! the sample count, the first and last sample times, the arc-ready flag, the arc stations
    !! and the three envelopes.
    TYPE(CD_RangeSet), INTENT(IN) :: set
    INTEGER :: il
    n = 0
    IF (.NOT. set%active) RETURN
    DO il = 1, SIZE(set%lines)
      IF (set%lines(il)%want_range) n = n + RANGE_MIRROR_HEAD + (1 + 3*CD_RQ_N)*set%lines(il)%nn
    END DO
  END FUNCTION CD_Range_Mirror_Size

  PURE SUBROUTINE CD_Range_Get_State(set, state)
    !! Copy the accumulated range graphs into state (CD_Range_Mirror_Size reals, every one
    !! double precision whatever the host's output precision). The touchdown references and
    !! the sample scratch are not part of it: a route rebuilds them.
    TYPE(CD_RangeSet), INTENT(IN) :: set
    REAL(wp), INTENT(OUT) :: state(:)
    INTEGER :: il, j, k, nn

    k = 0
    IF (.NOT. set%active) RETURN
    DO il = 1, SIZE(set%lines)
      IF (.NOT. set%lines(il)%want_range) CYCLE
      nn = set%lines(il)%nn
      state(k + 1) = REAL(set%lines(il)%nsample, wp)
      state(k + 2) = set%lines(il)%t_first
      state(k + 3) = set%lines(il)%t_last
      state(k + 4) = MERGE(CD_ONE, CD_ZERO, set%lines(il)%arc_ready)
      k = k + RANGE_MIRROR_HEAD
      state(k + 1:k + nn) = set%lines(il)%arc
      k = k + nn
      DO j = 1, nn
        state(k + 1:k + CD_RQ_N) = set%lines(il)%vmin(:, j)
        state(k + CD_RQ_N + 1:k + 2*CD_RQ_N) = set%lines(il)%vmax(:, j)
        state(k + 2*CD_RQ_N + 1:k + 3*CD_RQ_N) = set%lines(il)%vsum(:, j)
        k = k + 3*CD_RQ_N
      END DO
    END DO
  END SUBROUTINE CD_Range_Get_State

  SUBROUTINE CD_Range_Set_State(set, state, ErrStat, ErrMsg)
    !! Reload the accumulated range graphs of CD_Range_Get_State, of a set sized alike.
    TYPE(CD_RangeSet), INTENT(INOUT) :: set
    REAL(wp), INTENT(IN) :: state(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: il, j, k, nn

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    IF (SIZE(state) /= CD_Range_Mirror_Size(set)) THEN
      ErrStat = CD_RANGE_BADINPUT
      ErrMsg = 'CableDyn_RangeOutput: the saved range graphs do not match the lines of this run'
      RETURN
    END IF
    k = 0
    IF (.NOT. set%active) RETURN
    DO il = 1, SIZE(set%lines)
      IF (.NOT. set%lines(il)%want_range) CYCLE
      nn = set%lines(il)%nn
      set%lines(il)%nsample = NINT(state(k + 1))
      set%lines(il)%t_first = state(k + 2)
      set%lines(il)%t_last = state(k + 3)
      set%lines(il)%arc_ready = state(k + 4) > CD_ZERO
      k = k + RANGE_MIRROR_HEAD
      set%lines(il)%arc = state(k + 1:k + nn)
      k = k + nn
      DO j = 1, nn
        set%lines(il)%vmin(:, j) = state(k + 1:k + CD_RQ_N)
        set%lines(il)%vmax(:, j) = state(k + CD_RQ_N + 1:k + 2*CD_RQ_N)
        set%lines(il)%vsum(:, j) = state(k + 2*CD_RQ_N + 1:k + 3*CD_RQ_N)
        k = k + 3*CD_RQ_N
      END DO
    END DO
  END SUBROUTINE CD_Range_Set_State

  SUBROUTINE CD_Range_Clearance(set, r, clearance, ErrStat, ErrMsg)
    !! Vertical centreline clearance above the seabed, z - z_floor(x, y), per node.
    TYPE(CD_RangeSet), INTENT(IN) :: set
    REAL(wp), INTENT(IN) :: r(:, :)
    REAL(wp), INTENT(OUT) :: clearance(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: j, es
    REAL(wp) :: zf
    CHARACTER(160) :: em

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    clearance = CD_ZERO
    IF (.NOT. set%has_floor) RETURN
    DO j = 1, SIZE(r, 2)
      IF (set%has_bathymetry) THEN
        CALL CD_Bathymetry_Floor(set%bathymetry, r(1, j), r(2, j), zf, es, em)
        IF (es /= CD_BATHY_OK) THEN
          ErrStat = CD_RANGE_SOLVEFAIL
          ErrMsg = 'CableDyn_RangeOutput: bathymetry floor query failed: '//TRIM(em)
          RETURN
        END IF
      ELSE
        zf = set%z_floor
      END IF
      clearance(j) = r(3, j) - zf
    END DO
  END SUBROUTINE CD_Range_Clearance

  SUBROUTINE CD_Range_Commit_Sample(set, il, time, ErrStat, ErrMsg)
    !! Close the sample of deck line il at `time`: the route has filled r and val rows
    !! 1-4. Adds the clearance, fixes the arc stations and the touchdown reference at the
    !! first sample, evaluates the touchdown point, and accumulates the envelopes when the
    !! line has a range file and `time` lies in the window.
    TYPE(CD_RangeSet), INTENT(INOUT) :: set
    INTEGER, INTENT(IN) :: il
    REAL(wp), INTENT(IN) :: time
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: j, k, nn

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    IF (.NOT. CD_Range_Needs_Sample(set, il)) RETURN
    nn = set%lines(il)%nn
    CALL CD_Range_Clearance(set, set%lines(il)%r, set%lines(il)%val(CD_RQ_CLEARANCE, :), ErrStat, ErrMsg)
    IF (ErrStat /= CD_RANGE_OK) RETURN
    DO j = 1, nn
      DO k = 1, CD_RQ_N
        IF (.NOT. IEEE_IS_FINITE(set%lines(il)%val(k, j))) THEN
          ErrStat = CD_RANGE_SOLVEFAIL
          BLOCK
            ! Local buffer: a record longer than the caller's ErrMsg truncates
            ! instead of aborting the internal write.
            CHARACTER(1024) :: wmsg
            INTEGER :: wios
            wmsg = ''
            WRITE (wmsg, '(A,I0,A,I0)', IOSTAT=wios) 'CableDyn_RangeOutput: non-finite range-graph value on line ', &
              set%lines(il)%line_id, ', node ', j
            ErrMsg = wmsg
          END BLOCK
          RETURN
        END IF
      END DO
    END DO
    IF (.NOT. set%lines(il)%arc_ready) THEN
      set%lines(il)%arc(1) = CD_ZERO
      DO j = 2, nn
        set%lines(il)%arc(j) = set%lines(il)%arc(j - 1) + NORM2(set%lines(il)%r(:, j) - set%lines(il)%r(:, j - 1))
      END DO
      set%lines(il)%arc_ready = .TRUE.
    END IF
    IF (set%lines(il)%want_tdp) THEN
      IF (.NOT. set%lines(il)%tdp_ready) THEN
        CALL CD_Range_TDP_Reference(set%lines(il), set%lines(il)%r, set%lines(il)%val(CD_RQ_CLEARANCE, :), &
                                    ErrStat, ErrMsg)
        IF (ErrStat /= CD_RANGE_OK) RETURN
      END IF
      CALL CD_Range_TDP_Evaluate(set%lines(il), set%lines(il)%r, set%lines(il)%val(CD_RQ_CLEARANCE, :), &
                                 set%lines(il)%tdp)
    END IF
    IF (.NOT. set%lines(il)%want_range) RETURN
    ! Window membership: the rows are at k*dtM, so a relative guard keeps a row that
    ! lands on the start time in the window despite rounding of k*dtM.
    IF (time < set%t_start - 1.0e-9_wp*MAX(CD_ONE, ABS(set%t_start))) RETURN
    IF (set%lines(il)%nsample == 0) set%lines(il)%t_first = time
    set%lines(il)%t_last = time
    set%lines(il)%nsample = set%lines(il)%nsample + 1
    DO j = 1, nn
      DO k = 1, CD_RQ_N
        set%lines(il)%vmin(k, j) = MIN(set%lines(il)%vmin(k, j), set%lines(il)%val(k, j))
        set%lines(il)%vmax(k, j) = MAX(set%lines(il)%vmax(k, j), set%lines(il)%val(k, j))
        set%lines(il)%vsum(k, j) = set%lines(il)%vsum(k, j) + set%lines(il)%val(k, j)
      END DO
    END DO
  END SUBROUTINE CD_Range_Commit_Sample

  PURE SUBROUTINE tdp_locate(r, clearance, grounded_end, touching, arc, point, suspended_xy, grounded)
    !! Touchdown point of one configuration for a given grounded end (1 = A, 2 = B), the
    !! algorithm of cabledyn.touchdown_history. `touching` is false when the grounded end
    !! has lifted off (the TDP is then reported at that end) or every node is grounded (the
    !! TDP is then reported at the suspended end). `grounded` is the deformed chord length
    !! from the grounded end to the TDP, so it varies continuously with the TDP: the whole
    !! line when every node is grounded, and 0 only when the grounded end node itself is off
    !! the seabed or the TDP sits at that node.
    REAL(wp), INTENT(IN) :: r(:, :), clearance(:)
    INTEGER, INTENT(IN) :: grounded_end
    LOGICAL, INTENT(OUT) :: touching
    REAL(wp), INTENT(OUT) :: arc, point(3), suspended_xy(2), grounded
    INTEGER :: nn, k, j, jn, last
    REAL(wp) :: g_low, g_high, fraction, chord, s_scan, s_total, z_floor
    LOGICAL :: grounded_first, all_grounded

    nn = SIZE(r, 2)
    ! scan order: k = 1 is the grounded end
    grounded_first = clearance(node_of(1)) <= CD_SEABED_CONTACT_BLEND
    all_grounded = .TRUE.
    last = nn
    DO k = 1, nn
      IF (.NOT. (clearance(node_of(k)) <= CD_SEABED_CONTACT_BLEND)) THEN
        all_grounded = .FALSE.
        last = k - 1
        EXIT
      END IF
    END DO
    touching = grounded_first .AND. .NOT. all_grounded
    fraction = CD_ZERO
    IF (.NOT. grounded_first) THEN
      last = 1
    ELSE IF (.NOT. all_grounded) THEN
      g_low = clearance(node_of(last)) - CD_SEABED_CONTACT_BLEND
      g_high = clearance(node_of(last + 1)) - CD_SEABED_CONTACT_BLEND
      IF (g_high > g_low) fraction = MIN(CD_ONE, MAX(CD_ZERO, -g_low/(g_high - g_low)))
      CALL quadratic_fraction(fraction)
    END IF
    s_scan = CD_ZERO
    s_total = CD_ZERO
    DO k = 1, nn - 1
      chord = NORM2(r(:, node_of(k + 1)) - r(:, node_of(k)))
      IF (k < last) s_scan = s_scan + chord
      s_total = s_total + chord
    END DO
    j = node_of(last)
    point = r(:, j)
    IF (last < nn) THEN
      jn = node_of(last + 1)
      point = r(:, j) + fraction*(r(:, jn) - r(:, j))
      s_scan = s_scan + fraction*NORM2(r(:, jn) - r(:, j))
      ! the TDP sits at the contact-onset height: floor (z - clearance) interpolated along the
      ! chord, plus the onset height
      IF (touching) THEN
        z_floor = (CD_ONE - fraction)*(r(3, j) - clearance(j)) + fraction*(r(3, jn) - clearance(jn))
        point(3) = z_floor + CD_SEABED_CONTACT_BLEND
      END IF
    END IF
    grounded = s_scan
    arc = s_scan
    IF (grounded_end == 2) arc = s_total - s_scan
    suspended_xy = r(1:2, node_of(nn))

  CONTAINS

    PURE INTEGER FUNCTION node_of(k_scan) RESULT(node)
      INTEGER, INTENT(IN) :: k_scan
      node = k_scan
      IF (grounded_end == 2) node = nn + 1 - k_scan
    END FUNCTION node_of

    PURE SUBROUTINE quadratic_fraction(f)
      !! Quadratic clearance g(x) through the last grounded node (x = 0) and the first two
      !! suspended nodes (x = l1, l1 + l2), g measured from the contact-onset height, with its
      !! curvature limited to |qa| <= d1/l1 so that it rises monotonically over the element
      !! [0, l1]; the touchdown is its crossing inside the element, which is then unique. An
      !! unlimited parabola can dip below the onset height inside the element when the line
      !! rises sharply beyond it, and its crossing then lies near the suspended node: the
      !! location jumped by almost an element when the next node grounded. The monotone
      !! crossing reaches a node exactly when that node reaches the onset height, from either
      !! side, so the location is continuous as nodes ground and lift off. Keeps f (linear) when
      !! the line has fewer than two suspended nodes or the quadratic has no crossing.
      REAL(wp), INTENT(INOUT) :: f
      REAL(wp) :: g0, g1, g2, l1, l2, d1, qa, qb, disc, x1, x2, xc
      IF (last + 2 > nn) RETURN
      g0 = clearance(node_of(last)) - CD_SEABED_CONTACT_BLEND
      g1 = clearance(node_of(last + 1)) - CD_SEABED_CONTACT_BLEND
      g2 = clearance(node_of(last + 2)) - CD_SEABED_CONTACT_BLEND
      l1 = NORM2(r(:, node_of(last + 1)) - r(:, node_of(last)))
      l2 = NORM2(r(:, node_of(last + 2)) - r(:, node_of(last + 1)))
      IF (.NOT. (l1 > CD_ZERO) .OR. .NOT. (l2 > CD_ZERO)) RETURN
      d1 = (g1 - g0)/l1
      qa = ((g2 - g1)/l2 - d1)/(l1 + l2)
      ! monotone over the element: q'(0) = d1 - qa l1 >= 0 and q'(l1) = d1 + qa l1 >= 0
      IF (d1 > CD_ZERO) qa = MAX(-d1/l1, MIN(d1/l1, qa))
      qb = d1 - qa*l1
      ! qa x^2 + qb x + g0 = 0
      IF (ABS(qa)*l1 <= 1.0e-12_wp*MAX(ABS(qb), TINY(CD_ONE))) THEN
        IF (ABS(qb) > CD_ZERO) f = MIN(CD_ONE, MAX(CD_ZERO, (-g0/qb)/l1))
        RETURN
      END IF
      disc = qb*qb - 4.0_wp*qa*g0
      IF (disc < CD_ZERO) RETURN
      ! numerically stable pair of roots
      IF (qb >= CD_ZERO) THEN
        x1 = (-qb - SQRT(disc))/(2.0_wp*qa)
      ELSE
        x1 = (-qb + SQRT(disc))/(2.0_wp*qa)
      END IF
      x2 = CD_ZERO
      IF (ABS(x1) > CD_ZERO) x2 = g0/(qa*x1)
      xc = -HUGE(CD_ONE)
      IF (x1 >= -1.0e-9_wp*l1 .AND. x1 <= l1*(CD_ONE + 1.0e-9_wp)) xc = MAX(xc, x1)
      IF (x2 >= -1.0e-9_wp*l1 .AND. x2 <= l1*(CD_ONE + 1.0e-9_wp)) xc = MAX(xc, x2)
      IF (xc > -HUGE(CD_ONE)) f = MIN(CD_ONE, MAX(CD_ZERO, xc/l1))
    END SUBROUTINE quadratic_fraction
  END SUBROUTINE tdp_locate

  SUBROUTINE CD_Range_TDP_Reference(line, r, clearance, ErrStat, ErrMsg)
    !! Fix the grounded end and the excursion reference of a line from its initial state.
    TYPE(CD_RangeLine), INTENT(INOUT) :: line
    REAL(wp), INTENT(IN) :: r(:, :), clearance(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    LOGICAL :: ga, gb, touching
    REAL(wp) :: arc, point(3), suspended_xy(2), span, grounded
    INTEGER :: nn

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    nn = SIZE(r, 2)
    ga = clearance(1) <= CD_SEABED_CONTACT_BLEND
    gb = clearance(nn) <= CD_SEABED_CONTACT_BLEND
    IF (ga .EQV. gb) THEN
      ErrStat = CD_RANGE_BADINPUT
      BLOCK
        ! Local buffer: a record longer than the caller's ErrMsg truncates
        ! instead of aborting the internal write.
        CHARACTER(1024) :: wmsg
        INTEGER :: wios
        wmsg = ''
        WRITE (wmsg, '(A,I0,A,L1,A,L1,A)', IOSTAT=wios) 'CableDyn_RangeOutput: TDP channels of line ', line%line_id, &
          ': the initial state must rest on the seabed at exactly one end (End A grounded = ', ga, &
          ', End B grounded = ', gb, ')'
        ErrMsg = wmsg
      END BLOCK
      RETURN
    END IF
    line%tdp_end = MERGE(1, 2, ga)
    CALL tdp_locate(r, clearance, line%tdp_end, touching, arc, point, suspended_xy, grounded)
    span = NORM2(suspended_xy - point(1:2))
    IF (.NOT. touching .OR. .NOT. (span > CD_ZERO)) THEN
      ErrStat = CD_RANGE_BADINPUT
      BLOCK
        ! Local buffer: a record longer than the caller's ErrMsg truncates
        ! instead of aborting the internal write.
        CHARACTER(1024) :: wmsg
        INTEGER :: wios
        wmsg = ''
        WRITE (wmsg, '(A,I0,A)', IOSTAT=wios) 'CableDyn_RangeOutput: TDP channels of line ', line%line_id, &
          ': the initial touchdown point lies below the suspended end; the excursion is undefined'
        ErrMsg = wmsg
      END BLOCK
      RETURN
    END IF
    line%ref_arc = arc
    line%ref_xy = point(1:2)
    line%ref_dir = (suspended_xy - point(1:2))/span
    line%tdp_ready = .TRUE.
  END SUBROUTINE CD_Range_TDP_Reference

  PURE SUBROUTINE CD_Range_TDP_Evaluate(line, r, clearance, tdp)
    !! Touchdown channels of one configuration against the line's fixed reference:
    !! tdp = [arc from End A, x, y, z, layback, excursion, grounded length].
    TYPE(CD_RangeLine), INTENT(IN) :: line
    REAL(wp), INTENT(IN) :: r(:, :), clearance(:)
    REAL(wp), INTENT(OUT) :: tdp(CD_TDP_N)
    LOGICAL :: touching
    REAL(wp) :: arc, point(3), suspended_xy(2), grounded

    tdp = CD_ZERO
    IF (.NOT. line%tdp_ready) RETURN
    CALL tdp_locate(r, clearance, line%tdp_end, touching, arc, point, suspended_xy, grounded)
    tdp(CD_TDP_S) = arc
    tdp(CD_TDP_X:CD_TDP_Z) = point
    tdp(CD_TDP_LAY) = NORM2(suspended_xy - point(1:2))
    tdp(CD_TDP_EXC) = DOT_PRODUCT(point(1:2) - line%ref_xy, line%ref_dir)
    tdp(CD_TDP_GRD) = grounded
  END SUBROUTINE CD_Range_TDP_Evaluate

  SUBROUTINE CD_Range_Write_Files(set, out_root, ErrStat, ErrMsg)
    !! Write <out_root>.Line<L>.range.out for every line with a range file and samples.
    TYPE(CD_RangeSet), INTENT(IN) :: set
    CHARACTER(*), INTENT(IN) :: out_root
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: il, unit, ios, j, k, nq, n, kq, rows(CD_RQ_N)
    CHARACTER(LEN(out_root) + 32) :: path
    CHARACTER(1) :: tab
    CHARACTER(16) :: id_text
    CHARACTER(*), PARAMETER :: NAMES(CD_RQ_N) = &
                               [CHARACTER(11) :: 'Tension', 'Curvature', 'BendMoment', 'Declination', 'Clearance', &
                                                  'Torque', 'Twist']
    CHARACTER(*), PARAMETER :: UNITS(CD_RQ_N) = [CHARACTER(7) :: '(N)', '(1/m)', '(N.m)', '(deg)', '(m)', '(N.m)', &
                                                                                                              '(deg)']
    CHARACTER(*), PARAMETER :: STATS(3) = [CHARACTER(4) :: 'Min', 'Max', 'Mean']

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    IF (.NOT. set%active) RETURN
    tab = CHAR(9)
    DO il = 1, SIZE(set%lines)
      IF (.NOT. set%lines(il)%want_range) CYCLE
      n = set%lines(il)%nsample
      IF (n < 1) CYCLE
      ! the quantities written: Tension .. Declination, Clearance with a seabed, Torque and Twist
      ! on a line with torsion
      nq = CD_RQ_DECLINATION
      rows(1:nq) = [(k, k=1, CD_RQ_DECLINATION)]
      IF (set%has_floor) THEN
        nq = nq + 1
        rows(nq) = CD_RQ_CLEARANCE
      END IF
      IF (set%lines(il)%has_torsion) THEN
        rows(nq + 1:nq + 2) = [CD_RQ_TORQUE, CD_RQ_TWIST]
        nq = nq + 2
      END IF
      WRITE (id_text, '(I0)') set%lines(il)%line_id
      path = TRIM(out_root)//'.Line'//TRIM(id_text)//'.range.out'
      CALL CD_Open_Write(unit, TRIM(path), ios)
      IF (ios /= 0) THEN
        ErrStat = CD_RANGE_BADINPUT
        ErrMsg = 'CableDyn_RangeOutput: cannot open range-graph output file: '//TRIM(path)
        RETURN
      END IF
      WRITE (unit, '(A,A,A,I0,A,ES25.16E3,A,ES25.16E3,A)', IOSTAT=ios) 'CableDyn range graph (line ', &
        TRIM(id_text), '; ', n, ' samples from t =', set%lines(il)%t_first, ' s to t =', set%lines(il)%t_last, &
        ' s; public node order End A -> End B)'
      IF (ios /= 0) GOTO 910
      WRITE (unit, '(A)', ADVANCE='NO', IOSTAT=ios) 'Node'//tab//'ArcLength'
      DO kq = 1, nq
        k = rows(kq)
        DO j = 1, 3
          WRITE (unit, '(A)', ADVANCE='NO', IOSTAT=ios) tab//TRIM(NAMES(k))//TRIM(STATS(j))
        END DO
      END DO
      WRITE (unit, '(A)', IOSTAT=ios) ''
      WRITE (unit, '(A)', ADVANCE='NO', IOSTAT=ios) '(-)'//tab//'(m)'
      DO kq = 1, nq
        k = rows(kq)
        DO j = 1, 3
          WRITE (unit, '(A)', ADVANCE='NO', IOSTAT=ios) tab//TRIM(UNITS(k))
        END DO
      END DO
      WRITE (unit, '(A)', IOSTAT=ios) ''
      IF (ios /= 0) GOTO 910
      DO j = 1, set%lines(il)%nn
        WRITE (unit, '(I0,A,ES15.7E3)', ADVANCE='NO', IOSTAT=ios) j, tab, set%lines(il)%arc(j)
        DO kq = 1, nq
          k = rows(kq)
          WRITE (unit, '(3(A,ES15.7E3))', ADVANCE='NO', IOSTAT=ios) tab, set%lines(il)%vmin(k, j), &
            tab, set%lines(il)%vmax(k, j), tab, set%lines(il)%vsum(k, j)/REAL(n, wp)
        END DO
        WRITE (unit, '(A)', IOSTAT=ios) ''
        IF (ios /= 0) GOTO 910
      END DO
      FLUSH (unit, IOSTAT=ios)
      IF (ios /= 0) GOTO 910
      CLOSE (unit)
    END DO
    RETURN
    ! a file that could not be completed does not stay behind looking like a finished graph
910 ErrStat = CD_RANGE_BADINPUT
    ErrMsg = 'CableDyn_RangeOutput: cannot write range-graph output file: '//TRIM(path)
    CLOSE (unit, STATUS='DELETE', IOSTAT=ios)
  END SUBROUTINE CD_Range_Write_Files

  SUBROUTINE CD_Range_Discard_Files(set, out_root, ErrStat, ErrMsg)
    !! Remove the <out_root>.Line<L>.range.out files of an earlier run, so a run that ends
    !! before writing its own leaves none behind to be taken for its result. A file that
    !! cannot be removed fails here, at the start of the run, not after it.
    TYPE(CD_RangeSet), INTENT(IN) :: set
    CHARACTER(*), INTENT(IN) :: out_root
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: il

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    IF (.NOT. set%active) RETURN
    DO il = 1, SIZE(set%lines)
      IF (.NOT. set%lines(il)%want_range) CYCLE
      CALL CD_Range_Discard_File(out_root, set%lines(il)%line_id, ErrStat, ErrMsg)
      IF (ErrStat /= CD_RANGE_OK) RETURN
    END DO
  END SUBROUTINE CD_Range_Discard_Files

  SUBROUTINE CD_Range_Discard_File(out_root, line_id, ErrStat, ErrMsg)
    !! Remove the <out_root>.Line<line_id>.range.out file of an earlier run, if there is one.
    CHARACTER(*), INTENT(IN) :: out_root
    INTEGER, INTENT(IN) :: line_id
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: unit, ios
    CHARACTER(LEN(out_root) + 32) :: path
    CHARACTER(16) :: id_text

    ErrStat = CD_RANGE_OK
    ErrMsg = ''
    WRITE (id_text, '(I0)') line_id
    path = TRIM(out_root)//'.Line'//TRIM(id_text)//'.range.out'
    IF (.NOT. CD_Path_Openable(TRIM(path), .FALSE.)) RETURN   ! no such file
    CALL CD_Open_Write(unit, TRIM(path), ios, status='OLD')
    IF (ios == 0) CLOSE (unit, STATUS='DELETE', IOSTAT=ios)
    IF (ios == 0) THEN
      IF (CD_Path_Openable(TRIM(path), .FALSE.)) ios = 1
    END IF
    IF (ios /= 0) THEN
      ErrStat = CD_RANGE_BADINPUT
      ErrMsg = 'CableDyn_RangeOutput: cannot replace the range-graph output file of an earlier run: '//TRIM(path)
    END IF
  END SUBROUTINE CD_Range_Discard_File

  PURE LOGICAL FUNCTION CD_Is_TDP_Channel(lo) RESULT(yes)
    !! True for a name of the TDP family (lower case), valid or not: "tdp" then a digit.
    CHARACTER(*), INTENT(IN) :: lo
    yes = .FALSE.
    IF (LEN_TRIM(lo) < 4) RETURN
    IF (lo(1:3) /= 'tdp') RETURN
    yes = VERIFY(lo(4:4), '0123456789') == 0
  END FUNCTION CD_Is_TDP_Channel

  PURE SUBROUTINE CD_Parse_TDP_Channel(ch, line_id, comp)
    !! TDP<L>s / x / y / z / Lay / Exc / Grd (case-insensitive, leading zeros allowed) -> deck line
    !! id and component CD_TDP_*; comp = 0 (and line_id = 0) when malformed.
    CHARACTER(*), INTENT(IN) :: ch
    INTEGER, INTENT(OUT) :: line_id, comp
    CHARACTER(LEN(ch)) :: lo
    INTEGER :: i, last, first_alpha, c

    line_id = 0
    comp = 0
    lo = ch
    DO i = 1, LEN(lo)
      c = IACHAR(lo(i:i))
      IF (c >= IACHAR('A') .AND. c <= IACHAR('Z')) lo(i:i) = ACHAR(c + 32)
    END DO
    last = LEN_TRIM(lo)
    IF (.NOT. CD_Is_TDP_Channel(lo)) RETURN
    first_alpha = SCAN(lo(4:last), 'abcdefghijklmnopqrstuvwxyz')
    IF (first_alpha == 0) RETURN
    first_alpha = first_alpha + 3
    IF (VERIFY(lo(4:first_alpha - 1), '0123456789') /= 0) RETURN
    IF (first_alpha - 4 > 9) RETURN
    DO i = 4, first_alpha - 1
      line_id = 10*line_id + (IACHAR(lo(i:i)) - IACHAR('0'))
    END DO
    SELECT CASE (lo(first_alpha:last))
    CASE ('s'); comp = CD_TDP_S
    CASE ('x'); comp = CD_TDP_X
    CASE ('y'); comp = CD_TDP_Y
    CASE ('z'); comp = CD_TDP_Z
    CASE ('lay'); comp = CD_TDP_LAY
    CASE ('exc'); comp = CD_TDP_EXC
    CASE ('grd'); comp = CD_TDP_GRD
    END SELECT
    IF (comp == 0 .OR. line_id < 1) THEN
      comp = 0
      line_id = 0
    END IF
  END SUBROUTINE CD_Parse_TDP_Channel

END MODULE CableDyn_RangeOutput
