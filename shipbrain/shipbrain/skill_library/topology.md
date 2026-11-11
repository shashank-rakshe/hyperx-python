---
name: topology
description: topology optimisation / where material is needed - bracket shapes, lightening holes in web frames and floors, gussets; differentiable FE with TensorMesh
when: \b(topology|lightening holes?|lighten|material layout|weight saving|optimi[sz]e (the )?(bracket|web|floor|shape|layout)|where .* material)\b
---
1. Model the region as a 2D plate: L x H (mm), which edges are welded / supported (fixed), where the load acts
   (load_at [x, y]) and its size (force [Fx, Fy], N), how much material to keep (volfrac 0.3-0.6). Ask for what is
   missing or say what you assume.
2. topology(L, H, fixed, load_at, force, volfrac) -> picture + "keeping X % of the material gives Y % of the stiffness".
3. Answer: what the layout shows (load paths, where holes can go), the stiffness kept, and that the result is a
   concept - check plate buckling (plate_buckling), local stresses (cad_mesh + analysis_run) and class rules for
   minimum web height / hole sizes and their edge distances before using it.
4. A solid model (tetra / hexa) needing a fast or GPU solve: tensor_fem(file, fixed, loads).
