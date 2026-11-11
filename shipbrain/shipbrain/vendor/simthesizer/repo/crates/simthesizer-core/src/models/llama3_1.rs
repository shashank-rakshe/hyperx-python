use anyhow::{bail, Result};
use serde::Deserialize;

use crate::model::Model;
use crate::module::Module;
use crate::types::{Layer, ParallelStrategy};

const FP_BYTES: u64 = 2;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Llama31Model {
    pub hidden_size: u64,
    pub intermediate_size: u64,
    pub max_position_embeddings: u64,
    pub num_attention_heads: u64,
    pub num_hidden_layers: u32,
    pub num_key_value_heads: u64,
    pub vocab_size: u64,

    #[serde(skip, default)]
    pre_block_layers: Vec<Layer>,

    #[serde(skip, default)]
    block_layers: Vec<Layer>,

    #[serde(skip, default)]
    post_block_layers: Vec<Layer>,

    #[serde(skip, default)]
    weight_bytes_per_device: u64,

    #[serde(skip, default)]
    kv_bytes_per_token_per_device: u64,
}

crate::register_model!(Llama31Model, "llama3_1");

impl Module for Llama31Model {}

impl Llama31Model {
    fn local_num_kv_heads(&self, tp_size: u32) -> u64 {
        (self.num_key_value_heads / u64::from(tp_size)).max(1)
    }

    fn kv_dim(&self, tp_size: u32) -> u64 {
        self.local_num_kv_heads(tp_size) * self.head_dim()
    }

    fn head_dim(&self) -> u64 {
        self.hidden_size / self.num_attention_heads
    }

    fn tp_sync_bytes_per_token(&self) -> u64 {
        self.hidden_size * FP_BYTES
    }

    fn build_pre_block_layers(&self) -> Vec<Layer> {
        vec![Layer::Embedding {
            name: "embedding".to_string(),
            num_embeddings: self.vocab_size,
            embedding_dim: self.hidden_size,
        }]
    }

    fn build_dense_block_layers(&self, tp_size: u32) -> Vec<Layer> {
        let tp = u64::from(tp_size);
        let kv_dim = self.kv_dim(tp_size);
        let mut layers = vec![
            Layer::LayerNorm {
                name: "layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Gemm {
                name: "qkv_projection".to_string(),
                m: self.hidden_size,
                n: self.hidden_size / tp + 2 * kv_dim,
            },
            Layer::Rope {
                name: "rope".to_string(),
                head_dim: self.head_dim(),
                num_heads: self.num_attention_heads / tp,
            },
            Layer::Attention {
                name: "attention".to_string(),
                num_q_heads: self.num_attention_heads / tp,
                num_kv_heads: self.local_num_kv_heads(tp_size),
                head_dim: self.head_dim(),
            },
            Layer::Gemm {
                name: "o_projection".to_string(),
                m: self.hidden_size / tp,
                n: self.hidden_size,
            },
        ];
        if tp_size > 1 {
            layers.push(Layer::AllReduce {
                name: "all_reduce".to_string(),
                bytes_per_token: self.tp_sync_bytes_per_token(),
            });
        }
        layers.extend([
            Layer::LayerNorm {
                name: "layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Gemm {
                name: "ffn1".to_string(),
                m: self.hidden_size,
                n: 2 * (self.intermediate_size / tp),
            },
            Layer::Act {
                name: "act".to_string(),
                width: self.intermediate_size / tp,
            },
            Layer::Gemm {
                name: "ffn2".to_string(),
                m: self.intermediate_size / tp,
                n: self.hidden_size,
            },
        ]);
        if tp_size > 1 {
            layers.push(Layer::AllReduce {
                name: "all_reduce".to_string(),
                bytes_per_token: self.tp_sync_bytes_per_token(),
            });
        }
        layers
    }

    fn build_post_block_layers(&self, tp_size: u32) -> Vec<Layer> {
        let tp = u64::from(tp_size);
        vec![
            Layer::LayerNorm {
                name: "final_layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Gemm {
                name: "lm_head".to_string(),
                m: self.hidden_size,
                n: self.vocab_size / tp,
            },
            Layer::Sampler {
                name: "sampler".to_string(),
                vocab_size: self.vocab_size,
            },
        ]
    }

