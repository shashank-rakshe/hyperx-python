"""
DWSIM (https://github.com/DanWBR/dwsim10, GPL-3.0): the open-source chemical process simulator - thermodynamics
(property packages: Peng-Robinson, SRK, NRTL, UNIQUAC, steam tables, ...), unit operations (heaters, pumps, compressors,
separators, columns, reactors, heat exchangers ...), steady state and dynamics. ShipBrain runs its own MCP server
(58 operations, tools/DWSIM.MCPServer), unchanged, as a separate program through shipbrain.mcp_client.

  exe()                  the built server, or None
  build()                clone DWSIM 10 (with its submodule) and `dotnet publish` the MCP server once (.NET 10 SDK)
  run(file)              load a DWSIM flowsheet (.dwxml / .dwxmz), solve it, return every stream and unit operation
  flash(...)             one material stream: compounds + composition + T + P + flow -> phases, densities, enthalpy
The server's own operations are also there as they are: mcp_tools / mcp_call with server "dwsim".
"""
import glob, os, shutil, subprocess, sys

CACHE = os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'dwsim')
REPO = 'https://github.com/DanWBR/dwsim10.git'
_CLIENT = []


def exe():
    for c in (os.environ.get('SHIPBRAIN_DWSIM_MCP'), os.path.join(CACHE, 'mcp', 'dwsim-mcp'), os.path.join(CACHE, 'mcp', 'dwsim-mcp.exe')):
        if c and os.path.exists(c):
            return c
    return shutil.which('dwsim-mcp')


def build(log=print):
    if not shutil.which('dotnet'):
        raise RuntimeError('the .NET 10 SDK is needed to build the DWSIM MCP server (dotnet not found)')
    if not shutil.which('git'):
        raise RuntimeError('git is needed to fetch DWSIM')
    src = os.path.join(CACHE, 'src')
    if not os.path.isdir(os.path.join(src, 'tools', 'DWSIM.MCPServer')):
        shutil.rmtree(src, ignore_errors=True)
        r = subprocess.run(['git', 'clone', '-q', '--depth', '1', '--recurse-submodules', '--shallow-submodules', REPO, src],
                           capture_output=True, text=True, timeout=3600)
        if r.returncode:
            raise RuntimeError('could not fetch DWSIM: ' + r.stderr[-500:])
    r = subprocess.run(['dotnet', 'publish', os.path.join(src, 'tools', 'DWSIM.MCPServer', 'DWSIM.MCPServer.csproj'), '-c', 'Release',
                        '-o', os.path.join(CACHE, 'mcp')], capture_output=True, text=True, timeout=7200)
    if r.returncode or not exe():
        raise RuntimeError('DWSIM build failed: ' + (r.stdout + r.stderr)[-1500:])
    log and log('DWSIM MCP server built: ' + exe())
    return exe()


def client():
    from .mcp_client import MCPClient
    if _CLIENT and _CLIENT[0].p.poll() is None:
        return _CLIENT[0]
    e = exe()
    if not e:
        raise RuntimeError('DWSIM is not built yet: the .NET 10 SDK is needed to build the DWSIM MCP server, then '
                           'python -c "from shipbrain import dwsim; dwsim.build()"')
    _CLIENT[:] = [MCPClient([e, '--stdio'], timeout=1800)]
    return _CLIENT[0]


def _call(name, args):
    r = client().call(name, args)
    if r.get('is_error'):
        raise RuntimeError(f'DWSIM {name}: {str(r["result"])[:500]}')
    return r['result']


def _num(x):
    try:
        x = float(x)
        return None if x != x else x
    except (TypeError, ValueError):
        return None


def stream_summary(s):
    """DWSIM stream result -> compact dict in engineering units (degC, bar, kg/h)"""
    T, P = _num(s.get('temperature_K')), _num(s.get('pressure_Pa'))
    out = {'name': s.get('name'), 'T_C': round(T - 273.15, 2) if T else None, 'P_bar': round(P / 1e5, 4) if P else None,
           'mass_flow_kg_h': round(_num(s.get('mass_flow_kg_s')) * 3600, 2) if _num(s.get('mass_flow_kg_s')) is not None else None,
           'phases': []}
    for ph in s.get('phases', []):
        f = _num(ph.get('fraction'))
        nm = str(ph.get('name', '')).lower().replace('líquido', 'liquid').replace('sólido', 'solid')
        if not f or any(w in nm for w in ('mixture', 'mistura', 'overall', 'misturа')):
            continue                                         # the mixture / "overall liquid" are sums, not phases
        ph = dict(ph, name=nm.replace('liquid1', 'liquid 1').replace('liquid2', 'liquid 2'))
        comp = {k: round(_num(v.get('mole_fraction')), 4) for k, v in (ph.get('compounds') or {}).items() if _num(v.get('mole_fraction'))}
        out['phases'].append({'phase': ph['name'], 'mole_fraction_of_stream': round(f, 4), 'density_kg_m3': round(_num(ph.get('density_kg_m3')) or 0, 3),
                              'composition_mol': comp})
    mix = next((ph for ph in s.get('phases', []) if ph.get('name') == 'Mixture'), {})
    out['enthalpy_kJ_kg'] = round(_num(mix.get('enthalpy_kJ_kg')) or 0, 3)
    out['composition_mol'] = {k: round(_num(v.get('mole_fraction')), 4) for k, v in (mix.get('compounds') or {}).items() if _num(v.get('mole_fraction'))}
    return out


