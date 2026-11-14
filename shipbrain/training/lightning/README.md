# Train ShipBrain on Lightning AI

Lightning AI Studios are Linux machines with a persistent disk: you can run the data steps on a cheap CPU machine, then switch the same Studio to a GPU machine and train, and the files are still there.

1. Create a Studio (Python). Open the terminal. Check the free credits and the GPU price in your account (I do not know your current allowance).
2. Get the launcher (it downloads the training code from GitHub itself):
   ```bash
   curl -sL https://raw.githubusercontent.com/shashank-rakshe/hyperx-python/claude/new-session-qpeo6g/shipbrain/training/lightning/run_lightning.sh -o run_lightning.sh
   ```
3. Optional: `export HF_TOKEN=...` (a Hugging Face WRITE token: keeps the model state for incremental runs). Never paste the token into a chat.
4. **Data (CPU machine, about 1.5 h):** `nohup bash run_lightning.sh data > data.out 2>&1 &` then `tail -f data.out`. It ends with `DATA READY` and a table of every data file with its sample count.
5. **Switch the Studio to a GPU machine.** The 4B vision model needs about 16 GB of GPU memory (T4 16 GB or better; L4 / A10G 24 GB is faster).
6. **Train:** `export SB_FAST=1` (shorter), then `nohup bash run_lightning.sh train > train.out 2>&1 &`. The run keeps going when you close the browser; look at it with `tail -f train.out`. Studios may sleep when idle: use `nohup` and check the credits.
7. Results are in `~/shipbrain_run/working/`: `shipbrain-q4_k_m.gguf` (and the vision file), `summary.json`. Download them from the Studio file browser.

Later (new data only): run `bash run_lightning.sh train` again. With `HF_TOKEN` set, it trains on the new samples plus a small replay.
Settings: `SB_FAST=1`, `SB_N_TRAIN=2500`, `SB_CLASS_RULES=0`, `SB_MODE=full|auto|new`, `SB_STEP_LIMIT=<seconds>`.
Not tested on Lightning itself: the script only swaps two folder names in the Kaggle run; the GPU steps run for the first time there.
