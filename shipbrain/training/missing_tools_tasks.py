"""
Training samples from real runs of the tools that had no training examples: mesh chain (plates_mesh -> mesh_check -> solve_calculix -> show_result / probe_result), cad_mesh on a STEP plate,
fatigue_mesh, cfd_export (Fluent / STAR-CCM+), list_files, choose_engine, find_solvers, serving_sim, and the memory tools (remember, recall, list_skills, memory_feedback).
Every result is produced by really calling the tool. Tools that need a vision model, a commercial program, a large external build or a user-supplied file (look, drawing_*, moose_run, hex_mesh_algohex,
mcp_call, code_folder, parse_document ...) are NOT here: inventing their results would teach wrong numbers.

    python training/missing_tools_tasks.py --n 240 --out training/data/missing_tools_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=240)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'missing_tools_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_mt_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def step(tool, args):
        res = T.call(tool, json.loads(json.dumps(args)))
        if 'error' in res:
            raise ValueError(res['error'])
        return res, [A(tool_block(tool, args)), result_msg(tool, res)]

    def grillage():
        L, B = r.choice([3000, 4000, 5000, 6000]), r.choice([2000, 2400, 3000])
        t, tg = r.choice([8, 10, 12]), r.choice([8, 10, 12])
        hg = r.choice([300, 400, 500])
        y = round(B / 2)
        name = r.choice(['deck_panel', 'gr', 'panel_a', 'test_grillage'])
        plates = [{'id': 'DECK', 't': t, 'outline': [[0, 0, 0], [L, 0, 0], [L, B, 0], [0, B, 0]]},
                  {'id': 'G1', 't': tg, 'outline': [[0, y, 0], [L, y, 0], [L, y, -hg], [0, y, -hg]]}]
        head = r.choice([2, 3, 5])
        args = {'name': name, 'element_size': r.choice([150, 200, 250]), 'plates': plates, 'loads': [{'plates': ['DECK'], 'pressure': round(head * 0.01005, 5)}], 'fix': [{'x': 0}, {'x': L}]}
        return name, L, B, t, tg, hg, head, args

    def make_mesh():
        name, L, B, t, tg, hg, head, args = grillage()
        res, _ = step('plates_mesh', args)
        return name, res, (L, B, t, tg, hg, head)

    def answer_solve(res, name, t=None):
        a_ = (f"CalculiX linear static on {name}.inp: largest displacement {res['max_displacement_mm']:.2f} (model units, mm) at node {res['max_displacement_node']}, "
              f"largest von Mises stress {res['max_von_mises_MPa']:.0f} MPa at node {res['max_von_mises_node']}. Results are in {res['frd']}. "
              "Nodal values are extrapolated by CalculiX, and for shells the stress is the largest of the top, bottom and middle fibre. ")
        big_w = res['max_displacement_mm'] > 50 or (t and res['max_displacement_mm'] > 2 * t)
        if res['max_von_mises_MPa'] > 355 or big_w:
            a_ += (f"Warning: {res['max_von_mises_MPa']:.0f} MPa is above the yield of ordinary hull steel (235 to 355 MPa)" + (' and the displacement is very large for this plate' if big_w else '')
                   + ". The model is linear (small deflection, no yielding), so these numbers are not reliable at this size: the panel is too thin or too lightly supported. Add stiffeners or thickness, "
                   "or reduce the load, and run it again; for a real check of the collapse use a nonlinear analysis.")
        else:
            a_ += 'Compare the stress with the allowable of your material and the class rules.'
        return a_

    # ------------------------------------------------------------ chains
    def mesh_solve_show():
        name, L, B, t, tg, hg, head, args = grillage()
        q = f'Mesh a deck panel {L} x {B} mm, t {t}, with one girder {hg} x {tg} at mid-width, {head} m head on the deck, ends x=0 and x={L} fixed. Solve it and show me the stress.'
        m1, c1 = step('plates_mesh', args)
        inp = m1['files']['inp']
        m2, c2 = step('solve_calculix', {'inp': inp})
        m3, c3 = step('show_result', {'file': inp, 'frd': m2['frd'], 'field': 'von_mises'})
        ans = answer_solve(m2, name, t) + f" The picture {m3['png']} shows von Mises from {m3['min']:.0f} to {m3['max']:.0f} MPa."
        c2[0]['content'] = f"Meshed: {m1['nodes']} nodes, {m1['elements']} elements. Now the solver.\n" + c2[0]['content']
        return [U(q)] + c1 + c2 + c3 + [A(ans)]

    def check_file():
        name, res, _ = make_mesh()
        inp = res['files']['inp']
        m, c = step('mesh_check', {'file': inp})
        q = r.choice([f'Check the mesh {inp}.', f'Is {inp} a clean mesh?', f'{inp} ka mesh check karo'])
        q_ = m['quality']
        ans = (f"{inp}: {m['nodes']} nodes, {m['elements']} elements. Connectivity: {m['parts']} part, {m['free_nodes']} free nodes, {m['duplicate_nodes']} duplicate nodes, {m['free_edges']} free edges "
               f"({m['t_joint_edges']} of them at T-joints, which is normal). Quality: largest aspect ratio {q_['max_aspect']}, corner angles {q_['min_angle']} to {q_['max_angle']} degrees, "
               f"{q_['inverted_or_degenerate']} inverted elements. Verdict: {m['verdict']}.")
        return [U(q)] + c + [A(ans)]

    def solve_file():
        name, res, _ = make_mesh()
        inp = res['files']['inp']
        m, c = step('solve_calculix', {'inp': inp})
        return [U(r.choice([f'Run CalculiX on {inp}.', f'Solve {inp} (linear static).']))] + c + [A(answer_solve(m, name))]

    def show_geometry():
        name, res, _ = make_mesh()
        inp = res['files']['inp']
        view = r.choice(['iso', 'top', 'front'])
        m, c = step('show_result', {'file': inp, 'view': view})
        return [U(f'Show me the model {inp} in the {view} view.')] + c + [A(m['plain_english'])]

    def probe_place():
        name, res, dims = make_mesh()
        inp = res['files']['inp']
        step('solve_calculix', {'inp': inp})
        L, B = dims[0], dims[1]
        x, y = round(L * r.choice([0.25, 0.5, 0.75])), round(B * r.choice([0.25, 0.5]))
        m, c = step('probe_result', {'file': inp, 'x': x, 'y': y, 'z': 0})
        q = f'What is the stress and displacement of {inp} at x = {x}, y = {y} mm on the deck? (it is already solved)'
        return [U(q)] + c + [A(m['plain_english'])]

    def from_step():
        import cadquery as cq
        L, B, t = r.choice([800, 1000, 1500]), r.choice([400, 500, 800]), r.choice([8, 10, 12])
        fn = f'plate_{L}x{B}.step'
        cq.exporters.export(cq.Workplane('XY').box(L, B, t), os.path.join(work, fn))
        size = r.choice([50, 100])
        m, c = step('cad_mesh', {'file': fn, 'element_size': size, 'default_t': t})
        ck = m['check']
        ans = (f"Meshed {fn} with the own mesher: the thin solid became a mid-surface plate ({m['plates']} plate, thickness {t} mm): {m['nodes']} nodes, {m['elements']} quad elements, "
               f"{ck['free_nodes']} free nodes, {ck['duplicate_nodes']} duplicate nodes, check verdict: {ck['verdict']}. Files: {', '.join(m['files'].values())}.")
        return [U(f'Mesh the STEP file {fn} ({L} x {B} x {t} mm plate), element size {size} mm.')] + c + [A(ans)]

    def fatigue():
        L, B, t = 4000, 2400, r.choice([10, 12, 15])
        plates = [{'id': 'DECK', 't': t, 'outline': [[0, 0, 0], [L, 0, 0], [L, B, 0], [0, B, 0]]},
                  {'id': 'G1', 't': t, 'outline': [[0, 1200, 0], [L, 1200, 0], [L, 1200, -500], [0, 1200, -500]]}]
        box = r.choice([50, 80])
        args = {'plates': plates, 'hotspot': [2000, 1200, 0], 'size': box, 't': t}
        m, c = step('fatigue_mesh', args)
        ans = (f"Hot-spot model: a {m['box_mm']:.0f} mm box around the weld cut from the assembly ({', '.join(m['plates_in_box'])}), meshed t x t = {m['t_ref']:g} mm: {m['nodes']} nodes, {m['elements']} elements. "
               f"{len(m['readout_points'])} read-out lines are given at 0.5t and 1.5t from the weld toe: the hot-spot stress is 1.5 x s(0.5t) - 0.5 x s(1.5t). {m['note'].capitalize()}. "
               "Apply the loads from the global model to the cut faces (or use solve = true with loads) to get the stresses.")
        return [U(f'Make a fatigue hot-spot local model at the deck-girder weld at (2000, 1200, 0), plate thickness {t} mm.')] + c + [A(ans)]

    def cfd():
        target = r.choice(['fluent', 'starccm'])
        U_ = r.choice([0.5, 1.0, 2.0, 3.0])
        fluid = r.choice(['water', 'seawater', 'air'])
        m, c = step('cfd_export', {'target': target, 'velocity': U_, 'fluid': fluid})
        nm = 'ANSYS Fluent' if target == 'fluent' else 'STAR-CCM+'
        return [U(f'Set up the plate-in-flow case for {nm}: {fluid} at {U_:g} m/s.')] + c + [A(m['plain_english'])]

    def memory():
        facts = [('Our yard uses 250 mm frame spacing in the engine room', 'frame spacing'), ('Default plate steel is AH36 with 355 MPa yield', 'plate steel yield'),
                 ('Welding inspection class at this yard is B for all hull structure', 'welding inspection'), ('Standard bolt for the pump base is M20 grade 8.8', 'pump base bolt')]
        text, qry = r.choice(facts)
        m1, c1 = step('remember', {'text': text, 'tags': ['yard']})
        m2, c2 = step('recall', {'query': qry})
        return [U(f'Remember this: {text}.')] + c1 + [A(f"Saved as memory {m1['id']}: {text}. I will use it in later answers.")] + [U(f'What did I tell you about {qry}?')] + c2 + [A(f"You told me: {m2['memories'][0]['text']} (memory {m2['memories'][0]['id']}).")]

    def memory_like():
        text = r.choice(['Cargo tank coating is epoxy, 320 micron', 'Deck plating minimum thickness at this yard is 8 mm'])
        m1, c1 = step('remember', {'text': text})
        good = r.random() < 0.7
        m2, c2 = step('memory_feedback', {'id': m1['id'], 'good': good})
        return [U(f'Remember: {text}.')] + c1 + [A(f'Saved as {m1["id"]}.')] + [U('That is correct, keep it.' if good else 'That one is wrong, mark it bad.')] + c2 + [A('Marked as good: I will trust it more.' if good else 'Marked as bad: I will use it less.')]

    def skills():
        m, c = step('list_skills', {})
        return [U(r.choice(['What skills do you have?', 'List your saved workflows.']))] + c + [A(m['plain_english'])]

    def files():
        name, res, _ = make_mesh()
        m, c = step('list_files', {})
        return [U(r.choice(['What files do we have?', 'List the workspace files.']))] + c + [A('Files in the workspace: ' + ', '.join(m['files']) + '.')]

    def engine():
        q = r.choice(['natural frequencies of a deck panel', 'static stress in a bracket under load', 'flow past a plate at 1 m/s', 'buckling load of a stiffened panel', 'heat conduction in a plate',
                      'impact of a dropped object on a deck', 'fatigue life of a weld', 'plastic collapse load of a plate'])
        m, c = step('choose_engine', {'question': q})
        return [U(f'Which solver do you use for: {q}?')] + c + [A(m['plain_english'])]

    def solvers():
        m, c = step('find_solvers', {})
        return [U(r.choice(['Which solvers are installed on this PC?', 'find solvers']))] + c + [A(m['plain_english'])]

    def serving():
        users, rate = r.choice([4, 8, 16, 32]), r.choice([1, 2, 4])
        m, c = step('serving_sim', {'action': 'simulate', 'users': users, 'rate_per_s': rate})
        return [U(f'How fast would the model answer {users} users at once, {rate} requests per second?')] + c + [A(m['plain_english'])]

    def limits():
        q, ans = r.choice([
            ('Show me the von Mises stress picture of my model.', 'I need a solved model first: the stress picture is drawn from the CalculiX results file (.frd) next to the mesh. Give me the mesh and its loads and supports, or the finished .frd, and I will solve it (solve_calculix) and draw it (show_result).'),
            ('Can you run Fluent for me?', 'No. ANSYS Fluent and STAR-CCM+ are commercial and cannot run here. I can write the mesh, the setup sheet and the PyFluent script or STAR-CCM+ macro (cfd_export); you run them with your licence and upload the exported CSV, and I read the value at any place. The same case also runs in OpenFOAM here for a cross-check.'),
            ('Is a mesh with free edges wrong?', 'Not always. Free edges along the outer boundary of a shell are normal, and so are free edges at T-joints where plates meet. What matters are free nodes (nodes in no element), duplicate nodes (two nodes at one place) and unconnected parts: mesh_check reports all of these.')])
        return [U(q), A(ans)]

    gens = [(mesh_solve_show, 4), (check_file, 3), (solve_file, 3), (show_geometry, 2), (probe_place, 3), (from_step, 3), (fatigue, 2), (cfd, 3), (memory, 3), (memory_like, 2), (skills, 1),
            (files, 1), (engine, 3), (solvers, 1), (serving, 2), (limits, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 4:
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
        rows.append({'task': 'missing_' + g.__name__, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), (x['task'], roles)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s and 'sb_mt_' not in s, [t for t in ('/tmp/', '/home/', 'sb_mt_') if t in s]
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