def _say_stream(s):
    ph = ', '.join(f"{p['phase'].lower()} {p['mole_fraction_of_stream'] * 100:.1f} %" for p in s['phases']) or 'no phase data'
    main = ', '.join(f'{k} {v * 100:.1f} %' for k, v in sorted(s['composition_mol'].items(), key=lambda x: -x[1])[:4])
    return (f"stream {s['name']}: {s['T_C']:g} C, {s['P_bar']:g} bar, {s['mass_flow_kg_h']:g} kg/h ({ph})"
            + (f"; composition (mol) {main}" if main else '; composition not reported (pseudo-components)'))


def run(path, timeout_s=600):
    """load + solve a DWSIM flowsheet -> streams, unit operations, errors"""
    fl = _call('dwsim_flowsheet_load', {'filepath': os.path.abspath(path)})
    fid = fl['flowsheet_id']
    sol = _call('dwsim_solve_run', {'flowsheet_id': fid, 'timeout_s': timeout_s})
    objs = _call('dwsim_flowsheet_list_objects', {'flowsheet_id': fid})['objects']
    streams, units = [], []
    for o in objs:
        if o['type'] == 'MaterialStream':
            try:
                streams.append(stream_summary(_call('dwsim_stream_get_results', {'flowsheet_id': fid, 'name': o['name']})))
            except RuntimeError:
                pass
        elif o['type'] != 'EnergyStream':
            units.append({'name': o['name'], 'type': o['type'], 'calculated': o.get('calculated'), 'error': o.get('error')})
    errs = sol.get('errors') or []
    pe = (f"DWSIM solved {os.path.basename(path)} ({', '.join(fl.get('compounds', [])[:8])}): {len(streams)} material stream(s), "
          f"{len(units)} unit operation(s)" + (f", {len(errs)} error(s): {errs[0]}" if errs else ', no errors') + '. '
          + '; '.join(_say_stream(s) for s in streams[:8]) + '.')
    try:
        _call('dwsim_flowsheet_close', {'flowsheet_id': fid})
    except Exception:
        pass
    return {'flowsheet': os.path.basename(path), 'compounds': fl.get('compounds'), 'ok': sol.get('ok'), 'errors': errs,
            'streams': streams, 'unit_operations': units, 'plain_english': pe}


def flash(compounds, mass_fractions, T_C, P_bar, flow_kg_h=1000.0, package='Peng-Robinson (PR)'):
    """one material stream at T, P: DWSIM's flash -> phases, densities, compositions (mol), enthalpy.
    The feed composition is given in MASS fractions (DWSIM's convention for a new stream)."""
    composition = mass_fractions
    fid = _call('dwsim_flowsheet_create', {'name': 'shipbrain_flash'})['flowsheet_id']
    try:
        _call('dwsim_thermo_add_compounds', {'flowsheet_id': fid, 'names': list(compounds)})
        _call('dwsim_thermo_set_property_package', {'flowsheet_id': fid, 'name': package})
        comp = dict(zip(compounds, composition)) if not isinstance(composition, dict) else composition
        tot = sum(comp.values())
        _call('dwsim_stream_add_material', {'flowsheet_id': fid, 'name': 'S1', 'temperature_K': T_C + 273.15, 'pressure_Pa': P_bar * 1e5,
                                            'mass_flow_kg_s': flow_kg_h / 3600, 'composition': {k: v / tot for k, v in comp.items()}})
        _call('dwsim_solve_run', {'flowsheet_id': fid})
        s = stream_summary(_call('dwsim_stream_get_results', {'flowsheet_id': fid, 'name': 'S1'}))
    finally:
        try:
            _call('dwsim_flowsheet_close', {'flowsheet_id': fid})
        except Exception:
            pass
    s['package'] = package
    feed = ', '.join(f'{k} {v / tot * 100:.1f} %' for k, v in comp.items())
    s['feed_mass_fractions'] = {k: round(v / tot, 4) for k, v in comp.items()}
    s['plain_english'] = (f"For a feed of {feed} by mass at {T_C:g} C and {P_bar:g} bar, DWSIM ({package}) gives: " + _say_stream(s)
                          + ". The composition after the flash is in mole fractions.")
    return s


def samples():
    """DWSIM's own sample flowsheets (in the built source, tests/flowsheets)"""
    return sorted(glob.glob(os.path.join(CACHE, 'src', 'tests', 'flowsheets', '*.dwxm*')))
