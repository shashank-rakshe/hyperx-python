"""
NX Open training samples: questions about automating Siemens NX / Simcenter 3D -> nx_open(find) -> nx_open(syntax) ->
nx_open(journal) with nxopentse's real functions (checked against its code) -> plain answer. NX itself is not needed:
the journal is written and the answer says how to run it. Also renaming with links (nx_rename) and function questions.

    python training/nx_tasks.py --n 120 --out training/data/nx_train.jsonl.gz
"""
import argparse, gzip, json, os, random, re, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

GF = {'nx': 'NXOpen.CAE.CaeSetGroupFilterType.GeomFace'}


def scenarios(r):
    part = r.choice(['hull_block', 'deck_grillage', 'engine_foundation', 'hatch_cover', 'rudder_stock', 'bracket']) + \
        f'_{r.randint(1, 99):02d}'
    sim = part + '_sim1.sim'
    prt = part + '.prt'
    sol = r.choice(['SOL101_static', 'Static_Load', 'Sea_Pressure', 'Lifting'])
    grp = r.choice(['DECK', 'BOTTOM', 'SIDE_SHELL', 'BULKHEAD_FR40', 'TANK_TOP'])
    p = r.choice([0.01, 0.02, 0.05, 0.1, 0.15])
    t = r.choice([8, 10, 12, 15, 20])
    return r.choice([
        ('Solve all solutions in {sim} with NX', 'solve all solutions', sim, [{'fn': 'solve_all_solutions'}],
         'It opens {sim} and solves every solution in it (Simcenter Nastran, in the foreground).'),
        ('Write an NX journal that solves only {sol} in {sim}', 'solve solution name', sim,
         [{'fn': 'solve_solution', 'args': {'solution_name': sol}}], 'It opens {sim} and solves the solution {sol}.'),
        ('List all bodies in {prt} with their volume and mass (NX)', 'bodies part mass properties', prt,
         [{'fn': 'get_all_bodies_in_part', 'as': 'bodies'}, {'fn': 'get_body_properties', 'for_each': '$bodies', 'as': 'props'}],
         'It opens {prt}, collects every body and reads each one\'s mass properties (area, volume, mass, centre of gravity) - '
         'note nxopentse gives them in metres and kilograms.'),
        ('In {sim}, create a solution {sol} with a subcase "Load1" and a pressure of {p} MPa on the group {grp}',
         'create solution subcase pressure group', sim,
         [{'fn': 'create_solution', 'args': {'solution_name': sol}}, {'fn': 'create_subcase', 'args': {'solution_name': sol, 'subcase_name': 'Load1'}},
          {'fn': 'create_pressure_on_group', 'args': {'group_name': grp, 'pressure': p, 'force_name': f'P_{grp}', 'group_filter_type': GF}},
          {'fn': 'add_load_to_subcase', 'args': {'load_name': f'P_{grp}', 'solution_name': sol, 'subcase_name': 'Load1'}}],
         'It opens {sim}, creates the solution {sol} with the subcase Load1, puts {p} MPa on the faces of group {grp} '
         '(load P_{grp}) and adds that load to Load1. Check the pressure unit of your sim (MPa = N/mm2).'),
        ('Make a 2D mesh collector of {t} mm thickness in the FEM (NX journal)', '2d mesh collector thickness', None,
         [{'fn': 'create_2dmesh_collector', 'args': {'thickness': t}}],
         'It creates a 2D mesh collector with a shell thickness of {t} in the open FEM part (thickness in the part units).'),
        ('Print the assembly / part tree of {prt}', 'print part tree', prt,
         [{'fn': 'get_all_features', 'as': 'features'}],
         None),
        ('Fix node 1 in all directions and put 1000 N in z on node 25 in the open sim', 'nodal constraint nodal force', None,
         [{'fn': 'create_nodal_constraint', 'args': {'node_label': 1, 'dx': 0.0, 'dy': 0.0, 'dz': 0.0, 'rx': 0.0, 'ry': 0.0, 'rz': 0.0,
                                                     'constraint_name': 'Fix_N1'}},
          {'fn': 'create_nodal_force', 'args': {'node_label': 25, 'fx': 0.0, 'fy': 0.0, 'fz': 1000.0, 'force_name': 'F_N25'}}],
         'It creates the constraint Fix_N1 (node 1, all six directions fixed; nxopentse uses -777777 for a free direction) '
         'and the force F_N25 of 1000 N in z on node 25 in the open sim. Add them to a subcase before solving.'),
    ]), dict(sim=sim, prt=prt, sol=sol, grp=grp, p=p, t=t)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=120)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'nx_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge, nxopen
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_nx_')
    T = agent.Tools(work, knowledge.load(None))
    clean = lambda o: json.loads(json.dumps(o).replace(work + os.sep, '').replace(work, '.').replace(nxopen.TSE, '<shipbrain>/vendor/nxopentse/repo/src'))
    rows = []
    try:
        for i in range(a.n):
            kind = r.random()
            if kind < 0.15:                                      # what does function X need?
                fn = r.choice(['create_pressure_on_group', 'create_nodal_force', 'envelope_solution', 'get_nodal_values',
                               'create_solution', 'export_result', 'create_force_on_group', 'get_body_properties'])
                q = r.choice([f'What arguments does {fn} take?', f'NX Open: how do I call {fn}?', f'nxopentse {fn} syntax'])
                out = clean(T.call('nx_open', {'op': 'syntax', 'name': fn}))
                ans = (f"`{out['call']}` (in {out['function'].rsplit('.', 1)[0]}). " + out['doc'].split('\n')[0] + ' Arguments: ' +
                       ', '.join(f"{x['name']}" + (f" ({x['type']})" if x['type'] else '') + ('' if x['required'] else f" = {x['default']}")
                                 for x in out['args']) + '.')
                msgs = [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('nx_open', {'op': 'syntax', 'name': fn})},
                        result_msg('nx_open', out), {'role': 'assistant', 'content': ans}]
            elif kind < 0.22:                                    # rename with links
                f = r.choice(['frame_40.prt', 'bracket_a.prt', 'foundation.prt'])
                new = r.choice(['frame_40_rev2', 'bracket_b', 'foundation_v3'])
                q = f'Rename {f} to {new} without breaking the NX assemblies'
                out = clean(T.call('nx_rename', {'file': f, 'new_name': new}))
                ans = (f'Renaming {f} with its links needs Windows with NX installed: the NX File Renamer then uses NX\'s own '
                       'ug_edit_part_names to update every assembly and drawing in the same folder. This computer has no NX. '
                       'On your Windows PC with NX, ask again and I run it; or rename it inside NX (File > Save As, or in '
                       'the Assembly Navigator) so the assemblies follow the new name.')
                msgs = [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('nx_rename', {'file': f, 'new_name': new})},
                        result_msg('nx_rename', out), {'role': 'assistant', 'content': ans}]
            else:
                (q, query, part, calls, what), v = scenarios(r)
                if what is None:
                    continue
                q, what = q.format(**v), what.format(**v)
                part = part.format(**v) if part else None
                found = clean(T.call('nx_open', {'op': 'find', 'query': query}))
                args = {'op': 'journal', 'calls': calls, 'out': f'nx_journal_{i:03d}.py'}
                if part:
                    args['part'] = part
                out = clean(T.call('nx_open', args))
                if 'error' in out:
                    print('skip', out['error'][:200])
                    continue
                ans = (f"I wrote the NX Open journal {out['journal']} using nxopentse. {what} "
                       "NX is not on this computer, so run it in NX: File > Execute > NX Open... (Alt+F8)"
                       + (f" with {part} open, or run_journal.exe {out['journal']} -args {part}." if part else ' with the part open.'))
                msgs = [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('nx_open', {'op': 'find', 'query': query})},
                        result_msg('nx_open', found), {'role': 'assistant', 'content': tool_block('nx_open', args)},
                        result_msg('nx_open', out), {'role': 'assistant', 'content': ans}]
            rows.append({'task': 'nx_open', 'messages': msgs})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked into the samples'
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
