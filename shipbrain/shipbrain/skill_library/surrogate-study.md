---
name: surrogate-study
description: many similar FE runs, design space, parametric study or instant answers - build and use an AI surrogate
when: surrogate|reduced.order|\brom\b|parametric|design space|many (runs|cases|variants)|instant(ly)? (stress|answer)
---
1. surrogate_build(ranges={L:[..], B:[..], t:[..], p:[..]}, name=<short name>) - real CalculiX runs, adaptive, leave-one-out accuracy.
2. Tell the accuracy honestly (mean and worst leave-one-out %) and the time per prediction.
3. surrogate_predict(name, params) for each question; if it was not confident it already ran the real solver - say so.
4. The .hpp file lets a C++ program call the same model.
