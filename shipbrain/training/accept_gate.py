"""
Accept a retrained model only if it did not get worse. Compares the scorecard (and the tool-call evaluation) before and
after training, writes accept.json, exit code 0 = accepted, 1 = rejected.

Rules (all must hold):
  * overall scorecard score after >= before - 1 point (noise margin for one item)
  * no scorecard category loses more than 5 points
  * the 'missing' (asks) and 'no_tool' (never invents numbers) categories do not drop at all - they protect against
    the worst failure: a confident wrong answer
  * the tool-call evaluation (tool_ok / args_ok totals) does not drop by more than 3 points

    python training/accept_gate.py --before scorecard_before.json --after scorecard_after.json \
        [--eval-before eval_before.json --eval-after eval_after.json] --out accept.json
"""
import argparse, json, sys


def pct(s):
    n, d = s.split()[0].split('/')
    return 100.0 * int(n) / max(1, int(d))


def gate(before, after, eval_before=None, eval_after=None):
    reasons, rows = [], {}
    for cat in sorted(set(before) | set(after)):
        b, a = pct(before[cat]) if cat in before else 0.0, pct(after[cat]) if cat in after else 0.0
        rows[cat] = {'before': round(b, 1), 'after': round(a, 1), 'change': round(a - b, 1)}
    if 'ALL' in rows and rows['ALL']['change'] < -1.0:
        reasons.append(f"overall score fell {-rows['ALL']['change']:.1f} points")
    for cat, r in rows.items():
        if cat == 'ALL':
            continue
        if r['change'] < -5.0:
            reasons.append(f"{cat} fell {-r['change']:.1f} points")
        if cat in ('missing', 'no_tool') and r['change'] < 0:
            reasons.append(f"{cat} dropped ({r['before']} -> {r['after']}): the model got less careful about asking / inventing")
    if eval_before and eval_after:
        for k in ('tool_ok', 'args_ok'):
            nb, na = eval_before.get('n', 0) or 1, eval_after.get('n', 0) or 1
            d = 100.0 * (eval_after.get(k, 0) / na - eval_before.get(k, 0) / nb)
            rows.setdefault('eval_' + k, {'change': round(d, 1)})
            if d < -3.0:
                reasons.append(f'tool-call evaluation {k} fell {-d:.1f} points')
    return {'accepted': not reasons, 'reasons': reasons, 'categories': rows}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--before', required=True)
    ap.add_argument('--after', required=True)
    ap.add_argument('--eval-before')
    ap.add_argument('--eval-after')
    ap.add_argument('--out', default='accept.json')
    a = ap.parse_args(argv)
    sb, sa = json.load(open(a.before))['summary'], json.load(open(a.after))['summary']
    eb = json.load(open(a.eval_before))['total'] if a.eval_before else None
    ea = json.load(open(a.eval_after))['total'] if a.eval_after else None
    res = gate(sb, sa, eb, ea)
    json.dump(res, open(a.out, 'w'), indent=1)
    print('ACCEPTED' if res['accepted'] else 'REJECTED: ' + '; '.join(res['reasons']))
    sys.exit(0 if res['accepted'] else 1)


if __name__ == '__main__':
    main()
