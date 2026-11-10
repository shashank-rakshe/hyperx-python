---
name: result-review
description: check or report an FE result - peak stress, pass or fail, hotspots, mesh good enough, compare runs
when: \.frd\b|(check|review|report|post.?process|summar).*\b(result|stress|run)\b
---
1. result_insight(file, yield_MPa=<from the profile or the question, else 235>, baseline=<older run if they compare>).
2. Answer with: peak stress and where, utilisation and PASS / FAIL, hotspot areas, elements to refine, change vs baseline.
3. Point to the .vtk file for ParaView; an engineer must review the report draft before it is used.
