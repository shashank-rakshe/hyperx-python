! File: src/CableDyn_Driver.f90
! SPDX-License-Identifier: Apache-2.0
! Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
MODULE CableDyn_Driver
  !! Minimal static line driver for the positions-only EI=0 cable core: read a small
  !! keyword input file describing one cable, solve it to static equilibrium under
  !! self-weight (optionally on a penalty seabed), and write a CSV of the converged
  !! node positions and per-element tensions. It is the keyword-deck static driver used
  !! by the test suite; the command-line program (app/cabledyn.f90) reads MoorDyn-style
  !! decks through CableDyn_DeckDriver instead.
  !!
  !! Input format (whitespace-delimited; blank lines and comments are ignored -- a
  !! comment runs from the first `#` or `!` to end of line, inline or whole-line, so
  !! the annotated sample below parses verbatim; keywords may appear in any order,
  !! but a block keyword consumes the lines that follow it):
  !!
  !!   gravity 9.81                 ! m/s^2 (> 0)            [required]
  !!   rho_water 1025.0             ! kg/m^3 (> 0)           [optional, default 1025]
  !!   tension_only T               ! T/F                    [optional, default F]
  !!   seabed 0.0 1.0e5             ! z_floor k_n (N/m, >0)  [optional; omit => none]
  !!   nodes 3                      ! then 3 lines: x y z
  !!   0.0 0.0 0.0
  !!   1.0 0.0 0.0
  !!   2.0 0.0 0.0
  !!   elements 2                   ! then 2 lines: a b L0 EA mass_per_len diameter
  !!   1 2 0.9 1000.0 50.0 0.1      ! a,b 1-based; L0,EA,diam > 0, mass/len >= 0
  !!   2 3 0.9 1000.0 50.0 0.1
  !!   fixed 6                      ! then 1 line of 6 1-based DOF indices
  !!   1 2 3 7 8 9
  !!
  !! Self-weight: per element the submerged weight w = (mass_per_len -
  !! rho_water*pi/4*diam^2)*gravity acts in -z (CD_Submerged_Weight), assembled to
  !! the consistent nodal load (CD_Assemble_Distributed_Load). The solve is the
  !! CableDyn_Static path; tensions are recovered with
  !! CD_Compute_Cable_Tension on the converged state.
  USE CableDyn_Precision, ONLY: wp, CD_ZERO, CD_ONE, CD_All_Finite, CD_Is_Finite
  USE CableDyn_PathIO, ONLY: CD_Open_Read, CD_Open_Write
  USE CableDyn_Loads, ONLY: CD_Submerged_Weight, CD_Assemble_Distributed_Load
  USE CableDyn_Assemble, ONLY: CD_Compute_Cable_Tension
  USE CableDyn_Static, ONLY: CableSolverConfig, CD_Static_Cable_Solve, &
                             CD_Static_Cable_Solve_Continuation, CD_STATIC_OK, CD_STATIC_BADINPUT
  USE CableDyn_Line, ONLY: CD_LineType, CD_LineSection, CD_Build_Line_Mesh, &
                           CD_Nodal_Seabed_Stiffness, CD_LINE_OK
  USE CableDyn_Catenary, ONLY: CD_Catenary_Seed, CD_CAT_OK
  IMPLICIT NONE
  PRIVATE

  PUBLIC :: CD_Run_Static_Driver
  PUBLIC :: CD_Run_Line_Static_Driver
  PUBLIC :: CD_Deck_Is_Line_Object

  ! ErrStat codes: 0 success; 1 bad input / parse error; 2 solve failed.
  INTEGER, PARAMETER, PUBLIC :: CD_DRIVER_OK = 0
  INTEGER, PARAMETER, PUBLIC :: CD_DRIVER_BADINPUT = 1
  INTEGER, PARAMETER, PUBLIC :: CD_DRIVER_SOLVEFAIL = 2

