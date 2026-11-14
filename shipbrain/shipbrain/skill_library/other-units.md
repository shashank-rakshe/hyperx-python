---
name: other-units
description: the user gives sizes, loads or stresses in other units (inch, ft, psi, ksi, kip, m, kN, kPa, bar)
when: \b\d+(\.\d+)?\s*(in|inch|inches|ft|feet|psi|ksi|kip|kips|lbf|kpa|kn|bar)\b
---
1. convert_units(values=[...]) - every input into mm, N, MPa.
2. Call the tool with the converted numbers.
3. convert_units back into the user's units; answer in their units with mm / MPa in brackets.