    fn compute_weight_bytes_per_device(&self, tp_size: u32) -> u64 {
        let tp = u64::from(tp_size);
        let kv_dim = self.kv_dim(tp_size);
        let embed = (self.vocab_size / tp) * self.hidden_size;
        let q_proj = self.hidden_size * (self.hidden_size / tp);
        let k_proj = self.hidden_size * kv_dim;
        let v_proj = self.hidden_size * kv_dim;
        let o_proj = (self.hidden_size / tp) * self.hidden_size;
        let attn = q_proj + k_proj + v_proj + o_proj;
        let mlp = 2 * self.hidden_size * (self.intermediate_size / tp)
            + (self.intermediate_size / tp) * self.hidden_size;
        let layernorm = 2 * self.hidden_size;
        let block = attn + mlp + layernorm;
        let final_norm = self.hidden_size;
        let lm_head = self.hidden_size * (self.vocab_size / tp);
        FP_BYTES * (embed + u64::from(self.num_hidden_layers) * block + final_norm + lm_head)
    }

    fn compute_kv_bytes_per_token_per_device(&self, tp_size: u32) -> u64 {
        2 * self.kv_dim(tp_size) * u64::from(self.num_hidden_layers) * FP_BYTES
    }
}

impl Model for Llama31Model {
    fn init(&mut self, parallel: ParallelStrategy) -> Result<()> {
        let tp_size = parallel.tp;
        if tp_size == 0 {
            bail!("tp_size must be positive");
        }
        if self.hidden_size == 0 {
            bail!("hidden_size must be positive");
        }
        if self.intermediate_size == 0 {
            bail!("intermediate_size must be positive");
        }
        if self.max_position_embeddings == 0 {
            bail!("max_position_embeddings must be positive");
        }
        if self.num_attention_heads == 0 {
            bail!("num_attention_heads must be positive");
        }
        if self.num_key_value_heads == 0 {
            bail!("num_key_value_heads must be positive");
        }
        if self.num_hidden_layers == 0 {
            bail!("num_hidden_layers must be positive");
        }
        if self.vocab_size == 0 {
            bail!("vocab_size must be positive");
        }
        if !self.hidden_size.is_multiple_of(self.num_attention_heads) {
            bail!("hidden_size must be divisible by num_attention_heads");
        }
        if !self
            .num_attention_heads
            .is_multiple_of(self.num_key_value_heads)
        {
            bail!("num_attention_heads must be divisible by num_key_value_heads");
        }
        let tp = u64::from(tp_size);
        if !self.num_attention_heads.is_multiple_of(tp) {
            bail!("num_attention_heads must be divisible by tp_size");
        }
        if self.num_key_value_heads >= tp {
            if !self.num_key_value_heads.is_multiple_of(tp) {
                bail!("num_key_value_heads must be divisible by tp_size when sharded");
            }
        } else if !tp.is_multiple_of(self.num_key_value_heads) {
            bail!("tp_size must be divisible by num_key_value_heads when replicated");
        }

        self.pre_block_layers = self.build_pre_block_layers();
        self.block_layers = self.build_dense_block_layers(tp_size);
        self.post_block_layers = self.build_post_block_layers(tp_size);
        self.weight_bytes_per_device = self.compute_weight_bytes_per_device(tp_size);
        self.kv_bytes_per_token_per_device = self.compute_kv_bytes_per_token_per_device(tp_size);
        Ok(())
    }

    fn weight_bytes_per_device(&self) -> u64 {
        self.weight_bytes_per_device
    }

    fn kv_bytes_per_token_per_device(&self) -> u64 {
        self.kv_bytes_per_token_per_device
    }

    fn pre_block_layers(&self) -> &[Layer] {
        &self.pre_block_layers
    }

    fn block_layers(&self) -> &[Layer] {
        &self.block_layers
    }

    fn post_block_layers(&self) -> &[Layer] {
        &self.post_block_layers
    }

