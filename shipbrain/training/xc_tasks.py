"""
XC training samples. XC itself is not installed where the data is made, so NO XC result is ever invented: the conversations teach
the routing and the honest paths only -
  * "run the XC worked example for ..." : knowledge_search in the xc pack (real result), then xc_run with the worked example's own script
    copied unchanged from the XC verification tests; the real outcome here is the install card (XC not installed);
  * assessment requests with missing inputs: ask for them (member, code, loads, materials) instead of running a canned example;
  * "which program checks to Eurocode 2 / AISC 360?": plain answer (XC through xc_run when installed, hand tools meanwhile).

    python training/xc_tasks.py --xc /path/to/xc/verif/tests/materials --out training/data/xc_train.jsonl.gz
"""
import argparse, ast, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

EXAMPLES = [  # file, what the example does (plain words)
    ('ec2/test_ec2_interaction_diagram_01.py', 'the interaction diagram of a circular reinforced concrete column to Eurocode 2'),
    ('ec2/test_ec2_punching_shear_01.py', 'the punching shear resistance of a slab at an internal column to Eurocode 2 (clause 6.4.4)'),
    ('ec2/test_lap_length_01.py', 'anchorage and lap lengths of reinforcement to Eurocode 2 (clause 8.4.4)'),
    ('ec3/member_design/test_buckling_resistance_01.py', 'the buckling resistance of a steel column to Eurocode 3'),
    ('ec3/member_design/test_cross_section_verification_01.py', 'lateral torsional buckling of a steel beam to Eurocode 3'),
    ('ec3/member_design/test_section_classification_02.py', 'the classification of a steel cross-section to EN 1993-1-1 (clause 5.5)'),
    ('ec3/connection_design/test_bolt_shear_01.py', 'bolt shear strength to EN 1993-1-8'),
    ('aci/test_aci_shear_01.py', 'the shear design of a reinforced concrete beam to ACI 318-14'),
    ('ehe/test_shear_ehe08_05.py', 'the shear strength Vsu of a reinforced concrete section to EHE-08'),
    ('ehe/test_minimum_reinforcement_02.py', 'minimum and maximum reinforcement of a reinforced concrete column to EHE'),
]
OPEN = ['Run the XC worked example for {w}', 'Show me XC calculating {w} - run its example', 'Use XC to run the verification example for {w}',
        'I want to see XC at work: run the example for {w}']
ASKS = [
    ('Check my reinforced concrete beam to Eurocode 2', 'Which member and which checks: bending and shear? I need the span and support conditions, the section (width x depth), the concrete class and rebar grade (for example C30/37 and B500B), the bars and stirrups with their diameters and spacing, the cover, and the design moment and shear (kNm, kN). With those I build the model in XC (Eurocode 2 checks) or use the hand formulas.'),
    ('Is this steel column OK to AISC 360?', 'I can check it to AISC 360 with XC, or with the connection checks if it is a joint. For a column I need: the section (for example W14X90), steel grade, length and end conditions (effective length factors), and the loads: axial force and the moments about both axes (kN or kip, kNm or kip-ft). Tell me those and I run the check.'),
    ('Do the interaction diagram for my concrete column', 'Sure. I need the section shape and size (rectangular b x h, or circular diameter), concrete class, rebar grade, the bars (number, diameter and layout) and cover, and the code (Eurocode 2, ACI 318 or EHE). With the axial force and moments I also say if the point is inside the diagram.'),
    ('Assess the slab for punching shear', 'For a punching shear check I need the code (Eurocode 2 or ACI 318), slab thickness, concrete class, the column size and position (internal, edge, corner), the effective depth or cover and the flexural reinforcement ratio, and the design column reaction in kN. Then I calculate the resistance and the utilisation.'),
    ('Eurocode 3 check of my beam please', 'Which checks: bending, shear, lateral torsional buckling? I need the section (for example IPE400), steel grade, span, how the beam is restrained against sideways buckling, and the loads or the design moment and shear (kNm, kN). Then I run the check with XC (or by hand formulas while XC is not installed).'),
]
WHICH = [
    ('Which program do you use for Eurocode 2 concrete checks?', 'For code checks of concrete and steel members (Eurocode 2 and 3, ACI 318, AISC 360, EHE) ShipBrain uses XC, an open source finite element program with the code checks built in: I write the XC model for your member and run it with the xc_run tool. XC must be installed on your computer (easiest with Docker: docker pull engthiago/xcfem); until then I can give you hand-formula checks and the plate, stiffener and bolt tools.'),
    ('Can you run AISC 360 and Eurocode 3 member checks?', 'Yes, through XC (open source, runs from a Docker image or a local install): I write the model from your section, material, lengths and loads and read back the utilisation ratios. Without XC installed I fall back on hand formulas, and for bolted joints the connection check (AISC 360) and bolt group tools work today.'),
]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--xc', required=True, help='folder verif/tests/materials of the XC repository')
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'xc_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge, xcfem
    from shipbrain.repopack import load_packs
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    if xcfem.exe() is not None:
        sys.exit('XC is installed here: run the examples for real instead of teaching the not-installed path')
    work = tempfile.mkdtemp(prefix='sb_xc_')
    packs = os.path.join(work, 'packs')
    os.makedirs(packs)
    shutil.copy(os.path.join(os.path.dirname(HERE), 'packs', 'xc.sbpack'), packs)
    rk = knowledge.Knowledge()
    load_packs(packs, rk)
    T = agent.Tools(work, knowledge.load(None), repo_kb=rk)
    rows = []
    for fn, what in EXAMPLES:
        src = open(os.path.join(a.xc, fn), encoding='utf-8', errors='replace').read()
        ast.parse(src)
        for _ in range(2):
            q = r.choice(OPEN).format(w=what)
            sq = {'query': 'xc ' + what, 'scope': 'xc'}
            s1 = T.call('knowledge_search', sq)
            if 'error' in s1:
                continue
            xa = {'script': src, 'name': os.path.splitext(os.path.basename(fn))[0]}
            s2 = T.call('xc_run', xa)
            if 'error' not in s2 or 'install' not in s2:
                raise SystemExit('unexpected: xc_run did not give the install card')
            ans = (f"XC is not installed on this computer, so I could not run it. The worked example script is saved as {xa['name']}.py in your work folder. "
                   f"{s2['install']['message']}")
            rows.append({'task': 'xc_example', 'messages': [
                {'role': 'user', 'content': q}, {'role': 'assistant', 'content': 'First I look up the closest worked example in the XC knowledge.\n' + tool_block('knowledge_search', sq)},
                result_msg('knowledge_search', s1),
                {'role': 'assistant', 'content': f'The XC verification example for {what} fits. I run it unchanged.\n' + tool_block('xc_run', xa)},
                result_msg('xc_run', s2), {'role': 'assistant', 'content': ans}]})
    for q, ans in ASKS:
        rows.append({'task': 'xc_ask', 'messages': [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': ans}]})
    for q, ans in WHICH:
        rows.append({'task': 'xc_which', 'messages': [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': ans}]})
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked'
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows))


if __name__ == '__main__':
    main()
