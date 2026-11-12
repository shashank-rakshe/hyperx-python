---
name: design-blocks
description: early-stage ship design from physical blocks: weight and centre of gravity by group, shall / should requirements
when: building blocks?|\bDBB\b|design building block|weight (budget|estimate) of the (ship|vessel)|(shall|should) requirements?|requirements? (status|check) for the (ship|design)
---
# Design building blocks (dbb_blocks)

The vessel as blocks - volumes and plan areas grouped by function (cargo, machinery, accommodation, structure ...), each with a density and a centre of gravity - linked to requirements. `dbb_blocks` sums weight, volume
and area per block and per group, gives the total weight and centre of gravity, and the status of every requirement: red = the shall is not met, green = between shall and should, orange = beyond the should (more than needed).
- Metrics: weight, volume, plan area (of the linked blocks or a group), total weight, and length / beam / height of the hull (give hull = {L, B, D}).
- The result carries `weights_for_hydrostatics`: pass it as the weights of ship_hydrostatics or gz_curve to get draft, GM and the GZ curve of the design; then hull_generate for a hull around the blocks.
- Ask for what is missing: densities (t/m3; a tank of liquid cargo: 0.85 to 1.025 times its fullness), centres of gravity, and the shall values. Do not invent them. Steel weight can be a block with volume = steel
  volume and density 7.85 t/m3 (or an estimate from the hull).
- Say it is an early-stage sum: no structure sizing, no real hull lines, no stability approval.
