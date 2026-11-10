# One file for the model: llamafile

A **llamafile** is the model weights and a CPU inference server in a single executable that runs on Windows, Linux and macOS.
ShipBrain starts it for you (`--model shipbrain.llamafile`) and talks to it on `127.0.0.1:8081`.

## Make it (once, on any PC with the trained GGUF)

```bash
# 1. get the llamafile runtime (Mozilla-Ocho/llamafile releases): llamafile-<ver>  and  zipalign-<ver>
cp llamafile-0.9.3 shipbrain.llamafile

# 2. default arguments baked into the file
cat > .args <<'EOF'
-m
shipbrain-q4_k_m.gguf
--ctx-size
8192
...
EOF

# 3. pack the weights + args into the executable
./zipalign-0.9.3 -j0 shipbrain.llamafile shipbrain-q4_k_m.gguf .args
```

On Windows rename it to `shipbrain.exe` (or keep `.llamafile` — ShipBrain launches either).
Windows refuses executables larger than 4 GB: use a 4B model in `q4_k_m` (~2.5 GB) or smaller; for an 8B model keep the GGUF
separate and run `llamafile.exe -m shipbrain-8b-q4_k_m.gguf` or `llama-server`.

## Without llamafile

Any OpenAI-compatible CPU server works, ShipBrain just needs its URL:

| Server | Start | ShipBrain |
|---|---|---|
| llama.cpp | `llama-server -m shipbrain-q4_k_m.gguf --port 8080` | `--server http://127.0.0.1:8080` (default) or `--model x.gguf` to auto-start |
| Ollama | `ollama create shipbrain -f Modelfile` then `ollama serve` | `--server http://127.0.0.1:11434 --model-name shipbrain` |
| LM Studio | load the GGUF, start the local server | `--server http://127.0.0.1:1234` |

Ollama `Modelfile`:
```
FROM ./shipbrain-q4_k_m.gguf
PARAMETER temperature 0.2
PARAMETER num_ctx 8192
```

## CPU speed guide (q4_k_m, 8-core desktop CPU, 16 GB RAM)

| Base model | GGUF size | RAM | Speed |
|---|---|---|---|
| Qwen3-1.7B | ~1.1 GB | ~2 GB | ~15–25 tokens/s |
| Qwen3-4B | ~2.5 GB | ~4 GB | ~6–12 tokens/s |
| Qwen3-8B | ~5 GB | ~7 GB | ~3–6 tokens/s |

These are typical figures, not measurements on your workstation. A tool call is ~60–150 tokens, so a mesh request answers in
roughly 10–40 s with the 4B model.
