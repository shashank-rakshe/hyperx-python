---
name: llm-finetuning-llamafactory
description: fine-tuning a language model with LLaMA-Factory: LoRA, QLoRA, DPO, KTO, ORPO, multimodal Qwen3-VL, dataset formats, YAML configs
when: llama.?factory|llamafactory|fine.?tun(e|ing) (a |the )?(model|llm)|lora|qlora|\bdpo\b|\bkto\b|\borpo\b|sft config|alpaca format|sharegpt
---
# Fine-tuning with LLaMA-Factory (pack `LlamaFactory`, Apache-2.0)

LLaMA-Factory is a training framework for many models (Qwen3, Qwen3-VL, Llama, Gemma, DeepSeek ...) with LoRA and 2 to 8-bit QLoRA, supervised fine-tuning, reward modelling, DPO / KTO / ORPO / PPO, driven by a YAML file (`llamafactory-cli train config.yaml`) or a web UI.
- Data: JSON files in alpaca or sharegpt format, listed in `data/dataset_info.json`; multimodal samples carry image paths. ShipBrain's own training files are chat messages (`messages` lists with a tool-call block): they would need a short converter to sharegpt.
- ShipBrain's own run uses Unsloth with TRL (`training/finetune.py`): 4-bit QLoRA of Qwen3-VL-4B on a 16 GB GPU, then DPO, then GGUF export. LLaMA-Factory is the alternative to look at if you want a ready YAML-driven trainer, multi-GPU, or another method (KTO, ORPO); it also lists Unsloth and Liger Kernel as options.
- Look up exact YAML keys and the Qwen3-VL examples in the pack (cite the chunk ids) before writing a config.
