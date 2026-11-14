---
name: standard-parts
description: dimensions of standard bolts, nuts, washers, rolled sections, pipes and flanges from the BOLTS tables
when: iso ?\d{4}|din ?\d{3,5}|\bipe ?\d|\bhe[abm] ?\d|across flats|hex (bolt|nut|screw)|washer dimension|section dimension|nominal pipe size
---
# Standard parts (standard_part)

For the size of a standard part - bolt head across flats, nut height, washer diameter, IPE/HEA/HEB/HEM section depth, flange or pipe
dimensions - call `standard_part` with the request in words ("hex bolt ISO 4017 M20 length 60", "IPE 300", "NPS 4 pipe"). The numbers come
from the BOLTS library tables (copied in vendor/bolts); never quote them from memory.

- With a size the answer is one table row (mm). I-sections also get area, second moments and mass per metre from those dimensions (within about 1 % of the catalogue).
- Without a size the tool lists the matching standards and their size ranges: ask the user for the size.
- A size that is not in the table (M99) is refused with the range - say so; do not invent a value.
- ASME pipe tables are in inches; the tool adds the mm values (NPS 4 schedule 40 = 114.3 x 6.02 mm).
- Strength, capacity and material grade are not in these tables: use the connection or frame tools for those.
