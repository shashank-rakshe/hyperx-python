---
name: xc-assessment
description: reinforced concrete and steel member code checks with XC (Eurocode 2 / 3, ACI 318, AISC 360, EHE)
when: reinforced concrete|rebar|eurocode ?[23]|\bEC[23]\b|\bEHE\b|ACI ?318|interaction diagram|punching shear|fibre? section
---
# Code assessments with XC (xc_run)

For concrete or steel MEMBER checks against a design code (reinforced concrete: Eurocode 2, ACI 318, EHE, SIA 262; steel: Eurocode 3,
AISC 360, EAE), fibre sections and interaction diagrams, non-linear static / dynamic runs and construction phases, ShipBrain uses XC
(open source, GPL; the whole repository is in the knowledge pack `xc`). choose_engine routes such questions to XC.

Steps:
1. Ask for what is missing: member and section, materials / grades, lengths and supports, loads or design forces, code and checks wanted.
2. knowledge_search with scope "xc" for the closest worked example (the XC verification models under verif/tests/materials: ec2, ec3, aci, ehe,
   sia262, sia263, eae, ... : each is a complete runnable script with its expected numbers).
3. Adapt that script to the user's numbers (change inputs only; keep the XC calls as they are in the example), make it PRINT or write the results
   (utilisation ratios, resistances), and run it with xc_run.
4. Report what the script printed, in plain words: governing check, utilisation, pass / fail, and the assumptions. Never state numbers XC did not produce.
If XC is not installed the tool returns an install card (Docker image engthiago/xcfem or the native build): give it to the user, keep the script
(it is saved in the work folder) and meanwhile use the hand-formula tools (plate_check, stiffener_check, section_props, bolt, bolt_group, connection_check).
A script that fails: read the error lines, fix the input or the call against the example, run again; do not guess.
