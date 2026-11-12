---
name: results-pictures
description: pictures of the model and of analysis results (stress, displacement) as png and ParaView files
when: \bpicture\b|\bvisuali[sz]|contour plot|show (me )?(the )?(stress|displacement)|render the (model|mesh)|paraview
---
# Pictures (show_result)

To show the user the model or a result, call `show_result`: file = the STEP / STL / mesh (.inp), field = von_mises or displacement (needs the analysis run first:
the CalculiX .frd next to the .inp), view = iso / front / top / side, vtu = true for a ParaView file. Tell the user the file name and the value range it
returned (min, max, units, deformation scale). Displacement is drawn deformed with the scale named in the answer - say it is exaggerated.
Shell stress picture: the largest value over the thickness at each node. Flow results (Elmer) get their own pictures from the same tool once Elmer has run.
