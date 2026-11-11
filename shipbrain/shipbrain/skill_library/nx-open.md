---
name: nx-open
description: Siemens NX / Simcenter 3D automation - NX Open Python journals (CAD and CAE pre / post-processing), renaming NX files with their links
when: \b(nx ?open|journal|simcenter|siemens nx|\.sim\b|\.fem\b.*nx|nx (cae|cad|part|assembly)|rename .*\.prt|ug_edit)\b
---
1. Only to READ an NX file (geometry, size, STEP): native_cad / file_info - no NX needed.
2. To DO something inside NX (solve, add loads / constraints, mesh collectors, export or envelope results, list bodies or
   features, mass properties, screenshots): nx_open(op="find", query=<what the user wants>) -> pick functions, check
   each with nx_open(op="syntax", name=...) -> nx_open(op="journal", calls=[{fn, args, as}], part=<.prt/.sim>).
   Use only functions find / syntax return; arguments by their exact names; "$name" passes an earlier result,
   for_each:"$name" repeats a call per item. Never invent NX Open calls.
3. Answer: what the journal does step by step, the file, and how to run it (it runs by itself when NX is installed;
   otherwise NX: File > Execute > NX Open... / Alt+F8). Units: get_body_properties gives metres and kg.
4. Renaming a .prt without breaking assemblies / drawings: nx_rename(file, new_name) (Windows + NX); otherwise say
   to rename inside NX.
