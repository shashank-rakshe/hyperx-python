---
name: ocx-model
description: OCX / 3Docx ship structure models - syntax of any OCX class, read, validate, compare, mesh, write, STEP
when: \b(ocx|3docx|\.3docx|open class 3d exchange)\b
---
1. A question about OCX syntax (an element, attribute, allowed value, version difference): ocx_syntax(name, version) -
   answer from its result only (required parts in order, allowed values, XML example). Words instead of a name search
   the library; changes_from=<old version> lists what changed. Default version 3.2.0; all of 2.8.6 ... 3.2.0 are known.
2. An OCX file: ocx_read(file) first (panels, plates, thickness, sections, frames), then as asked:
   - ocx_validate(file): valid against the official XSD of its version, or the problems with their place;
   - compare_structures(a, b) works directly on .3docx files (also OCX against a drawing-read or yard model);
   - structure_to_mesh(<name>_structure.json) for an FE model; ocx_to_step(file) for 3D CAD.
3. Making OCX: ocx_write(structure JSON or OCX or ship XML) -> OCX 3.2.0 checked against the official XSD.
4. Never invent OCX element names: if ocx_syntax does not know it, say so and give the closest names it found.
