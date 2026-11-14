"""
cad3dify (https://github.com/neka-nat/cad3dify, MIT), copied whole into vendor/ and run as written:
a 2D CAD drawing picture -> CadQuery code (vision model, with its own prompt and CadQuery examples) -> run -> STEP ->
render the result -> the model compares render and drawing and corrects the code -> run again (num_refinements times).

It was written for cloud models. ShipBrain runs it, unchanged, in its own process with ShipBrain's OWN model: a small
launcher (below) makes its chat model the local model server (llama-server / Ollama / LM Studio speak the same
OpenAI API) and uses its "execute only" path (no tool-calling agent, which small local models do not need). The cloud
SDKs it imports at the top (Anthropic, Google) are not needed and not installed: empty stand-ins are given instead.

Needs: langchain<1, langchain-openai<1, langchain-experimental<1, svglib, rlPyCairo, loguru (+ cadquery).
"""
import json, os, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'cad3dify', 'repo')

_LAUNCH = r'''
import json, os, sys, types
cfg = json.loads(sys.argv[1])
for name, cls in (('langchain_anthropic', 'ChatAnthropic'), ('langchain_google_genai', 'ChatGoogleGenerativeAI')):
    try:
        __import__(name)
    except ImportError:                       # cloud SDK not installed: never used with ShipBrain's own model
        m = types.ModuleType(name)
        setattr(m, cls, type(cls, (), {}))
        sys.modules[name] = m
sys.path.insert(0, cfg['root'])
from cad3dify import chat_models
from langchain_openai import ChatOpenAI


def _local(self):
    return ChatOpenAI(base_url=cfg['base_url'], api_key=cfg.get('api_key') or 'local', model=cfg.get('model') or 'local',
                      temperature=min(self.temperature, 0.7), max_tokens=cfg.get('max_tokens', 3000), timeout=cfg.get('timeout', 900))


chat_models.ChatModelParameters.create_chat_model = _local
from cad3dify.pipeline import generate_step_from_2d_cad_image
generate_step_from_2d_cad_image(cfg['image'], cfg['out'], num_refinements=cfg['refinements'], model_type='llama')
print('@@DONE@@', os.path.exists(cfg['out']))
'''


def load_upstream():
    """import cad3dify's own package in THIS process (for its prompts, render and image code): cloud SDKs it imports
    at the top are replaced by empty stand-ins, its chat model by a no-call placeholder"""
    import types
    for name, cls in (('langchain_anthropic', 'ChatAnthropic'), ('langchain_google_genai', 'ChatGoogleGenerativeAI')):
        try:
            __import__(name)
        except ImportError:
            m = types.ModuleType(name)
            setattr(m, cls, type(cls, (), {}))
            sys.modules[name] = m
    if ROOT not in sys.path:
        sys.path.insert(0, ROOT)
    import cad3dify as up
    from cad3dify import chat_models
    from langchain_core.language_models.fake_chat_models import FakeListChatModel
    chat_models.ChatModelParameters.create_chat_model = lambda self: FakeListChatModel(responses=['```python\n```'])
    return up


def prompts(code_example='result = cq.Workplane("XY").box(1, 1, 1)'):
    """cad3dify's own prompt texts, exactly as it sends them on the local-model path: (generate, refine(code))"""
    up = load_upstream()
    from cad3dify.v1.cad_code_generator import CadCodeGeneratorChain
    from cad3dify.v1.cad_code_refiner import CadCodeRefinerChain
    gen = CadCodeGeneratorChain(model_type='llama').chains[0].prompt.messages[0].prompt[0].format()
    ref_t = CadCodeRefinerChain(model_type='llama').chains[0].prompt.messages[0].prompt[0]
    return gen, lambda code: ref_t.format(code=code)


def available():
    return os.path.isdir(ROOT)


def run(image, out_step, base_url, refinements=2, model='local', api_key=None, max_tokens=3000, timeout=3600):
    """drawing picture -> STEP with cad3dify's own pipeline on the given (local) model server"""
    if not available():
        raise RuntimeError('cad3dify is not in shipbrain/vendor')
    for mod in ('langchain', 'langchain_openai', 'langchain_experimental', 'svglib', 'loguru'):
        try:
            __import__(mod)
        except ImportError:
            raise ModuleNotFoundError(f"No module named '{mod}'")
    png = os.path.splitext(os.path.abspath(out_step))[0] + '_drawing.png'
    if image.lower().endswith('.pdf'):                       # first page of a PDF drawing
        from .drawings import load_image
        from PIL import Image
        Image.fromarray(load_image(image, 0, dpi=150).clip(0, 255).astype('uint8')).save(png)
    else:                                                    # cad3dify saves merged pictures as Pillow format 'JPG', which
        from PIL import Image                                # Pillow does not know (upstream bug): always give it a PNG
        Image.open(image).convert('RGB').save(png)
    image = png
    base = base_url.rstrip('/')
    base = base if base.endswith('/v1') else base + '/v1'
    cfg = {'root': ROOT, 'image': os.path.abspath(image), 'out': os.path.abspath(out_step), 'base_url': base, 'model': model,
           'api_key': api_key, 'refinements': int(refinements), 'max_tokens': max_tokens}
    if os.path.exists(cfg['out']):
        os.remove(cfg['out'])
    r = subprocess.run([sys.executable, '-c', _LAUNCH, json.dumps(cfg)], capture_output=True, text=True, timeout=timeout,
                       cwd=os.path.dirname(cfg['out']))
    log = (r.stderr or '') + (r.stdout or '')
    if not os.path.exists(cfg['out']):
        raise RuntimeError('cad3dify made no STEP: ' + log.strip()[-1200:])
    codes = [ln for ln in log.splitlines() if 'code generation complete' in ln]
    return {'step': cfg['out'], 'rounds': len(codes), 'log_tail': log.strip()[-1500:]}
