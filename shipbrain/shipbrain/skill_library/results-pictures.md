---
name: results-pictures
description: pictures of the model and of analysis results (stress, displacement) as png and ParaView files
when: \bpicture\b|\bvisuali[sz]|contour plot|show (me )?(the )?(stress|displacement)|render the (model|mesh)|paraview|(stress|pressure|velocity|displacement) (at|near) (the )?(point|node|x ?=)
---
# Pictures (show_result)

To show the user the model or a result, call `show_result`: file = the STEP / STL / mesh (.inp), field = von_mises or displacement (needs the analysis run first:
the CalculiX .frd next to the .inp), view = iso / front / top / side, vtu = true for a ParaView file. Tell the user the file name and the value range it
returned (min, max, units, deformation scale). Displacement is drawn deformed with the scale named in the answer - say it is exaggerated.
Shell stress picture: the largest value over the thickness at each node. Flow results (Elmer) get their own pictures from the same tool once Elmer has run.

Pictures appear in the chat window by themselves (every png in a tool result's files), and a result with a viewer opens an interactive view in the right panel: the part
coloured by von Mises or displacement, hover over any place for the value, click to pin it. When the user asks for the value at a place ("what is the stress at x = 300, y = 0,
z = 500", "pressure in front of the plate at 1.2 m"), call `probe_result` with the mesh .inp (mm), the OpenFOAM case folder (name_flow, metres) or the Elmer .vtu (metres) and the
coordinates: it gives the value at the nearest node or cell and says how far that is from the point asked for - quote that distance.
