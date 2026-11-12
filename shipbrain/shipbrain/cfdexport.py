"""
CFD cases for programs ShipBrain cannot run here (they need a licence): ANSYS Fluent and Simcenter STAR-CCM+ - the case is set up by ShipBrain and handed over:

  <name>.msh          the mesh in Fluent's ASCII format, made by ShipBrain's own grid (fluentmesh.py; checked by reading it back with OpenFOAM's Fluent importer)
  <name>_setup.txt    the case in plain words: geometry, fluid, boundary conditions, models, what to report - the same numbers ShipBrain's OpenFOAM run uses
  <name>_fluent.py    a PyFluent script that sets this up and runs it            (written from the PyFluent documentation; NOT run - no Fluent here)
  <name>_starccm.java a STAR-CCM+ macro that imports the mesh and sets it up    (written from the STAR-CCM+ API; NOT run - no STAR-CCM+ here)

Results come back through files: export the fields as CSV (Fluent: File > Export > Solution Data, ASCII; STAR-CCM+: export a table / Plot > CSV) and upload them:
probe_result reads the value at any place and show_result draws them (tabfield.py). The same case runs in OpenFOAM with openfoam_flow, which is how the numbers can be cross-checked.
"""
import os, shutil, tempfile

from . import openfoam, fluentmesh

TARGETS = ('fluent', 'starccm')
ZONES = {'inlet': 'velocity-inlet', 'outlet': 'pressure-outlet', 'floor': 'wall', 'body': 'wall', 'top': 'symmetry', 'sides': 'symmetry', 'frontAndBack': 'symmetry'}


def export(target, workdir, name, **kw):
    if target not in TARGETS:
        raise ValueError('target must be one of ' + ', '.join(TARGETS))
    tmp = tempfile.mkdtemp(prefix='sb_cfdx_')
    try:
        info = openfoam.build_case(os.path.join(tmp, 'of'), **kw)
    finally:
        pass
    topo = info['grid']['topology']
    msh = os.path.join(workdir, name + '.msh')
    zt = {p: ZONES.get(p, 'wall') for p, _, _ in topo['patches']}
    fluentmesh.write_msh(topo, zt, msh)
    shutil.rmtree(tmp, ignore_errors=True)
    rho, nu, U = info['rho'], info['nu'], info['U']
    turb = info['turbulence']
    setup = _setup_text(name, info, zt, kw)
    open(os.path.join(workdir, name + '_setup.txt'), 'w').write(setup)
    files = [name + '.msh', name + '_setup.txt']
    if target == 'fluent':
        open(os.path.join(workdir, name + '_fluent.py'), 'w').write(_pyfluent(name, rho, nu, U, turb, zt))
        files.append(name + '_fluent.py')
    else:
        open(os.path.join(workdir, name + '_starccm.java'), 'w').write(_starccm(name, rho, nu, U, turb))
        files.append(name + '_starccm.java')
    return {'target': target, 'files': files, 'cells': info['cells'], 'zones': zt, 'rho': rho, 'mu': rho * nu, 'U': U, 'turbulence': turb, 'tested_in_the_target_program': False}


def _setup_text(name, info, zt, kw):
    L = [f'CASE {name} - set up by ShipBrain', '', f"Mesh: {name}.msh ({info['cells']:,} hexahedral cells), metres.", f"Fluid: density {info['rho']} kg/m3, dynamic viscosity {info['rho'] * info['nu']:.6g} Pa s (kinematic {info['nu']:.6g} m2/s).",
         f"Flow: steady, incompressible, {'laminar' if info['turbulence'] == 'laminar' else 'SST k-omega with wall functions'}; inlet velocity {info['U']} m/s along +x; gravity off.", '', 'Boundaries:']
    nice = {'velocity-inlet': 'velocity inlet (normal to the face)', 'pressure-outlet': 'pressure outlet, 0 Pa gauge', 'wall': 'wall, no slip', 'symmetry': 'symmetry (slip)'}
    for z, t in zt.items():
        L.append(f'  {z}: {nice[t]}')
    if info['turbulence'] != 'laminar':
        L.append('  inlet turbulence: intensity 5 %, viscosity ratio 10')
    L += ['', 'Report: force on the zone "body" (x = drag, y = lift), pressure and velocity fields; export the solution data as CSV (x, y, z and the fields) for ShipBrain.',
          'Cross-check: the same case runs in OpenFOAM with ShipBrain (openfoam_flow); the two should agree to within a few percent of drag.']
    return '\n'.join(L) + '\n'


