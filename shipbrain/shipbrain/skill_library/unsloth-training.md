---
name: unsloth-training
description: Unsloth fast fine-tuning: FastLanguageModel, FastVisionModel, 4-bit QLoRA, LoRA settings, GGUF export, train on responses only
when: unsloth|fastlanguagemodel|fastvisionmodel|get_peft_model|save_pretrained_gguf|train_on_responses_only|4.?bit (qlora|training)|gguf export
---
# Unsloth (pack `unsloth`): the library ShipBrain's own training uses

Unsloth makes LoRA / QLoRA fine-tuning of Qwen, Llama, Gemma and other models faster and lighter on memory, and exports the result to GGUF for llama.cpp.
- ShipBrain's run (`training/finetune.py`): load the base in 4 bit (`FastVisionModel.from_pretrained` for the vision model Qwen3-VL-4B, `FastLanguageModel` for text-only), add LoRA with `get_peft_model` (rank 32), train with TRL's SFTTrainer on the assistant turns only (`train_on_responses_only`), optional DPO, save the adapter, export GGUF (q4_k_m) plus the image-part file.
- Continuing from a saved adapter: load the adapter folder as the model name; the incremental run does this (SB_MODE=auto).
- The pack holds the library source, its tests, the CLI and the studio; look up exact function names and arguments there (cite the chunk ids) before changing the training code: the API moves between releases.