    fn num_blocks(&self) -> u32 {
        self.num_hidden_layers
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scheduler::Scheduler;
    use crate::types::ReadySubRequest;
    use serde_json::json;

    fn model() -> Llama31Model {
        serde_json::from_value(json!({
            "hidden_size": 4096, "intermediate_size": 14336,
            "max_position_embeddings": 131072, "num_attention_heads": 32,
            "num_hidden_layers": 32, "num_key_value_heads": 8, "vocab_size": 128256
        }))
        .unwrap()
    }

    fn parallel(tp: u32) -> ParallelStrategy {
        ParallelStrategy { tp, pp: 1, ep: 1 }
    }

    #[test]
    fn tp_shapes_and_memory_include_replicated_kv_heads() {
        // BF16 tensor counts for the fixture, including replicated K/V weights.
        for (tp, kv_heads, qkv_width, kv_bytes, weight_bytes) in [
            (1, 8, 6144, 131072, 16060522496),
            (2, 4, 3072, 65536, 8030527488),
            (8, 1, 768, 16384, 2008031232),
            (16, 1, 512, 16384, 1037836288),
            (32, 1, 384, 16384, 552738816),
        ] {
            let mut model = model();
            model.init(parallel(tp)).unwrap();
            assert_eq!(model.kv_bytes_per_token_per_device(), kv_bytes, "TP={tp}");
            assert_eq!(model.weight_bytes_per_device(), weight_bytes, "TP={tp}");
            assert!(
                model.block_layers().iter().any(|layer| matches!(layer,
                    Layer::Attention { num_q_heads, num_kv_heads, head_dim, .. }
                        if *num_q_heads == 32 / u64::from(tp)
                            && *num_kv_heads == kv_heads && *head_dim == 128
                )),
                "TP={tp}"
            );
            assert!(
                model.block_layers().iter().any(|layer| matches!(layer,
                    Layer::Gemm { name, m: 4096, n } if name == "qkv_projection" && *n == qkv_width
                )),
                "TP={tp}"
            );
        }
    }

    #[test]
    fn invalid_head_partitions_fail_before_building_layers() {
        for (q_heads, kv_heads, tp, error) in [
            (32, 8, 0, "tp_size must be positive"),
            (32, 8, 3, "num_attention_heads must be divisible by tp_size"),
            (
                32,
                8,
                64,
                "num_attention_heads must be divisible by tp_size",
            ),
            (
                24,
                6,
                4,
                "num_key_value_heads must be divisible by tp_size when sharded",
            ),
            (
                24,
                6,
                8,
                "tp_size must be divisible by num_key_value_heads when replicated",
            ),
        ] {
            let mut model = model();
            model.hidden_size = q_heads * 128;
            model.num_attention_heads = q_heads;
            model.num_key_value_heads = kv_heads;
            assert_eq!(model.init(parallel(tp)).unwrap_err().to_string(), error);
            assert!(model.block_layers().is_empty());
        }
    }

    #[test]
    fn replicated_kv_memory_limits_admission_and_is_released() {
        let mut model = model();
        model.init(parallel(16)).unwrap();
        let mut scheduler: Box<dyn Scheduler> = serde_json::from_value(json!({
            "kind": "chunked_prefill", "block_size": 4, "max_batch": 2,
            "max_num_batched_tokens": 8, "device_mem": 1037836288_u64 + 4 * 16384,
            "device_mem_utilization": 1.0, "enable_prefix_caching": false
        }))
        .unwrap();
        scheduler
            .init(
                model.scheduler_model_weight_bytes(),
                model.scheduler_kv_bytes_per_request(),
                model.scheduler_kv_bytes_per_token(),
                parallel(16),
            )
            .unwrap();
        for id in 0..2 {
            scheduler.enqueue_sub_request(ReadySubRequest {
                request_id: id,
                subrequest_index: 0,
                completion_node_id: id,
                arrival_time: 0.0,
                input_tokens: 4,
                output_tokens: 1,
                known_tokens: 4,
                kv_tokens: 0,
                input_token_ids: None,
                output_token_ids: None,
            });
        }
        assert_eq!(scheduler.schedule().unwrap().len(), 1);
        assert_eq!(scheduler.done_iteration(1.0).len(), 1);
        assert_eq!(scheduler.schedule().unwrap().len(), 1);
        assert_eq!(scheduler.done_iteration(2.0).len(), 1);
        assert!(scheduler.schedule().unwrap().is_empty());
    }
}
