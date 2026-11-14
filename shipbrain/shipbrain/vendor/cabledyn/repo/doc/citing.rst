.. SPDX-License-Identifier: Apache-2.0

How to cite
===========

If CableDyn contributes to published work, cite the journal article that describes the
formulation and its validation. To record the exact software version used, also cite the
software release. Both entries are kept in the repository's ``CITATION.cff``, which GitHub
exposes through its **Cite this repository** function.

Journal article (preferred citation)
------------------------------------

Seo, J. H., Lim, J., Shim, K. & Song, J. (2026). CableDyn: Curvature-resolving implicit
finite-element analysis of mooring lines and dynamic power cables for floating offshore
wind. *Ocean Engineering* 368 (Part 2), 128332.
https://doi.org/10.1016/j.oceaneng.2026.128332

All authors: Department of Naval Architecture and Ocean Engineering, Inha University,
Incheon, Republic of Korea.

.. code-block:: bibtex

   @article{Seo2026CableDyn,
     author  = {Seo, Jae Hoon and Lim, Junsoo and Shim, Kyusung and Song, Jinwoo},
     title   = {{CableDyn}: Curvature-resolving implicit finite-element analysis of
                mooring lines and dynamic power cables for floating offshore wind},
     journal = {Ocean Engineering},
     volume  = {368},
     number  = {Part 2},
     pages   = {128332},
     year    = {2026},
     doi     = {10.1016/j.oceaneng.2026.128332}
   }

Software release
----------------

Seo, J. H. (2026). *CableDyn: Geometrically exact finite-element statics and dynamics of
mooring lines and dynamic power cables for floating offshore wind* (version 0.4.0) [Computer
software]. https://github.com/SMI-Lab-Inha/CableDyn

.. code-block:: bibtex

   @software{CableDyn_0_3_0,
     author  = {Seo, Jae Hoon},
     title   = {{CableDyn}: Geometrically exact finite-element statics and dynamics of mooring
                lines and dynamic power cables for floating offshore wind},
     version = {0.4.0},
     year    = {2026},
     url     = {https://github.com/SMI-Lab-Inha/CableDyn},
     license = {Apache-2.0}
   }

When results depend on a particular release, quote the version reported in the solver banner
(``CableDyn v0.4.2``) together with the options recorded for the run.

Relation to the journal article
-------------------------------

The journal article records the formulation as published; CableDyn continues to develop, and its
defaults follow the methods the project currently recommends. The published methods remain
selectable, so the article's calculations can be reproduced. Differences from the article:

* **End tension channels.** The article reports mooring fairlead and anchor tensions as the end
  element's axial tension. ``FairTen`` and ``AnchTen`` report the end force, as defined in
  :doc:`outputs`. That force adds axial damping and the end node's share of weight, seabed
  contact, and drag at the actual velocity; the weight share is about half the end element's
  submerged weight, which on a coarse mesh can reach several percent of a grounded chain's
  anchor tension. This matches the end-force convention of MoorDyn and OrcaFlex. The
  distributed tension along a line keeps the article's definition
  :math:`T = EA(\lVert\partial\mathbf r/\partial s\rVert - 1)`.
* **Finite-EI time integration.** The article evaluates the internal force at the
  generalised-α blended configuration. By default, CableDyn blends the internal forces instead.
  This removes a time-step-dependent stretch bias on rapidly rotating cable tangents. Set
  ``False alpha_force_blend`` (see :doc:`options`) to reproduce the article's scheme.
* **Finite-EI static initialisation.** By default, the static solution starts from a catenary
  and ramps up the bending stiffness in continuation, which is faster and more robust. On the
  article's cables it reaches the same equilibrium to solver tolerance. Set
  ``sequenced cable_statics`` to run the article's mesh-sequenced procedure first.

Every CableDyn result in the article, re-run in both configurations, is listed in
`validation/PAPER_REPRODUCTION.md
<https://github.com/SMI-Lab-Inha/CableDyn/blob/main/validation/PAPER_REPRODUCTION.md>`_.

Citing methods and reference data
---------------------------------

CableDyn implements established methods — the cubic-Hermite Kirchhoff-rod element, Morison
hydrodynamics, linear wave theory, and the generalised-α integrator — and is validated
against published reference designs. When a study relies on a specific method or data set,
cite the original source listed in :doc:`references` as well.