def _pyfluent(name, rho, nu, U, turb, zt):
    mu = rho * nu
    return f'''"""ShipBrain case {name} for ANSYS Fluent through PyFluent (pip install ansys-fluent-core).
Written from the PyFluent documentation and NOT run by ShipBrain (no Fluent here): the settings paths below follow the 0.2x / 2024-2025 API; if a line fails,
the error names the setting - adjust that line, or set the case up by hand from {name}_setup.txt."""
import ansys.fluent.core as pyfluent

solver = pyfluent.launch_fluent(mode="solver", precision="double", processor_count=4, dimension=3)
s = solver.settings
s.file.read_case(file_name="{name}.msh")
s.setup.general.solver.type = "pressure-based"
s.setup.general.solver.time = "steady"
{"s.setup.models.viscous.model = 'laminar'" if turb == 'laminar' else "s.setup.models.viscous.model = 'k-omega'" + chr(10) + "s.setup.models.viscous.k_omega_model = 'sst'"}
fluid = s.setup.materials.fluid["air"]            # the default fluid is edited to the case fluid
fluid.density.option = "constant"; fluid.density.value = {rho}
fluid.viscosity.option = "constant"; fluid.viscosity.value = {mu:.8g}
bc = s.setup.boundary_conditions
inlet = bc.velocity_inlet["inlet"]
inlet.momentum.velocity_specification_method = "Magnitude, Normal to Boundary"
inlet.momentum.velocity_magnitude.value = {U}
{"" if turb == 'laminar' else "inlet.turbulence.turbulence_specification = 'Intensity and Viscosity Ratio'" + chr(10) + "inlet.turbulence.turbulent_intensity = 0.05" + chr(10) + "inlet.turbulence.turbulent_viscosity_ratio = 10"}
bc.pressure_outlet["outlet"].momentum.gauge_pressure.value = 0
s.solution.methods.p_v_coupling.flow_scheme = "Coupled"
s.solution.initialization.initialization_type = "standard"
s.solution.initialization.standard_initialize()
s.solution.run_calculation.iter_count = 800
s.solution.run_calculation.calculate()
# force on the body and an ASCII export for ShipBrain
s.results.report.forces.compute  # forces report: use the Fluent GUI / TUI  report > forces > wall-forces  for zone "body"
s.file.export.ascii(file_name="{name}_fields", surface_name_list=["body"], delimiter="comma", cell_func_domain=["pressure", "velocity-magnitude", "x-velocity"])
solver.exit()
'''


def _starccm(name, rho, nu, U, turb):
    mu = rho * nu
    return f'''// ShipBrain case {name} for STAR-CCM+ (File > Play Macro, or starccm+ -batch {name}_starccm.java).
// Written from the STAR-CCM+ Java API and NOT compiled or run by ShipBrain (no STAR-CCM+ here): if a class or method name differs in your version the compiler says which;
// then adjust it or set the case up by hand from {name}_setup.txt. The mesh is imported as a volume mesh (Fluent .msh).
package macro;

import star.common.*;
import star.base.neo.*;
import star.flow.*;
import star.material.*;
import star.metrics.*;
{"" if turb == 'laminar' else "import star.turbulence.*;" + chr(10) + "import star.kwturb.*;"}

public class {name.capitalize()}Macro extends StarMacro {{
  public void execute() {{
    Simulation sim = getActiveSimulation();
    sim.importVolumeMesh(resolvePath("{name}.msh"));
    PhysicsContinuum phys = (PhysicsContinuum) sim.getContinuumManager().createContinuum(PhysicsContinuum.class);
    phys.enable(ThreeDimensionalModel.class);
    phys.enable(SteadyModel.class);
    phys.enable(SingleComponentLiquidModel.class);
    phys.enable(ConstantDensityModel.class);
    phys.enable(SegregatedFlowModel.class);
{"    phys.enable(LaminarModel.class);" if turb == 'laminar' else "    phys.enable(TurbulentModel.class);" + chr(10) + "    phys.enable(RansTurbulenceModel.class);" + chr(10) + "    phys.enable(KOmegaTurbulence.class);" + chr(10) + "    phys.enable(SstKwTurbModel.class);"}
    SingleComponentLiquidModel liquid = phys.getModelManager().getModel(SingleComponentLiquidModel.class);
    Liquid fluid = (Liquid) liquid.getMaterial();
    ((ConstantMaterialPropertyMethod) fluid.getMaterialProperties().getMaterialProperty(ConstantDensityProperty.class).getMethod()).getQuantity().setValue({rho});
    ((ConstantMaterialPropertyMethod) fluid.getMaterialProperties().getMaterialProperty(DynamicViscosityProperty.class).getMethod()).getQuantity().setValue({mu:.8g});
    Region region = sim.getRegionManager().getRegion("fluid-zone");
    region.setPhysicsContinuum(phys);
    Boundary inlet = region.getBoundaryManager().getBoundary("inlet");
    inlet.setBoundaryType(sim.get(ConditionTypeManager.class).get(InletBoundary.class));
    inlet.getValues().get(VelocityMagnitudeProfile.class).getMethod(ConstantScalarProfileMethod.class).getQuantity().setValue({U});
    Boundary outlet = region.getBoundaryManager().getBoundary("outlet");
    outlet.setBoundaryType(sim.get(ConditionTypeManager.class).get(PressureBoundary.class));
    for (String n : new String[] {{"top", "sides"}}) {{
      Boundary b = region.getBoundaryManager().getBoundary(n);
      b.setBoundaryType(sim.get(ConditionTypeManager.class).get(SymmetryBoundary.class));
    }}
    sim.getSimulationIterator().run();
    // reports and CSV export: create a Force report on boundary "body" and an XYZ internal table in the GUI, then Export to CSV
  }}
}}
'''
