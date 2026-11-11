"""
LLM serving simulation with Simthesizer (https://github.com/casys-kaist/simthesizer, MIT; copied whole into vendor/,
built and run as written - Rust, no GPU needed): how fast a model server answers when many people use it at once.

  build()                 cargo build --release once (about 20 s)
  scenarios()             the measured set-ups that come with it (model + GPU; today Llama 3.1 8B on one RTX Pro 6000)
  simulate(...)           users, arrival rate, prompt / answer length -> time to first token, speed per user,
                          total tokens per second, how long each answer takes (median and 90 %)
New set-ups (another model or GPU) need its profiling on that GPU (scripts/profile.py with vLLM) - see its README.
ShipBrain's own one-PC speed planner is shipbrain.speed (CPU / small GPU, one user).
"""
import json, os, random, shutil, statistics, subprocess, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'simthesizer', 'repo')
TARGET = os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'simthesizer')


def exe():
    p = os.path.join(TARGET, 'release', 'simthesizer' + ('.exe' if os.name == 'nt' else ''))
    return p if os.path.exists(p) else None


def build(log=print):
    if not shutil.which('cargo'):
        raise RuntimeError('Rust is needed to build Simthesizer once (cargo not found)')
    r = subprocess.run(['cargo', 'build', '--release', '-q'], cwd=ROOT, capture_output=True, text=True, timeout=3600,
                       env=dict(os.environ, CARGO_TARGET_DIR=TARGET))
    if r.returncode or not exe():
        raise RuntimeError('Simthesizer build failed: ' + (r.stderr or r.stdout)[-1200:])
    log and log('Simthesizer built: ' + exe())
    return exe()


def scenarios():
    d = os.path.join(ROOT, 'examples', 'scenarios')
    return sorted(x for x in os.listdir(d) if os.path.exists(os.path.join(d, x, 'simthesizer.toml'))) if os.path.isdir(d) else []


def make_workload(path, users=50, rate_per_s=2.0, input_tokens=600, output_tokens=300, seed=0):
    """single-call requests arriving at random (Poisson) at rate_per_s; lengths vary +-30 %"""
    r = random.Random(seed)
    t = 0.0
    with open(path, 'w') as f:
        for i in range(int(users)):
            t += r.expovariate(rate_per_s)
            f.write(json.dumps({'request_id': i, 'arrival_time': round(t, 4), 'initial': [0], 'sub_requests': [
                {'kind': 'llm', 'input_tokens': max(1, int(input_tokens * r.uniform(0.7, 1.3))),
                 'output_tokens': max(1, int(output_tokens * r.uniform(0.7, 1.3))), 'next': []}]}) + '\n')
    return path


def _pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))] if xs else None


def simulate(scenario=None, workload=None, users=50, rate_per_s=2.0, input_tokens=600, output_tokens=300, seed=0):
    e = exe() or build(log=None)
    sc = scenario or (scenarios() or [None])[0]
    if not sc:
        raise RuntimeError('no Simthesizer scenario found')
    cfg = os.path.join(ROOT, 'examples', 'scenarios', sc, 'simthesizer.toml')
    tmp = tempfile.mkdtemp(prefix='sb_serve_')
    wl = workload or make_workload(os.path.join(tmp, 'workload.jsonl'), users, rate_per_s, input_tokens, output_tokens, seed)
    out = os.path.join(tmp, 'sim.jsonl')
    r = subprocess.run([e, '--config', cfg, '--workload', os.path.abspath(wl), '--output-jsonl', out], cwd=ROOT,
                       capture_output=True, text=True, timeout=3600)
    if r.returncode or not os.path.exists(out):
        raise RuntimeError('Simthesizer failed: ' + (r.stderr or r.stdout)[-800:])
    ttft, tpot, e2e, toks, ends, starts = [], [], [], 0, [], []
    for line in open(out):
        d = json.loads(line)
        lat = [x for s in d.get('sub_requests', []) for x in (s.get('token_latency') or [])]
        if not lat:
            continue
        ttft.append(lat[0])
        if len(lat) > 1:
            tpot.append(statistics.mean(lat[1:]))
        e2e.append(sum(lat))
        toks += len(lat)
        starts.append(d['arrival_time'])
        ends.append(d['arrival_time'] + sum(lat))
    span = max(ends) - min(starts) if ends else 0
    res = {'scenario': sc, 'requests': len(e2e), 'ttft_p50_s': round(_pct(ttft, 50), 3), 'ttft_p90_s': round(_pct(ttft, 90), 3),
           'per_user_tokens_s': round(1 / statistics.mean(tpot), 1) if tpot else None,
           'answer_p50_s': round(_pct(e2e, 50), 2), 'answer_p90_s': round(_pct(e2e, 90), 2),
           'total_tokens_s': round(toks / span, 1) if span else None}
    model, gpu = (sc.split('--') + ['', ''])[1], (sc.split('--') + [''])[0]
    res['plain_english'] = (
        f"Simthesizer simulated {res['requests']} requests on {gpu} running {model}: the first word comes after "
        f"{res['ttft_p50_s']} s (90 % within {res['ttft_p90_s']} s), each user then gets about {res['per_user_tokens_s']} tokens/s, "
        f"a whole answer takes {res['answer_p50_s']} s (90 % within {res['answer_p90_s']} s), and the server produces "
        f"{res['total_tokens_s']} tokens/s in total. (Measured set-up of Simthesizer; other models / GPUs need its GPU profiling.)")
    shutil.rmtree(tmp, ignore_errors=True)
    return res
