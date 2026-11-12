---
name: openhcm-tool-knowledge
description: OpenHCM consortium format, the Bureau Veritas web viewer and the limits of ShipBrain reader
when: what is openhcm|openhcm (viewer|schema|consortium|standard)
---
# OpenHCM - tool knowledge

OpenHCM (https://github.com/OpenHCMStandard) is maintained by the OpenHCM Consortium; the web viewer (Bureau Veritas, Apache-2.0, JavaScript / three.js) shows a model in the browser without uploading it. Its code (loader,
mesh builder: plates, stiffeners, compartment tree) is in the knowledge pack `OpenHCMViewer` - search it for how plates with holes are triangulated or how stiffener flanges are built. The schema itself is at
openhcmstandard.github.io/Data-Format. ShipBrain's `openhcm_read` is its own Python reader written to the element names the viewer reads and tested on a model written to that description (no real OpenHCM file was
available): if a real file fails, send it, do not assume the reader is complete (inspection records, thickness measurements and coatings are not read).
