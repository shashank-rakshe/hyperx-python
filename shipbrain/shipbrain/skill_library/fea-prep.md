---
name: fea-prep
description: get an uploaded CAD model ready for FEA - clean, simplify, mid-surface, mesh
when: (clean ?up|defeature|simplif|prepare|ready)\b.*\b(fea|fe model|mesh|analysis)|(fea|mesh).*(clean ?up|prepare)
---
1. file_info(file) - say in one line what the model is (solids, plates, pipes, size).
2. repair_model(file, request=<the user's own words>) - removes the small features they named, then sews and fixes.
3. Thin plates: surface_extract(<repaired file>, kind="mid", mesh_size=<their size or 100>); a solid part: cad_mesh.
4. Piping in the model: also pipe_extract(<repaired file>).
5. Answer: what was removed, what was kept and why, mesh size and element count, the files written.
