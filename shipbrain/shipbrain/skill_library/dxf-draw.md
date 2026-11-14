---
name: dxf-draw
description: draw 2D drawings from plain words (plates with holes and slots, stiffened panels, flanges, free shapes) into DXF with layers, dimensions and title block; check a DXF for drafting problems
when: \b(draw|drawing of|sketch|dxf|title block|dimensioned|general arrangement|drafting|make a drawing)\b
---
1. Turn the user's words into `parts` (mm). Positions of holes are measured from the lower-left corner of the part: say so.
   Convert feet / inches first (convert_units). Missing KEY sizes (length, width, diameter) -> ask one short question;
   secondary things (thickness label, sheet, scale) -> use defaults and say them: A3, scale chosen automatically, dims on.
2. dxf_draw(parts, title, sheet, scale, notes). Then tell in words what was drawn (parts, sizes, how many holes and where),
   the scale and sheet, the file and the preview picture.
3. An error says what does not fit (a hole outside the plate, a bore larger than the flange): tell the user and offer the
   corrected value, then draw again.
4. An existing DXF: dxf_check(file) for drafting problems (layers, duplicates, gaps, typed-over dimensions);
   drawing_check(file) for the arithmetic written on it; compare_drawings for revisions.
5. Never invent sizes. Class-rule minimum thicknesses or spacings come from class_rule, not from the drawing tool.
