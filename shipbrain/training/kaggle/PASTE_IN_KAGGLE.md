# Start ShipBrain training on Kaggle: paste one cell

1. Kaggle -> Create -> New Notebook. Right side **Settings**: Accelerator **GPU T4 x2** (or P100), **Internet On**, Persistence none.
2. Add-ons -> Secrets (once): `HF_TOKEN` = a Hugging Face token with **write** access (keeps the model state for the next incremental run and a private copy of the GGUF), optional `GH_TOKEN` (progress on GitHub).
3. Paste this in the first cell and Run (or Save Version -> Save & Run All):

```python
!curl -sL https://raw.githubusercontent.com/shashank-rakshe/hyperx-python/claude/new-session-qpeo6g/shipbrain/training/kaggle/kernel.py -o /kaggle/working/kernel.py
%run /kaggle/working/kernel.py
```

The cell downloads the code and all the data itself (git clone of the repository, packs, training data files, class rule books, GitHub release data); nothing else to attach.

## Full or only new data

| You write before the `%run` line | What happens |
|---|---|
| nothing (default `auto`) | first run: trains on ALL data and saves the state. Later runs: trains only on samples the saved model has not seen + 10 % replay, continuing from its saved adapter |
| `import os; os.environ['SB_MODE']='full'` | everything again from the base model |
| `import os; os.environ['SB_MODE']='new'` | incremental, and stop with an error if no saved state exists (never silently retrains everything) |
| `import os; os.environ['SB_REPLAY']='0'` | pure new data, no replay (fastest, more forgetting risk) |

Adding data later = just add it to the repository (a new pack, a new `training/data/*.jsonl.gz`, new tasks) and run the same cell again. Samples are recognised by content, so the same sample is never learned twice.
If the saved state is lost, or the base model in `training/base_model.json` changes, the run falls back to full training and says why. A run that the accept gate rejects does NOT update the saved state, so the next run tries the same new data again.

## Time budget

A run is stopped by Kaggle after 12 h, and the free GPU quota is about 30 h per week. `SB_BUDGET_H` (default 11) makes the run skip the optional last steps (small draft model, speed measurement) when less than 2 h of the budget are left, so the main model and its GGUF are never lost to them. Set `import os; os.environ['SB_BUDGET_H']='8'` before the `%run` line to be more careful.

## Make the data on a CPU notebook (no GPU quota), then train on the GPU

1. New notebook, **Accelerator: None**, Internet On. Cell:
```python
import os
os.environ['SB_DATA_ONLY'] = '1'
os.environ['SB_N_TRAIN'] = '2500'
!curl -sL https://raw.githubusercontent.com/shashank-rakshe/hyperx-python/claude/new-session-qpeo6g/shipbrain/training/kaggle/kernel.py -o /kaggle/working/kernel.py
%run /kaggle/working/kernel.py
```
   Save Version -> Save & Run All. It makes all training data, writes `shipbrain_train_data/` to its Output and stops (about 1 to 1.5 h, uses no GPU quota). A `[heartbeat]` line every 5 minutes shows it is alive.
2. GPU notebook: Add Input -> Notebooks -> your CPU notebook (its output). Use the normal cell (with `SB_FAST`). The log says `data steps skipped: ready-made data from ...` and goes straight to scoring and training.
Data that the CPU notebook made from private packs (class rules) makes the model private (never published).
