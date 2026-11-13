"""
Training samples for python_run (real runs): a calculation with a loop, a table from a loop, a plot, reading a CSV, a script that fails and is fixed, and when NOT to use it (a single formula -> calc, a CAD part ->
cadquery_build). Plus a few cadquery_build requests in plain words so the model learns to offer both code tools.

    python training/python_tools_tasks.py --n 80 --out training/data/python_tools_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=80)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'python_tools_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_py_')
    T = agent.Tools(work, knowledge.load(None), allow_code=True)
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def run(code, **kw):
        args = {'code': code, **kw}
        res = T.call('python_run', args)
        if 'error' in res:
            raise ValueError(res['error'])
        return res, [A(tool_block('python_run', args)), result_msg('python_run', res)]

    def weights():
        L, B = r.choice([1.0, 1.5, 2.0]), r.choice([0.5, 1.0])
        ts = sorted(r.sample([6, 8, 10, 12, 14, 16, 20], 4))
        code = f"rho = 7850  # kg/m3\nL, B = {L}, {B}  # m\nfor t in {ts}:\n    m = rho * L * B * t / 1000\n    print(f't = {{t}} mm: {{m:.1f}} kg')\n"
        res, c = run(code)
        lines = res['output'].strip().splitlines()
        return [U(f'Weight of a steel plate {L} x {B} m for thicknesses {", ".join(map(str, ts))} mm, as a table.')] + c + [A('Steel plate ' + f'{L} x {B} m (7850 kg/m3):\n' + '\n'.join('- ' + x for x in lines))]

    def table_stress():
        P = r.choice([5000, 10000, 20000])
        ds = sorted(r.sample([10, 12, 16, 20, 24], 3))
        code = f"import math\nP = {P}  # N\nfor d in {ds}:\n    A = math.pi * d**2 / 4\n    print(f'd = {{d}} mm: stress {{P / A:.1f}} MPa')\n"
        res, c = run(code)
        lines = res['output'].strip().splitlines()
        return [U(f'Tensile stress in a round bar under {P} N for diameters {", ".join(map(str, ds))} mm.')] + c + [A('Stress = load / area:\n' + '\n'.join('- ' + x for x in lines))]

    def plot():
        k = r.choice([2, 5, 10])
        code = (f"import numpy as np\nimport matplotlib.pyplot as plt\nx = np.linspace(0, 10, 50)\ny = {k} * x\nplt.plot(x, y)\nplt.xlabel('load (kN)')\nplt.ylabel('deflection (mm)')\n"
                f"plt.title('Deflection against load')\nplt.grid(True)\nplt.savefig('deflection.png', dpi=100)\nprint('max', y.max())\n")
        res, c = run(code, name='plot')
        return [U(f'Plot a straight-line deflection against load, {k} mm per kN, load 0 to 10 kN.')] + c + [A(f"Plotted: the picture {res['files'][0] if res['files'] else 'deflection.png'} shows deflection from 0 to {res['output'].split()[-1]} mm for 0 to 10 kN.")]

    def csv_stats():
        rows = [(i, round(r.uniform(100, 400), 1)) for i in range(1, r.choice([6, 8, 10]) + 1)]
        csv = 'point,stress_MPa\n' + '\n'.join(f'{i},{v}' for i, v in rows)
        fn = r.choice(['stress.csv', 'readings.csv'])
        open(os.path.join(work, fn), 'w').write(csv)
        code = f"import pandas as pd\ndf = pd.read_csv('{fn}')\nprint(len(df), 'points')\nprint('max', df.stress_MPa.max(), 'at point', int(df.loc[df.stress_MPa.idxmax(), 'point']))\nprint('mean', round(df.stress_MPa.mean(), 1))\n"
        res, c = run(code)
        o = res['output'].strip().splitlines()
        return [U(f'In {fn}: how many points, the largest stress and where, and the mean?')] + c + [A(f"{o[0]}; largest {o[1].replace('max ', '')}; mean {o[2].replace('mean ', '')} MPa.")]

    def fix_error():
        code1 = "weights = [10, 12, 14]\nprint(sum(weigths))\n"
        try:
            res1, c1 = run(code1)
        except ValueError:
            return None
        code2 = "weights = [10, 12, 14]\nprint(sum(weights))\n"
        res2, c2 = run(code2)
        c1[0]['content'] = c1[0]['content']
        return ([U('Add up the plate thicknesses 10, 12 and 14 mm with a script.')] + c1 + [A('A typo in my variable name (weigths): fixing it and running again.\n' + tool_block('python_run', {'code': code2}))]
                + [c2[1], A(f"Sum of thicknesses: {res2['output'].strip()} mm.")])

    def use_calc():
        return [U(r.choice(['What is 1250 * 8 / 1000?', 'convert 12 mm to inches in one number'])), A('That is a single formula, so I use the calculator, not a script.\n' + tool_block('calc', {'expression': '1250 * 8 / 1000'}))] if False else None

    def cad_plain():
        L, B, t = r.choice([200, 300, 400]), r.choice([100, 150]), r.choice([10, 20, 30])
        code = f"import cadquery as cq\nresult = cq.Workplane('XY').box({L}, {B}, {t})\n"
        args = {'code': code, 'name': 'plate', 'expect': {'bbox': [L, B, t], 'tol': 0.01}}
        res = T.call('cadquery_build', args)
        if 'error' in res:
            return None
        return [U(f'Make a 3D STEP plate {L} x {B} x {t} mm.'), A(tool_block('cadquery_build', args)), result_msg('cadquery_build', res),
                A(f"Built plate.step ({L} x {B} x {t} mm), {res.get('n_solids', 1)} solid, valid: {res.get('valid')}. It matches your sizes.")]

    def which_tool():
        q, a_ = r.choice([
            ('Do I need Python to add two numbers?', 'No: for a single formula I use the calculator (calc). I use Python (python_run) when you need a loop over many values, a table, a plot, or to read and convert a data file.'),
            ('Can you run my own script?', 'Yes: give me the script (or tell me what it should do) and I run it in the workspace folder with python_run: numpy, scipy, matplotlib and pandas are available. I show the printed output and the files it wrote. For a 3D part I use CadQuery (cadquery_build) instead.'),
            ('Is it safe to run code from the chat?', 'The scripts run on this PC in the workspace folder, with a time limit, and I show the code I run. They are not sandboxed from your computer, so only ask for code you are comfortable with; you can switch the code tools off with --no-code when you start ShipBrain.')])
        return [U(q), A(a_)]

    gens = [(weights, 4), (table_stress, 3), (plot, 3), (csv_stats, 3), (fix_error, 2), (cad_plain, 3), (which_tool, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 5:
        tries += 1
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:120])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'python_' + g.__name__, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), (x['task'], roles)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s and 'sb_py_' not in s
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
