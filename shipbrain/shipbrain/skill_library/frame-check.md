---
name: frame-check
description: frame, beam, column, portal, truss or pipe support check - forces, stresses, deflection, load combinations
when: \b(frame(?!-?field)|portal|truss|cantilever|beam|column|pipe ?rack|pipe support)s?\b
---
1. Build nodes (mm) and members with their sections (pipe [OD, t] | rect | I [h, b, tw, tf] | box | A, Iy, Iz, J).
2. Supports: fixed / pinned / roller (or a dof list). Loads per case: G (dead, add self_weight), Q (live), W (wind).
3. frame_solve(...) - Awatif's solver; combinations ULS-1 (1.35G + 1.5Q + 0.9W), ULS-2 (1.35G + 1.05Q + 1.5W), SLS.
4. For a pipe model from pipe_extract: frame_solve(file=<piping .inp>, supports=[{"at": [x, y, z], "type": "fixed"}], loads={"G": [{"self_weight": 1}]}).
5. Answer: governing combination and member, stress and utilisation (PASS / FAIL), max deflection, the report file.
   Buckling, shear and local checks are not included: say so.
