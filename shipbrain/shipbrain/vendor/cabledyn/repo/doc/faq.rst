.. SPDX-License-Identifier: Apache-2.0

Frequently asked questions
==========================

Answers to recurring questions about CableDyn settings and results. For a rejected deck, a
non-zero exit code, or a named error message, see :doc:`troubleshooting`.

Modelling and inputs
--------------------

.. admonition:: Do I need a water depth?
   :class: note

   No. ``WtrDpth`` is optional — omit it for a suspended or taut line with no bottom contact.
   Supply it (or a ``bathymetryFile``) only when the line touches the seabed. Deck ``waves`` do
   require ``WtrDpth``.

.. admonition:: Do I have to rewrite a MoorDyn deck's LINES into SECTIONS?
   :class: note

   No. The stock 7-column MoorDyn row ``ID LineType AttachA AttachB UnstrLen NumSegs Outputs`` is
   accepted as a one-section line, and anchor-first lines are turned fairlead-first
   automatically. Use ``SECTIONS`` when one line object is built from several line types. See
   :doc:`driver_format`.

.. admonition:: Which solver path is my line on?
   :class: note

   It is decided per line by its sections' line-type ``EI``: a line whose sections all have
   ``EI = 0`` uses the cable path; a line with any ``EI > 0`` section uses the finite-EI
   cubic-Hermite path. A mixed deck can carry both kinds of line. See :doc:`concepts`.

.. admonition:: Can I set the solver tolerance?
   :class: note

   The dynamic Newton controls, yes: ``dynamic_solver rel abs max_iter backtracks [rhoInf]``
   sets the relative and absolute tolerances, the iteration budget, and the line-search
   backtracks (see :doc:`options` for which controls each route uses). The static-solver
   tolerances are built in, and keys like ``staticRelTol`` are rejected as unknown; this keeps
   every static initial condition reproducible.

Results
-------

.. admonition:: Why are my velocities and accelerations zero?
   :class: note

   ``L<L>N<J>v…`` / ``…a…`` channels are zero on a static-only run — there is no motion at the static
   IC. Add ``dtM``/``TMax`` (and, for a driven end, a ``motionFile``) to march dynamics.

.. admonition:: Why is ``AnchAngle`` about 90 degrees?
   :class: note

   ``FairAngle`` / ``AnchAngle`` are aliases of the **declinations** from +GZ (as OrcaFlex defines
   them), so a horizontal anchor segment is 90 degrees and a downward fairlead tangent exceeds 90
   degrees. Request ``FairIncl`` / ``AnchIncl`` for signed inclination below horizontal: zero is
   horizontal and positive is downward. ``FairDecl`` / ``AnchDecl`` provide explicitly named
   declinations.

.. admonition:: Why does static tension differ slightly from MoorDyn?
   :class: note

   CableDyn's static IC is a **Newton equilibrium**; MoorDyn reaches its
   initial state by drag-scaled dynamic relaxation. The two agree within the validated band
   (0.13–1.59 % on the validated chain cases); a small offset between the two approaches is
   expected. See :doc:`validation`.

.. admonition:: What should I do when the tensile monitor reports compression?
   :class: warning

   Treat the reported force, location, and time as an engineering validity check. ``warn`` allows a
   long run to finish and counts every accepted integration step outside the declared strain
   band; it does not make a compressive cable state physical. Small, localised excursions at a
   grounded tail may justify a documented tolerance study. Large or fatigue-region excursions require
   inspection of the motion convention, spatial and temporal convergence, contact state, and cable
   configuration before the response is used. Select ``True`` when any out-of-band compression must
   reject the step.

OpenFAST coupling
-----------------

.. admonition:: Why do CableDyn channels look stepped in an OpenFAST plot?
   :class: note

   CableDyn solves on ``dtM`` (the glue ``DT`` unless the deck sets a larger ``dtM``) and, with a
   larger ``dtM``, holds its committed channels between solves (its coupled loads are
   extrapolated from the last two solves) on the faster glue clock of
   OpenFAST (maintained by NLR, the National Laboratory of the Rockies, formerly NREL). A smaller
   ``DT_Out`` records more copies of the held value; it does not add physical bandwidth. Plot
   ``<OpenFASTRoot>.CD.out`` for the solver-native record containing one row per genuine CableDyn
   solve. A larger ``dtM`` is faster; demonstrate damage/range convergence by reducing it, and
   heed the initialisation note on a line whose axial period it does not resolve
   (:doc:`modeling`).

.. admonition:: Why did ``dtM = 0.025 s`` make my coupled run much slower?
   :class: note

   Equal ``dtM`` and OpenFAST ``DT`` (the default) request a nonlinear CableDyn solve on every glue
   step, four times as many as ``dtM = 0.1 s`` at ``DT = 0.025 s``. The release executables are serial; the
   threading advice in this answer applies only to source builds configured with OpenMP. On such
   builds an ``EI = 0`` line evaluates its elements in parallel only from 8192 elements and a
   finite-EI cable from 32 elements, while separate lines can still run concurrently; nested
   OpenMP teams are suppressed automatically. Keep the linear-algebra library to one thread when
   OpenMP parallelism is enabled (for example ``OPENBLAS_NUM_THREADS=1``), then time the complete
   OpenFAST model. A fast isolated mooring
   benchmark does **not** imply a fast coupled run: OpenFAST may call ``CalcOutput`` several times
   per physical step with different trial kinematics. Set the environment variable
   ``CABLEDYN_PROFILE=1`` before running ``openfast.exe`` to separate CableDyn solve, SeaState
   sampling, output-probe, and native-I/O time, and to split the steps of ``EI = 0`` lines and
   finite-EI cables into residual, tangent, factorisation and back-substitution time (with
   ``OMP_NUM_THREADS=1`` the line times add up to the solve time). The ``profile parts`` line
   splits ``CalcOutput`` further, into the overlay and restore of the current kinematics (at
   ``nsuper = 1``) and the output channels, and splits the SeaState sampling into the node
   queries, the grid checks and the hand-over of the fields; the ``Hermite assembly`` line splits
   the cable assemblies into their sections (:ref:`cli-profile`). The standalone driver reads
   the same variable and prints its own breakdown (:ref:`cli-profile`). Keep ``ModCoupling`` fixed while
   comparing configurations. Do not switch to loose coupling merely to meet a wall-clock target; on
   the IEA-15MW reference model it materially changed platform and tension responses. Test
   ``OMP_NUM_THREADS=1`` as well as the intended threaded setting: three short lines can be too
   little work to amortise OpenMP overhead.

   Finally, require normal OpenFAST termination, and compare the ``Time Ratio`` that OpenFAST
   reports with the default solver settings (see :doc:`openfast`).

   A finite-bending interval that converges algebraically but exceeds the mesh-aware temporal
   increment check is retried internally with generalised-alpha substeps. A stalled tension-only
   standalone step uses the same bounded subdivision policy. Prescribed position, velocity, and
   acceleration remain one kinematically consistent C2 trajectory. The default recovery ceiling is
   1024 and ``recovery_max_substeps`` can adjust it without changing the committed host grid. A
   final failure reports the simulated interval, ceiling, and maximum prescribed displacement
   increment. The profiler reports the recovery count. Use a checkpoint (``ChkptTime`` in the
   ``.fst`` file) to replay any event without rerunning the full transient.