CONTAINS

  SUBROUTINE CD_Run_Static_Driver(input_path, output_path, converged, ErrStat, ErrMsg)
    !! Parse the input file, solve the static EI=0 line, and write the CSV output.
    !! ``converged`` reports the solve outcome; ErrStat is CD_DRIVER_OK only when the
    !! file parsed, the solve ran, AND it converged (a parsed-but-non-converged solve
    !! is CD_DRIVER_SOLVEFAIL with the CSV still written for inspection).
    CHARACTER(*), INTENT(IN)  :: input_path, output_path
    LOGICAL, INTENT(OUT) :: converged
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER  :: n_nodes, n_elem, n_dof
    INTEGER, ALLOCATABLE :: conn(:, :), fixed_dofs(:)
    REAL(wp), ALLOCATABLE :: nodes(:, :), l0(:), ea(:), mass_pl(:), diam(:)
    REAL(wp), ALLOCATABLE :: w(:), load(:, :), f_ext(:), q0(:), q(:), tension(:)
    REAL(wp) :: gravity, rho_water, z_floor, k_n
    LOGICAL  :: tension_only, has_seabed, stalled, at_floor
    INTEGER  :: n_iter, es, i
    REAL(wp), ALLOCATABLE :: kn_arr(:)
    CHARACTER(1024) :: em
    TYPE(CableSolverConfig) :: cfg

    converged = .FALSE.
    ErrStat = CD_DRIVER_OK
    ErrMsg = ''

    CALL parse_input(input_path, gravity, rho_water, tension_only, has_seabed, z_floor, k_n, &
                     nodes, conn, l0, ea, mass_pl, diam, fixed_dofs, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN
    n_nodes = SIZE(nodes, 2)
    n_elem = SIZE(conn, 2)
    n_dof = 3*n_nodes

    ! self-weight -> consistent nodal load
    ALLOCATE (w(n_elem), load(3, n_elem), f_ext(n_dof))
    CALL CD_Submerged_Weight(mass_pl, diam, rho_water, gravity, w, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'submerged weight: '//TRIM(em))
      RETURN
    END IF
    DO i = 1, n_elem
      load(1, i) = CD_ZERO
      load(2, i) = CD_ZERO
      load(3, i) = -w(i)            ! gravity acts -z
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'load assembly: '//TRIM(em))
      RETURN
    END IF

    ! seed q0 from the input node positions (flat positions-only state)
    ALLOCATE (q0(n_dof), q(n_dof), tension(n_elem))
    DO i = 1, n_nodes
      q0(3*i - 2:3*i) = nodes(:, i)
    END DO

    IF (has_seabed) THEN
      ALLOCATE (kn_arr(n_nodes), source=k_n)
      CALL CD_Static_Cable_Solve(q0, conn, l0, ea, tension_only, f_ext, fixed_dofs, cfg, &
                                 q, converged, stalled, at_floor, n_iter, es, em, &
                                 seabed_z_floor=z_floor, seabed_kn=kn_arr)
    ELSE
      CALL CD_Static_Cable_Solve(q0, conn, l0, ea, tension_only, f_ext, fixed_dofs, cfg, &
                                 q, converged, stalled, at_floor, n_iter, es, em)
    END IF
    IF (es /= CD_STATIC_OK) THEN
      ! No usable state. Distinguish a rejected-input error (e.g. an out-of-range
      ! fixed DOF in the file) from a numerical solve failure (singular tangent).
      IF (es == CD_STATIC_BADINPUT) THEN
        CALL fail(ErrStat, ErrMsg, 'static solve rejected the input: '//TRIM(em))   ! BADINPUT
      ELSE
        ErrStat = CD_DRIVER_SOLVEFAIL
        ErrMsg = 'CableDyn_Driver: static solve failed: '//TRIM(em)
      END IF
      RETURN
    END IF

    ! per-element tension on the converged state
    CALL CD_Compute_Cable_Tension(reshape3(q, n_dof), conn, l0, ea, tension_only, tension, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'tension recovery: '//TRIM(em))
      RETURN
    END IF

    CALL write_csv(output_path, q, conn, tension, converged, stalled, at_floor, n_iter, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN

    IF (.NOT. converged) THEN
      ErrStat = CD_DRIVER_SOLVEFAIL
      ErrMsg = 'CableDyn_Driver: solve did not converge (CSV written for inspection)'
    END IF
  END SUBROUTINE CD_Run_Static_Driver

  ! --------------------------------------------------------------------------- !
  ! line-object (composite multi-section) static driver                         !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE CD_Run_Line_Static_Driver(input_path, output_path, converged, ErrStat, ErrMsg)
    !! Run the OrcaFlex-style line-object static deck: a line declared as line types
    !! + sections + endpoints (CableDyn_Line) is meshed, seeded from the analytical
    !! catenary (CableDyn_Catenary), and solved to the EI=0 grounded equilibrium by
    !! load continuation (CableDyn_Static). This is the deck/driver workflow over the
    !! composite line-object foundation -- multi-line-types and in-line mesh
    !! refinement come straight from the deck, and the same single-line continuation
    !! kernel solves the result. The CSV output matches the explicit driver.
    !!
    !! Deck format (whitespace-delimited; `#`/`!` comments and blank lines ignored;
    !! a block keyword consumes the lines that follow it):
    !!
    !!   gravity 9.81                ! m/s^2 (> 0)               [required]
    !!   rho_water 1025.0            ! kg/m^3 (> 0)              [optional, def 1025]
    !!   tension_only F              ! T/F                       [optional, def F]
    !!   seabed 0.0 1.0e5            ! z_floor  kn_base          [optional; omit => none]
    !!                               !   NB kn_base is PER-AREA [N/m^3]; each node gets
    !!                               !   kn_base * diameter * segment-length (per-node
    !!                               !   tributary penalty), UNLIKE the explicit driver
    !!                               !   whose `seabed` k_n is per-node [N/m].
    !!   anchor 0.0 0.0 0.0          ! anchor point (node 1)     [required]
    !!   fairlead 60.0 0.0 35.0      ! fairlead point (last node)[required]
    !!   static_solver 1e-8 1e-5 80 12  ! rel_tol abs_tol max_iter backtracks [optional]
    !!   continuation 4              ! then 1 line of 4 load factors  [optional]
    !!   0.25 0.5 0.75 1.0           !   strictly increasing, ending at 1 (def this ramp)
    !!   line_types 2                ! then 2 lines: EA mass_per_len diameter  [required]
    !!   5.0e6 50.0 0.10
    !!   8.0e6 20.0 0.08
    !!   sections 2                  ! then 2 lines: line_type length n_segments [required]
    !!   1 40.0 8
    !!   2 40.0 12
    !!
    !! Sections are listed anchor -> fairlead; the anchor is node 1. Both endpoints are
    !! pinned (the 6 endpoint DOFs). The shape is seeded from the analytical extensible
    !! catenary (CD_Catenary_Seed: grounded, suspended, taut or vertical spans) and, when
    !! no catenary exists for the geometry, from a straight-line (rest-proportional) seed
    !! (the seabed is optional).
    !! A parsed-but-non-converged solve is CD_DRIVER_SOLVEFAIL with the CSV still
    !! written for inspection.
    CHARACTER(*), INTENT(IN)  :: input_path, output_path
    LOGICAL, INTENT(OUT) :: converged
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    REAL(wp) :: gravity, rho_water, z_floor, kn_base, anchor(3), fairlead(3), h, gl
    LOGICAL  :: tension_only, has_seabed, stalled, at_floor
    TYPE(CableSolverConfig) :: cfg
    TYPE(CD_LineType), ALLOCATABLE :: line_types(:)
    TYPE(CD_LineSection), ALLOCATABLE :: sections(:)
    REAL(wp), ALLOCATABLE :: factors(:)
    INTEGER, ALLOCATABLE :: conn(:, :), fixed_dofs(:)
    REAL(wp), ALLOCATABLE :: l0(:), ea(:), mass_pl(:), diam(:), w(:), load(:, :)
    REAL(wp), ALLOCATABLE :: f_ext(:), q0(:), q(:), tension(:), kn(:)
    INTEGER  :: n_elem, n_nodes, n_dof, es, i, n_iter, n_stages
    CHARACTER(1024) :: em

    converged = .FALSE.
    ErrStat = CD_DRIVER_OK
    ErrMsg = ''

    CALL parse_line_deck(input_path, gravity, rho_water, tension_only, has_seabed, z_floor, &
                         kn_base, anchor, fairlead, cfg, factors, line_types, sections, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN

    ! mesh the composite line (anchor is node 1, so sections are anchor -> fairlead)
    CALL CD_Build_Line_Mesh(sections, line_types, .FALSE., conn, l0, ea, mass_pl, diam, es, em)
    IF (es /= CD_LINE_OK) THEN
      CALL fail(ErrStat, ErrMsg, 'line assembly: '//TRIM(em)); RETURN
    END IF
    n_elem = SIZE(l0)
    n_nodes = n_elem + 1
    n_dof = 3*n_nodes

    ! submerged self-weight -> consistent nodal load
    ALLOCATE (w(n_elem), load(3, n_elem), f_ext(n_dof))
    CALL CD_Submerged_Weight(mass_pl, diam, rho_water, gravity, w, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'submerged weight: '//TRIM(em)); RETURN
    END IF
    DO i = 1, n_elem
      load(1, i) = CD_ZERO
      load(2, i) = CD_ZERO
      load(3, i) = -w(i)
    END DO
    CALL CD_Assemble_Distributed_Load(conn, l0, load, f_ext, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'load assembly: '//TRIM(em)); RETURN
    END IF

    ! Seed the shape from the analytical extensible catenary (CD_Catenary_Seed) of the
    ! line through the endpoints. The deck inputs are already validated finite/positive
    ! (parse_line_deck + CD_Build_Line_Mesh), so a non-OK catenary result here is a
    ! geometry without a catenary -- fall back to the straight-line (rest-proportional)
    ! seed, which the continuation solve then refines.
    ALLOCATE (q0(n_dof), q(n_dof), tension(n_elem))
    CALL CD_Catenary_Seed(anchor, fairlead, l0, ea, w, q0, h, gl, es, em)
    IF (es /= CD_CAT_OK) CALL straight_line_seed(anchor, fairlead, l0, q0)

    ! both endpoints pinned (anchor = node 1, fairlead = last node)
    ALLOCATE (fixed_dofs(6))
    fixed_dofs = [1, 2, 3, n_dof - 2, n_dof - 1, n_dof]

    ! solve by load continuation, with the per-node tributary seabed penalty if declared
    IF (has_seabed) THEN
      CALL CD_Nodal_Seabed_Stiffness(kn_base, diam, l0, kn, es, em)
      IF (es /= CD_LINE_OK) THEN
        CALL fail(ErrStat, ErrMsg, 'seabed stiffness: '//TRIM(em)); RETURN
      END IF
      CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, tension_only, f_ext, fixed_dofs, &
                                              cfg, factors, q, converged, stalled, at_floor, &
                                              n_iter, n_stages, es, em, &
                                              seabed_z_floor=z_floor, seabed_kn=kn)
    ELSE
      CALL CD_Static_Cable_Solve_Continuation(q0, conn, l0, ea, tension_only, f_ext, fixed_dofs, &
                                              cfg, factors, q, converged, stalled, at_floor, &
                                              n_iter, n_stages, es, em)
    END IF
    IF (es /= CD_STATIC_OK) THEN
      IF (es == CD_STATIC_BADINPUT) THEN
        CALL fail(ErrStat, ErrMsg, 'static solve rejected the input: '//TRIM(em))
      ELSE
        ErrStat = CD_DRIVER_SOLVEFAIL
        ErrMsg = 'CableDyn_Driver: static solve failed: '//TRIM(em)
      END IF
      RETURN
    END IF

    CALL CD_Compute_Cable_Tension(reshape3(q, n_dof), conn, l0, ea, tension_only, tension, es, em)
    IF (es /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'tension recovery: '//TRIM(em)); RETURN
    END IF

    CALL write_csv(output_path, q, conn, tension, converged, stalled, at_floor, n_iter, ErrStat, ErrMsg)
    IF (ErrStat /= 0) RETURN

    IF (.NOT. converged) THEN
      ErrStat = CD_DRIVER_SOLVEFAIL
      ErrMsg = 'CableDyn_Driver: solve did not converge (CSV written for inspection)'
    END IF
  END SUBROUTINE CD_Run_Line_Static_Driver

  ! --------------------------------------------------------------------------- !
  ! input parsing                                                               !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE parse_input(path, gravity, rho_water, tension_only, has_seabed, z_floor, k_n, &
                         nodes, conn, l0, ea, mass_pl, diam, fixed_dofs, ErrStat, ErrMsg)
    !! Keyword-dispatch parser for the driver input format (see the module header).
    CHARACTER(*), INTENT(IN)  :: path
    REAL(wp), INTENT(OUT) :: gravity, rho_water, z_floor, k_n
    LOGICAL, INTENT(OUT) :: tension_only, has_seabed
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: nodes(:, :), l0(:), ea(:), mass_pl(:), diam(:)
    INTEGER, ALLOCATABLE, INTENT(OUT) :: conn(:, :), fixed_dofs(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: unit, ios, n, i, a, b
    CHARACTER(512) :: line
    CHARACTER(64) :: kw
    LOGICAL :: have_gravity, have_nodes, have_elems, have_fixed
    CHARACTER(16) :: to_flag

    ErrStat = 0
    ErrMsg = ''
    ! defaults
    gravity = CD_ZERO
    rho_water = 1025.0_wp
    tension_only = .FALSE.
    has_seabed = .FALSE.
    z_floor = CD_ZERO
    k_n = CD_ZERO
    have_gravity = .FALSE.
    have_nodes = .FALSE.
    have_elems = .FALSE.
    have_fixed = .FALSE.
    ! Default-allocate every INTENT(OUT) array to zero size so it is allocated on
    ! EVERY return path (the block keywords below deallocate + reallocate to the
    ! real size). This keeps the caller's SIZE()/indexing well-defined even on an
    ! error return and silences -Wmaybe-uninitialized.
    ALLOCATE (nodes(3, 0), conn(2, 0), l0(0), ea(0), mass_pl(0), diam(0), fixed_dofs(0))

    CALL CD_Open_Read(unit, path, ios)
    IF (ios /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'cannot open input file: '//TRIM(path))
      RETURN
    END IF

    DO
      CALL next_record(unit, line, ios)
      IF (ios /= 0) EXIT                      ! end of file
      READ (line, *, IOSTAT=ios) kw
      IF (ios /= 0) CYCLE
      ! Every line must carry EXACTLY its expected number of whitespace-separated
      ! tokens. Trailing extras are rejected, not silently dropped -- most
      ! consequentially on the variable-length `fixed` list (extra DOFs would
      ! discard boundary conditions that set the equilibrium), but uniformly on
      ! every line so a malformed deck fails closed instead of being parsed leniently.
      SELECT CASE (to_lower(TRIM(kw)))
      CASE ('gravity')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'gravity <value>')) RETURN
        READ (line, *, IOSTAT=ios) kw, gravity
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "gravity" line'); CLOSE (unit); RETURN
        END IF
        have_gravity = .TRUE.
      CASE ('rho_water')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'rho_water <value>')) RETURN
        READ (line, *, IOSTAT=ios) kw, rho_water
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "rho_water" line'); CLOSE (unit); RETURN
        END IF
      CASE ('tension_only')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'tension_only <T|F>')) RETURN
        READ (line, *, IOSTAT=ios) kw, to_flag
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "tension_only" line'); CLOSE (unit); RETURN
        END IF
        ! Explicit allow-list: any other token (a typo, a Fortran-style `.true.`,
        ! `yes`, ...) fails closed rather than silently defaulting to .FALSE. and
        ! quietly running a requested tension-only case with compression enabled.
        SELECT CASE (to_lower(TRIM(to_flag)))
        CASE ('t', 'true', '.true.')
          tension_only = .TRUE.
        CASE ('f', 'false', '.false.')
          tension_only = .FALSE.
        CASE DEFAULT
          CALL fail(ErrStat, ErrMsg, 'tension_only must be T/F (or true/false)'); CLOSE (unit); RETURN
        END SELECT
      CASE ('seabed')
        IF (bad_count(line, 3, unit, ErrStat, ErrMsg, 'seabed <z_floor> <k_n>')) RETURN
        READ (line, *, IOSTAT=ios) kw, z_floor, k_n
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "seabed" line (need z_floor k_n)'); CLOSE (unit); RETURN
        END IF
        has_seabed = .TRUE.
      CASE ('nodes')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'nodes <count>')) RETURN
        READ (line, *, IOSTAT=ios) kw, n
        IF (ios /= 0 .OR. n < 2) THEN
          CALL fail(ErrStat, ErrMsg, '"nodes" needs a count >= 2'); CLOSE (unit); RETURN
        END IF
        DEALLOCATE (nodes); ALLOCATE (nodes(3, n))
        DO i = 1, n
          CALL next_record(unit, line, ios)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'unexpected EOF in nodes block'); CLOSE (unit); RETURN
          END IF
          IF (bad_count(line, 3, unit, ErrStat, ErrMsg, 'node "x y z"')) RETURN
          READ (line, *, IOSTAT=ios) nodes(1, i), nodes(2, i), nodes(3, i)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'malformed node line (need x y z)'); CLOSE (unit); RETURN
          END IF
        END DO
        have_nodes = .TRUE.
      CASE ('elements')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'elements <count>')) RETURN
        READ (line, *, IOSTAT=ios) kw, n
        IF (ios /= 0 .OR. n < 1) THEN
          CALL fail(ErrStat, ErrMsg, '"elements" needs a count >= 1'); CLOSE (unit); RETURN
        END IF
        DEALLOCATE (conn, l0, ea, mass_pl, diam)
        ALLOCATE (conn(2, n), l0(n), ea(n), mass_pl(n), diam(n))
        DO i = 1, n
          CALL next_record(unit, line, ios)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'unexpected EOF in elements block'); CLOSE (unit); RETURN
          END IF
          IF (bad_count(line, 6, unit, ErrStat, ErrMsg, 'element "a b L0 EA mass diam"')) RETURN
          READ (line, *, IOSTAT=ios) a, b, l0(i), ea(i), mass_pl(i), diam(i)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'malformed element line (need a b L0 EA mass diam)')
            CLOSE (unit); RETURN
          END IF
          conn(1, i) = a
          conn(2, i) = b
        END DO
        have_elems = .TRUE.
      CASE ('fixed')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'fixed <count>')) RETURN
        READ (line, *, IOSTAT=ios) kw, n
        IF (ios /= 0 .OR. n < 0) THEN
          CALL fail(ErrStat, ErrMsg, '"fixed" needs a count >= 0'); CLOSE (unit); RETURN
        END IF
        DEALLOCATE (fixed_dofs); ALLOCATE (fixed_dofs(n))
        IF (n > 0) THEN
          CALL next_record(unit, line, ios)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'unexpected EOF in fixed block'); CLOSE (unit); RETURN
          END IF
          ! Exactly n DOFs: a line with fewer fails the READ; a line with more is
          ! rejected here rather than silently dropping the trailing constraints.
          IF (bad_count(line, n, unit, ErrStat, ErrMsg, 'fixed-DOF list of the declared length')) RETURN
          READ (line, *, IOSTAT=ios) (fixed_dofs(i), i=1, n)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'malformed fixed-DOF line'); CLOSE (unit); RETURN
          END IF
        END IF
        have_fixed = .TRUE.
      CASE DEFAULT
        CALL fail(ErrStat, ErrMsg, 'unknown keyword "'//TRIM(kw)//'"'); CLOSE (unit); RETURN
      END SELECT
    END DO
    CLOSE (unit)

    IF (.NOT. (have_gravity .AND. have_nodes .AND. have_elems .AND. have_fixed)) THEN
      CALL fail(ErrStat, ErrMsg, 'input must define gravity, nodes, elements, and fixed')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive'); RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(rho_water) .AND. rho_water > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'rho_water must be finite and positive'); RETURN
    END IF
    IF (has_seabed .AND. .NOT. (CD_Is_Finite(z_floor) .AND. CD_Is_Finite(k_n) .AND. k_n > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed needs finite z_floor and positive k_n'); RETURN
    END IF
    ! deeper structural validation (ranges, shapes, positivity) is the solver's job
    ! and is reported through it; the parser guarantees only a well-formed file.
  END SUBROUTINE parse_input

  SUBROUTINE parse_line_deck(path, gravity, rho_water, tension_only, has_seabed, z_floor, kn_base, &
                             anchor, fairlead, cfg, factors, line_types, sections, ErrStat, ErrMsg)
    !! Keyword-dispatch parser for the line-object deck (see CD_Run_Line_Static_Driver).
    !! Returns the scalars, the (optional) solver config + continuation schedule, and
    !! the line-type / section tables. Fails closed on a malformed or incomplete deck.
    CHARACTER(*), INTENT(IN)  :: path
    REAL(wp), INTENT(OUT) :: gravity, rho_water, z_floor, kn_base, anchor(3), fairlead(3)
    LOGICAL, INTENT(OUT) :: tension_only, has_seabed
    TYPE(CableSolverConfig), INTENT(OUT) :: cfg
    REAL(wp), ALLOCATABLE, INTENT(OUT) :: factors(:)
    TYPE(CD_LineType), ALLOCATABLE, INTENT(OUT) :: line_types(:)
    TYPE(CD_LineSection), ALLOCATABLE, INTENT(OUT) :: sections(:)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg

    INTEGER :: unit, ios, n, i, lt
    REAL(wp) :: len_i
    CHARACTER(512) :: line
    CHARACTER(64) :: kw
    CHARACTER(16) :: to_flag
    LOGICAL :: have_gravity, have_anchor, have_fairlead, have_types, have_sections

    ErrStat = 0
    ErrMsg = ''
    gravity = CD_ZERO
    rho_water = 1025.0_wp
    tension_only = .FALSE.
    has_seabed = .FALSE.
    z_floor = CD_ZERO
    kn_base = CD_ZERO
    anchor = CD_ZERO
    fairlead = CD_ZERO
    have_gravity = .FALSE.
    have_anchor = .FALSE.
    have_fairlead = .FALSE.
    have_types = .FALSE.
    have_sections = .FALSE.
    ! allocate every INTENT(OUT) array on every return path; the default continuation
    ! ramp stands unless a `continuation` block overrides it.
    ALLOCATE (line_types(0), sections(0))
    ALLOCATE (factors(4)); factors = [0.25_wp, 0.5_wp, 0.75_wp, CD_ONE]

    CALL CD_Open_Read(unit, path, ios)
    IF (ios /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'cannot open input file: '//TRIM(path)); RETURN
    END IF

    DO
      CALL next_record(unit, line, ios)
      IF (ios /= 0) EXIT
      READ (line, *, IOSTAT=ios) kw
      IF (ios /= 0) CYCLE
      SELECT CASE (to_lower(TRIM(kw)))
      CASE ('gravity')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'gravity <value>')) RETURN
        READ (line, *, IOSTAT=ios) kw, gravity
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "gravity" line'); CLOSE (unit); RETURN
        END IF
        have_gravity = .TRUE.
      CASE ('rho_water')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'rho_water <value>')) RETURN
        READ (line, *, IOSTAT=ios) kw, rho_water
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "rho_water" line'); CLOSE (unit); RETURN
        END IF
      CASE ('tension_only')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'tension_only <T|F>')) RETURN
        READ (line, *, IOSTAT=ios) kw, to_flag
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "tension_only" line'); CLOSE (unit); RETURN
        END IF
        SELECT CASE (to_lower(TRIM(to_flag)))
        CASE ('t', 'true', '.true.')
          tension_only = .TRUE.
        CASE ('f', 'false', '.false.')
          tension_only = .FALSE.
        CASE DEFAULT
          CALL fail(ErrStat, ErrMsg, 'tension_only must be T/F (or true/false)'); CLOSE (unit); RETURN
        END SELECT
      CASE ('seabed')
        IF (bad_count(line, 3, unit, ErrStat, ErrMsg, 'seabed <z_floor> <kn_base>')) RETURN
        READ (line, *, IOSTAT=ios) kw, z_floor, kn_base
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "seabed" line (need z_floor kn_base)'); CLOSE (unit); RETURN
        END IF
        has_seabed = .TRUE.
      CASE ('anchor')
        IF (bad_count(line, 4, unit, ErrStat, ErrMsg, 'anchor <x> <y> <z>')) RETURN
        READ (line, *, IOSTAT=ios) kw, anchor(1), anchor(2), anchor(3)
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "anchor" line (need x y z)'); CLOSE (unit); RETURN
        END IF
        have_anchor = .TRUE.
      CASE ('fairlead')
        IF (bad_count(line, 4, unit, ErrStat, ErrMsg, 'fairlead <x> <y> <z>')) RETURN
        READ (line, *, IOSTAT=ios) kw, fairlead(1), fairlead(2), fairlead(3)
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "fairlead" line (need x y z)'); CLOSE (unit); RETURN
        END IF
        have_fairlead = .TRUE.
      CASE ('static_solver')
        IF (bad_count(line, 5, unit, ErrStat, ErrMsg, &
                      'static_solver <rel_tol> <abs_tol> <max_iter> <armijo_backtracks>')) RETURN
        READ (line, *, IOSTAT=ios) kw, cfg%rel_tol, cfg%abs_tol, cfg%max_iter, cfg%armijo_max_backtracks
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed "static_solver" line'); CLOSE (unit); RETURN
        END IF
      CASE ('continuation')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'continuation <count>')) RETURN
        READ (line, *, IOSTAT=ios) kw, n
        IF (ios /= 0 .OR. n < 1) THEN
          CALL fail(ErrStat, ErrMsg, '"continuation" needs a count >= 1'); CLOSE (unit); RETURN
        END IF
        CALL next_record(unit, line, ios)
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'unexpected EOF in continuation block'); CLOSE (unit); RETURN
        END IF
        IF (bad_count(line, n, unit, ErrStat, ErrMsg, 'continuation factor list of the declared length')) RETURN
        DEALLOCATE (factors); ALLOCATE (factors(n))
        READ (line, *, IOSTAT=ios) (factors(i), i=1, n)
        IF (ios /= 0) THEN
          CALL fail(ErrStat, ErrMsg, 'malformed continuation factor line'); CLOSE (unit); RETURN
        END IF
      CASE ('line_types')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'line_types <count>')) RETURN
        READ (line, *, IOSTAT=ios) kw, n
        IF (ios /= 0 .OR. n < 1) THEN
          CALL fail(ErrStat, ErrMsg, '"line_types" needs a count >= 1'); CLOSE (unit); RETURN
        END IF
        DEALLOCATE (line_types); ALLOCATE (line_types(n))
        DO i = 1, n
          CALL next_record(unit, line, ios)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'unexpected EOF in line_types block'); CLOSE (unit); RETURN
          END IF
          IF (bad_count(line, 3, unit, ErrStat, ErrMsg, 'line type "EA mass_per_len diameter"')) RETURN
          READ (line, *, IOSTAT=ios) line_types(i)%ea, line_types(i)%mass_per_length, line_types(i)%diameter
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'malformed line_type row (need EA mass_per_len diameter)')
            CLOSE (unit); RETURN
          END IF
          line_types(i)%ei = CD_ZERO   ! EI=0 cable path; finite-EI uses the dedicated deck workflow
        END DO
        have_types = .TRUE.
      CASE ('sections')
        IF (bad_count(line, 2, unit, ErrStat, ErrMsg, 'sections <count>')) RETURN
        READ (line, *, IOSTAT=ios) kw, n
        IF (ios /= 0 .OR. n < 1) THEN
          CALL fail(ErrStat, ErrMsg, '"sections" needs a count >= 1'); CLOSE (unit); RETURN
        END IF
        DEALLOCATE (sections); ALLOCATE (sections(n))
        DO i = 1, n
          CALL next_record(unit, line, ios)
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'unexpected EOF in sections block'); CLOSE (unit); RETURN
          END IF
          IF (bad_count(line, 3, unit, ErrStat, ErrMsg, 'section "line_type length n_segments"')) RETURN
          READ (line, *, IOSTAT=ios) lt, len_i, sections(i)%n_segments
          IF (ios /= 0) THEN
            CALL fail(ErrStat, ErrMsg, 'malformed section row (need line_type length n_segments)')
            CLOSE (unit); RETURN
          END IF
          sections(i)%line_type = lt
          sections(i)%length = len_i
        END DO
        have_sections = .TRUE.
      CASE DEFAULT
        CALL fail(ErrStat, ErrMsg, 'unknown keyword "'//TRIM(kw)//'"'); CLOSE (unit); RETURN
      END SELECT
    END DO
    CLOSE (unit)

    IF (.NOT. (have_gravity .AND. have_anchor .AND. have_fairlead .AND. have_types .AND. have_sections)) THEN
      CALL fail(ErrStat, ErrMsg, 'deck must define gravity, anchor, fairlead, line_types, and sections')
      RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(gravity) .AND. gravity > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'gravity must be finite and positive'); RETURN
    END IF
    IF (.NOT. (CD_Is_Finite(rho_water) .AND. rho_water > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'rho_water must be finite and positive'); RETURN
    END IF
    IF (.NOT. (CD_All_Finite(anchor) .AND. CD_All_Finite(fairlead))) THEN
      CALL fail(ErrStat, ErrMsg, 'anchor and fairlead must be finite'); RETURN
    END IF
    IF (has_seabed .AND. .NOT. (CD_Is_Finite(z_floor) .AND. CD_Is_Finite(kn_base) .AND. kn_base > CD_ZERO)) THEN
      CALL fail(ErrStat, ErrMsg, 'seabed needs finite z_floor and positive kn_base'); RETURN
    END IF
    ! validate the (optional) solver policy at parse for a clear error (the inner solve
    ! would also reject it, but as a less specific "solve rejected the input").
    IF (.NOT. (CD_Is_Finite(cfg%rel_tol) .AND. cfg%rel_tol > CD_ZERO) &
        .OR. .NOT. (CD_Is_Finite(cfg%abs_tol) .AND. cfg%abs_tol > CD_ZERO) &
        .OR. cfg%max_iter < 1 .OR. cfg%armijo_max_backtracks < 0) THEN
      CALL fail(ErrStat, ErrMsg, 'static_solver: rel_tol/abs_tol must be > 0, max_iter >= 1, backtracks >= 0')
      RETURN
    END IF
    ! structural ranges (EA/diameter/length positivity, factor schedule, DOF ranges) are
    ! validated by CD_Build_Line_Mesh / CD_Static_Cable_Solve_Continuation and surfaced through them.
  END SUBROUTINE parse_line_deck

  SUBROUTINE CD_Deck_Is_Line_Object(input_path, is_line, ErrStat, ErrMsg)
    !! Pre-scan a deck to choose the driver: TRUE iff any record's first token is the
    !! `sections` keyword (the line-object deck), FALSE for the explicit nodes/elements
    !! deck, so a caller can dispatch without a mode flag.
    CHARACTER(*), INTENT(IN)  :: input_path
    LOGICAL, INTENT(OUT) :: is_line
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: unit, ios
    CHARACTER(512) :: line
    CHARACTER(64) :: kw
    is_line = .FALSE.
    ErrStat = 0
    ErrMsg = ''
    CALL CD_Open_Read(unit, input_path, ios)
    IF (ios /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'cannot open input file: '//TRIM(input_path)); RETURN
    END IF
    DO
      CALL next_record(unit, line, ios)
      IF (ios /= 0) EXIT
      READ (line, *, IOSTAT=ios) kw
      IF (ios /= 0) CYCLE
      IF (to_lower(TRIM(kw)) == 'sections') THEN
        is_line = .TRUE.; EXIT
      END IF
    END DO
    CLOSE (unit)
  END SUBROUTINE CD_Deck_Is_Line_Object

  SUBROUTINE next_record(unit, line, ios)
    !! Read the next non-blank line with any inline comment stripped; ios /= 0 at end
    !! of file. A comment starts at the first `#` OR `!` (both are accepted so the
    !! documented sample deck, which annotates lines with `!`, parses verbatim);
    !! everything from there to end-of-line is discarded before the caller tokenises.
    INTEGER, INTENT(IN)  :: unit
    CHARACTER(*), INTENT(OUT) :: line
    INTEGER, INTENT(OUT) :: ios
    CHARACTER(LEN(line)) :: buf
    INTEGER :: p, q
    DO
      READ (unit, '(A)', IOSTAT=ios) buf
      IF (ios /= 0) RETURN
      buf = ADJUSTL(buf)
      p = INDEX(buf, '#')
      q = INDEX(buf, '!')
      IF (q > 0 .AND. (p == 0 .OR. q < p)) p = q   ! earliest of '#' / '!'
      IF (p > 0) buf(p:) = ' '                      ! strip the inline comment
      IF (LEN_TRIM(buf) > 0) THEN
        line = buf
        RETURN
      END IF
    END DO
  END SUBROUTINE next_record

  ! --------------------------------------------------------------------------- !
  ! output                                                                      !
  ! --------------------------------------------------------------------------- !

  SUBROUTINE write_csv(path, q, conn, tension, converged, stalled, at_floor, n_iter, ErrStat, ErrMsg)
    !! Write the converged node positions and per-element tensions as CSV. The header
    !! comment lines (# ...) carry the solve summary; two labelled sections follow.
    CHARACTER(*), INTENT(IN)  :: path
    REAL(wp), INTENT(IN)  :: q(:), tension(:)
    INTEGER, INTENT(IN)  :: conn(:, :), n_iter
    LOGICAL, INTENT(IN)  :: converged, stalled, at_floor
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    INTEGER :: unit, ios, i, n_nodes, n_elem
    ErrStat = 0
    ErrMsg = ''
    n_nodes = SIZE(q)/3
    n_elem = SIZE(conn, 2)
    CALL CD_Open_Write(unit, path, ios)
    IF (ios /= 0) THEN
      CALL fail(ErrStat, ErrMsg, 'cannot open output file: '//TRIM(path)); RETURN
    END IF
    WRITE (unit, '(A)') '# CableDyn static driver output'
    WRITE (unit, '(A,L1,A,I0,A,L1,A,L1)') '# converged=', converged, ' n_iter=', n_iter, &
      ' stalled=', stalled, ' at_floor=', at_floor
    WRITE (unit, '(A)') 'section,node,x,y,z'
    DO i = 1, n_nodes
      WRITE (unit, '(A,I0,3(A,ES23.15E3))') 'node,', i, ',', q(3*i - 2), ',', q(3*i - 1), ',', q(3*i)
    END DO
    WRITE (unit, '(A)') 'section,elem,node_a,node_b,tension_N'
    DO i = 1, n_elem
      WRITE (unit, '(A,I0,2(A,I0),A,ES23.15E3)') 'elem,', i, ',', conn(1, i), ',', conn(2, i), &
        ',', tension(i)
    END DO
    CLOSE (unit)
  END SUBROUTINE write_csv

  ! --------------------------------------------------------------------------- !

  PURE FUNCTION reshape3(q, n_dof) RESULT(nodes)
    !! Copy the flat positions-only state into a (3, n_nodes) node array.
    INTEGER, INTENT(IN) :: n_dof
    REAL(wp), INTENT(IN) :: q(n_dof)
    REAL(wp) :: nodes(3, n_dof/3)
    nodes = RESHAPE(q, [3, n_dof/3])
  END FUNCTION reshape3

  SUBROUTINE straight_line_seed(anchor, fairlead, l0, q0)
    !! Rest-proportional straight-line seed: place node i at anchor + frac_i *
    !! (fairlead - anchor), where frac_i is the unstretched arc-length fraction
    !! (cumulative l0) from the anchor. The fallback seed for a suspended / taut /
    !! level / vertical line that the grounded catenary cannot seed. Always valid for
    !! finite endpoints and positive lengths (both pre-validated by the caller).
    REAL(wp), INTENT(IN)  :: anchor(3), fairlead(3), l0(:)
    REAL(wp), INTENT(OUT) :: q0(:)
    INTEGER  :: n_elem, i
    REAL(wp) :: total, cum, frac
    n_elem = SIZE(l0)
    total = SUM(l0)
    q0(1:3) = anchor
    cum = CD_ZERO
    DO i = 1, n_elem
      cum = cum + l0(i)
      frac = cum/total                      ! total > 0 (lengths validated positive)
      q0(3*i + 1:3*i + 3) = anchor + frac*(fairlead - anchor)
    END DO
  END SUBROUTINE straight_line_seed

  PURE INTEGER FUNCTION count_tokens(s) RESULT(k)
    !! Number of whitespace-separated tokens in s (already comment-stripped and
    !! left-justified by next_record).
    CHARACTER(*), INTENT(IN) :: s
    INTEGER :: i
    LOGICAL :: in_tok
    k = 0
    in_tok = .FALSE.
    DO i = 1, LEN_TRIM(s)
      IF (s(i:i) == ' ' .OR. s(i:i) == ACHAR(9)) THEN   ! space or tab
        in_tok = .FALSE.
      ELSE IF (.NOT. in_tok) THEN
        in_tok = .TRUE.
        k = k + 1
      END IF
    END DO
  END FUNCTION count_tokens

  LOGICAL FUNCTION bad_count(line, k, unit, ErrStat, ErrMsg, what) RESULT(bad)
    !! Guard: returns .TRUE. (after failing closed and closing the unit) iff `line`
    !! does not hold EXACTLY k whitespace-separated tokens, so each parse site reads
    !! a strictly-shaped line via `IF (bad_count(...)) RETURN`. ``what`` names the
    !! expected layout for the error message.
    CHARACTER(*), INTENT(IN)  :: line, what
    INTEGER, INTENT(IN)  :: k, unit
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    ErrStat = 0
    ErrMsg = ''
    bad = (count_tokens(line) /= k)
    IF (bad) THEN
      CALL fail(ErrStat, ErrMsg, 'malformed line; expected '//TRIM(what))
      CLOSE (unit)
    END IF
  END FUNCTION bad_count

  PURE FUNCTION to_lower(s) RESULT(out)
    !! ASCII lowercase (for case-insensitive keyword/flag matching).
    CHARACTER(*), INTENT(IN) :: s
    CHARACTER(LEN(s)) :: out
    INTEGER :: i, c
    DO i = 1, LEN(s)
      c = IACHAR(s(i:i))
      IF (c >= IACHAR('A') .AND. c <= IACHAR('Z')) THEN
        out(i:i) = ACHAR(c + 32)
      ELSE
        out(i:i) = s(i:i)
      END IF
    END DO
  END FUNCTION to_lower

  SUBROUTINE fail(ErrStat, ErrMsg, msg)
    INTEGER, INTENT(OUT) :: ErrStat
    CHARACTER(*), INTENT(OUT) :: ErrMsg
    CHARACTER(*), INTENT(IN)  :: msg
    ErrStat = CD_DRIVER_BADINPUT
    ErrMsg = 'CableDyn_Driver: '//msg
  END SUBROUTINE fail

END MODULE CableDyn_Driver
