# CO2 sequestration plant — Oslo

A DEXPI 2.0 **process** model of a demonstration CO2 handling and injection system, built for the
OPC Materials Subject Group.

| | |
| --- | --- |
| Author | David Cameron, University of Oslo |
| Date | March 2026 |
| Licence | CC BY 4.0 |
| Authoring tool | XMLSpy |
| Reference | <https://www.sciencedirect.com/science/article/pii/S0098135423004349#ecom0001> |

## Files

| File | What it is |
| --- | --- |
| `CO2TerminalExample.xml` | The model, **exactly as contributed**. Do not edit — it is a fixture for the loader. |
| `CO2TerminalExample-corrected.xml` | The same model with three misspellings fixed. Its leading XML comment lists every change and every deliberate non-change. |
| `2026-05-04 CO2 for DEXPI 2 and OPC.pdf` | Slides showing the model graphically (converted from the original PowerPoint). |

## Loading it

This is a process model, so it needs the lenient mode, because most of its objects
omit the mandatory `Identifier`:

```python
from pydexpi.loaders.public import load_xml_file

model = load_xml_file("CO2TerminalExample.xml", strict=False)
process = model.conceptualModel          # ProcessModel
len(process.processConnections)          # 122, of which 121 are wired at both ends
```

Loading the original reports the file's own defects through the serializer's error registry:

```python
from pydexpi.loaders.xml_serializer import DexpiXmlSerializer

serializer = DexpiXmlSerializer(strict=False)
serializer.load_from_string(open("CO2TerminalExample.xml", encoding="utf-8").read())
for entry in serializer.loader.error_registry.get_errors():
    print(entry.level, entry.message)
```
