"""
DWSIM process simulations -> training samples (every number is DWSIM's own result).

  plants    DWSIM's 22 sample flowsheets (gas processing, columns, reactors, separators, LNG, biodiesel ...):
            "simulate / what comes out of / what is the temperature of stream X in <plant>" -> process_sim run
  flashes   many mixtures (natural gas, water-alcohol, aromatics, refrigerants, CO2, air, ammonia ...) at many T / P
            with a fitting property package -> process_sim flash -> phases, composition, density
Needs the built DWSIM server (shipbrain.dwsim.build()). The result is small and is kept in the repo
(training/data/dwsim_train.jsonl.gz), so the Kaggle run does not have to build DWSIM.

    python training/dwsim_tasks.py --out training/data/dwsim_train.jsonl.gz --n-flash 260
"""
import argparse, gzip, json, os, random, re, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, dwsim   # noqa: E402

MIXES = [   # compounds, typical mass fractions, T range C, P range bar, packages
    (['Methane', 'Ethane', 'Propane', 'N-butane'], [0.80, 0.10, 0.07, 0.03], (-60, 60), (5, 90), ['Peng-Robinson (PR)', 'Soave-Redlich-Kwong (SRK)']),
    (['Methane', 'Carbon dioxide'], [0.85, 0.15], (-40, 50), (10, 80), ['Peng-Robinson (PR)', 'Soave-Redlich-Kwong (SRK)']),
    (['Water', 'Methanol'], [0.6, 0.4], (20, 110), (0.5, 3), ['NRTL', 'UNIFAC', 'Wilson']),
    (['Water', 'Ethanol'], [0.7, 0.3], (20, 105), (0.5, 3), ['NRTL', 'UNIFAC']),
    (['Benzene', 'Toluene'], [0.5, 0.5], (60, 130), (0.5, 2), ['Peng-Robinson (PR)', 'NRTL']),
    (['Propane', 'N-butane'], [0.6, 0.4], (-30, 70), (1, 20), ['Peng-Robinson (PR)', 'Soave-Redlich-Kwong (SRK)']),
    (['Nitrogen', 'Oxygen', 'Argon'], [0.755, 0.232, 0.013], (-195, 30), (1, 10), ['Peng-Robinson (PR)']),
    (['Water'], [1.0], (20, 250), (0.5, 40), ['Steam Tables (IAPWS-IF97)']),
    (['Ammonia', 'Water'], [0.3, 0.7], (20, 120), (1, 15), ['Peng-Robinson (PR)', 'NRTL']),
    (['N-hexane', 'N-heptane', 'N-octane'], [0.3, 0.4, 0.3], (50, 160), (0.5, 3), ['Peng-Robinson (PR)']),
    (['Hydrogen', 'Methane'], [0.3, 0.7], (-150, 50), (10, 60), ['Peng-Robinson (PR)']),
    (['Carbon dioxide', 'Water'], [0.1, 0.9], (10, 90), (1, 50), ['Peng-Robinson (PR)', 'Soave-Redlich-Kwong (SRK)']),
]
ASK_FLASH = ['Flash {f} by mass at {T} C and {P} bar - what phases do I get?', 'What is the state of a {f} (mass) mixture at {T} C, {P} bar?',
             'DWSIM flash: {f} by mass, {T} C, {P} bar, {pk}', 'Is {f} (by mass) liquid or vapour at {T} C and {P} bar? Use {pk}.',
             'Phase split and composition of {f} (mass %) at {T} degC and {P} bar?']
ASK_RUN = ['Simulate {n}', 'Run the DWSIM flowsheet {n} and tell me what comes out', 'Solve {n}: products, temperatures and flows?',
           'What are the product streams of {n}?']


def tb(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}) + '\n```'


def res(name, out):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + agent.compact_result(out)}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='training/data/dwsim_train.jsonl.gz')
    ap.add_argument('--n-flash', type=int, default=260)
    ap.add_argument('--per-plant', type=int, default=4)
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_dwsim_')
    T = agent.Tools(work)
    sysmsg = {'role': 'system', 'content': agent.system_prompt(T)}
    rows = []
    for f in dwsim.samples():                                     # the sample plants
        fname = os.path.basename(f)
        shutil.copy(f, os.path.join(work, fname))
        args = {'action': 'run', 'file': fname}
        out = T.call('process_sim', args)
        if 'error' in out or not out.get('streams'):
            print('skip', fname, str(out.get('error'))[:200])
            continue
        rows.append({'task': 'dwsim_run', 'messages': [sysmsg, {'role': 'user', 'content': r.choice(ASK_RUN).format(n=fname)},
                                                       {'role': 'assistant', 'content': tb('process_sim', args)}, res('process_sim', out),
                                                       {'role': 'assistant', 'content': out['plain_english']}]})
        for s in r.sample(out['streams'], min(a.per_plant - 1, len(out['streams']))):
            if s.get('T_C') is None:
                continue
            q = r.choice([f"In {fname}, what is the temperature and pressure of stream {s['name']}?",
                          f"What is the composition of stream {s['name']} in {fname}?", f"How much flows in stream {s['name']} of {fname}?"])
            main_c = ', '.join(f'{k} {v * 100:.1f} %' for k, v in sorted(s['composition_mol'].items(), key=lambda x: -x[1])[:4])
            phases = ', '.join(f"{p['phase']} {p['mole_fraction_of_stream'] * 100:.1f} %" for p in s['phases']) or 'single phase'
            ans = (f"DWSIM solved {fname}; stream {s['name']} is at {s['T_C']:g} C and {s['P_bar']:g} bar with {s['mass_flow_kg_h']:g} kg/h "
                   f"({phases})." + (f" Its composition (mole fractions) is {main_c}." if main_c else
                                    ' DWSIM does not report a composition for it (petroleum pseudo-components).'))
            rows.append({'task': 'dwsim_stream', 'messages': [sysmsg, {'role': 'user', 'content': q}, {'role': 'assistant', 'content': tb('process_sim', args)},
                                                              res('process_sim', out), {'role': 'assistant', 'content': ans}]})
        print(fname, 'ok', flush=True)
    for i in range(a.n_flash):                                      # flashes
        comps, base, (t0, t1), (p0, p1), pks = r.choice(MIXES)
        fr = [max(0.01, b * r.uniform(0.6, 1.4)) for b in base]
        tot = sum(fr)
        fr = [round(x / tot, 3) for x in fr]
        Tc, Pb = round(r.uniform(t0, t1), 1), round(r.uniform(p0, p1), 2)
        pk = r.choice(pks)
        args = {'action': 'flash', 'compounds': comps, 'mass_fractions': fr, 'T_C': Tc, 'P_bar': Pb, 'package': pk}
        try:
            out = T.call('process_sim', args)
        except Exception as e:
            out = {'error': str(e)}
        if 'error' in out:
            continue
        feed = ', '.join(f'{c} {x * 100:.0f} %' for c, x in zip(comps, fr))
        rows.append({'task': 'dwsim_flash', 'messages': [sysmsg, {'role': 'user', 'content': r.choice(ASK_FLASH).format(f=feed, T=Tc, P=Pb, pk=pk)},
                                                         {'role': 'assistant', 'content': tb('process_sim', args)}, res('process_sim', out),
                                                         {'role': 'assistant', 'content': out['plain_english']}]})
    r.shuffle(rows)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    op = gzip.open if a.out.endswith('.gz') else open
    with op(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    shutil.rmtree(work, ignore_errors=True)
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
