use anyhow::{bail, Result};
use serde::Deserialize;

use crate::model::Model;
use crate::module::Module;
use crate::types::{Layer, ParallelStrategy};

const FP_BYTES: u64 = 2;

fn default_mamba_ssm_state_dtype_bytes() -> u64 {
    4
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NemotronHModel {
    pub hidden_size: u64,
    pub intermediate_size: u64,
    pub num_hidden_layers: u32,
    pub hybrid_override_pattern: String,
    pub num_attention_heads: u64,
    pub head_dim: u64,
    pub num_key_value_heads: u64,
    pub vocab_size: u64,

    pub mamba_num_heads: u64,
    pub mamba_head_dim: u64,
    pub n_groups: u64,
    pub ssm_state_size: u64,
    pub conv_kernel: u64,

    pub moe_intermediate_size: u64,
    pub moe_shared_expert_intermediate_size: u64,
    pub n_routed_experts: u64,
    pub n_shared_experts: u32,
    pub num_experts_per_tok: u32,

    #[serde(default)]
    pub use_bias: bool,

    #[serde(default = "default_true")]
    pub use_conv_bias: bool,

    #[serde(default = "default_mamba_ssm_state_dtype_bytes")]
    pub mamba_ssm_state_dtype_bytes: u64,

    #[serde(skip, default)]
    pre_block_layers: Vec<Layer>,

    #[serde(skip, default)]
    block_layers: Vec<Layer>,

    #[serde(skip, default)]
    post_block_layers: Vec<Layer>,

    #[serde(skip, default)]
    block_count: u32,

    #[serde(skip, default)]
    weight_bytes_per_device: u64,

    #[serde(skip, default)]
    kv_bytes_per_token_per_device: u64,

    #[serde(skip, default)]
    kv_bytes_per_request_per_device: u64,

    #[serde(skip, default)]
    scheduler_kv_bytes_per_request: u64,

    #[serde(skip, default)]
    scheduler_kv_bytes_per_token: u64,
}

crate::register_model!(NemotronHModel, "nemotron_h");

impl Module for NemotronHModel {}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HybridBlockKind {
    Mamba,
    Attention,
    DenseMlp,
    Moe,
}

impl NemotronHModel {
    fn ep_divisor(ep_size: u32) -> u64 {
        u64::from(ep_size.max(1))
    }

    fn scheduler_memory_divisor(ep_size: u32) -> u64 {
        Self::ep_divisor(ep_size)
    }

    fn moe_dispatch_bytes_per_token(&self) -> u64 {
        self.hidden_size * FP_BYTES + self.n_routed_experts * FP_BYTES
    }

    fn moe_combine_bytes_per_token(&self) -> u64 {
        self.hidden_size * FP_BYTES
    }

    fn mamba_intermediate_size(&self) -> u64 {
        self.mamba_num_heads * self.mamba_head_dim
    }

    fn mamba_conv_dim(&self) -> u64 {
        self.mamba_intermediate_size() + 2 * self.n_groups * self.ssm_state_size
    }

    fn local_num_experts(&self, ep_size: u32) -> u64 {
        self.n_routed_experts.div_ceil(Self::ep_divisor(ep_size))
    }

    fn layer_kind(symbol: char) -> Result<HybridBlockKind> {
        match symbol {
            'M' => Ok(HybridBlockKind::Mamba),
            '*' => Ok(HybridBlockKind::Attention),
            '-' => Ok(HybridBlockKind::DenseMlp),
            'E' => Ok(HybridBlockKind::Moe),
            _ => bail!("unsupported hybrid_override_pattern symbol '{symbol}'"),
        }
    }

    fn block_kinds(&self) -> Result<Vec<HybridBlockKind>> {
        self.hybrid_override_pattern
            .chars()
            .map(Self::layer_kind)
            .collect()
    }

    fn build_pre_block_layers(&self) -> Vec<Layer> {
        vec![Layer::Embedding {
            name: "embedding".to_string(),
            num_embeddings: self.vocab_size,
            embedding_dim: self.hidden_size,
        }]
    }

    fn build_attention_block(&self) -> Vec<Layer> {
        vec![
            Layer::LayerNorm {
                name: "layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Gemm {
                name: "qkv_projection".to_string(),
                m: self.hidden_size,
                n: (self.num_attention_heads + 2 * self.num_key_value_heads) * self.head_dim,
            },
            Layer::Attention {
                name: "attention".to_string(),
                num_q_heads: self.num_attention_heads,
                num_kv_heads: self.num_key_value_heads,
                head_dim: self.head_dim,
            },
            Layer::Gemm {
                name: "o_projection".to_string(),
                m: self.num_attention_heads * self.head_dim,
                n: self.hidden_size,
            },
        ]
    }

    fn build_mamba_block(&self) -> Vec<Layer> {
        vec![
            Layer::LayerNorm {
                name: "layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Mamba {
                name: "mamba".to_string(),
                num_heads: self.mamba_num_heads,
                head_dim: self.mamba_head_dim,
                state_size: self.ssm_state_size,
                conv_kernel_size: self.conv_kernel,
            },
        ]
    }

    fn build_dense_mlp_block(&self) -> Vec<Layer> {
        vec![
            Layer::LayerNorm {
                name: "layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Gemm {
                name: "ffn1".to_string(),
                m: self.hidden_size,
                n: self.intermediate_size,
            },
            Layer::Act {
                name: "act".to_string(),
                width: self.intermediate_size,
            },
            Layer::Gemm {
                name: "ffn2".to_string(),
                m: self.intermediate_size,
                n: self.hidden_size,
            },
        ]
    }

    fn build_moe_block(&self) -> Vec<Layer> {
        vec![
            Layer::LayerNorm {
                name: "layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Moe {
                name: "moe".to_string(),
                num_experts: self.n_routed_experts,
                num_experts_per_token: self.num_experts_per_tok,
                num_shared_experts_per_token: self.n_shared_experts,
                dispatch_bytes_per_token: self.moe_dispatch_bytes_per_token(),
                combine_bytes_per_token: self.moe_combine_bytes_per_token(),
            },
        ]
    }

    fn build_block_plan(&self, kind: HybridBlockKind) -> Vec<Layer> {
        match kind {
            HybridBlockKind::Mamba => self.build_mamba_block(),
            HybridBlockKind::Attention => self.build_attention_block(),
            HybridBlockKind::DenseMlp => self.build_dense_mlp_block(),
            HybridBlockKind::Moe => self.build_moe_block(),
        }
    }

    fn build_repeated_block_plan(block_plans: &[Vec<Layer>]) -> (Vec<Layer>, u32) {
        let Some(first) = block_plans.first() else {
            return (Vec::new(), 0);
        };

        if block_plans.iter().all(|plan| plan == first) {
            (first.clone(), block_plans.len() as u32)
        } else {
            let total_layers = block_plans.iter().map(Vec::len).sum();
            let mut flattened = Vec::with_capacity(total_layers);
            for plan in block_plans {
                flattened.extend(plan.iter().cloned());
            }
            (flattened, 1)
        }
    }

    fn build_post_block_layers(&self) -> Vec<Layer> {
        vec![
            Layer::LayerNorm {
                name: "final_layernorm".to_string(),
                hidden_size: self.hidden_size,
            },
            Layer::Gemm {
                name: "lm_head".to_string(),
                m: self.hidden_size,
                n: self.vocab_size,
            },
            Layer::Sampler {
                name: "sampler".to_string(),
                vocab_size: self.vocab_size,
            },
        ]
    }

    fn attention_weight_elems(&self) -> u64 {
        let qkv = self.hidden_size
            * (self.num_attention_heads + 2 * self.num_key_value_heads)
            * self.head_dim;
        let o_proj = (self.num_attention_heads * self.head_dim) * self.hidden_size;
        let layernorm = self.hidden_size;
        qkv + o_proj + layernorm
    }

    fn dense_mlp_weight_elems(&self) -> u64 {
        let layernorm = self.hidden_size;
        let up = self.hidden_size * self.intermediate_size;
        let down = self.intermediate_size * self.hidden_size;
        layernorm + up + down
    }

    fn moe_weight_elems(&self, ep_size: u32) -> u64 {
        let layernorm = self.hidden_size;
        let gate = self.hidden_size * self.n_routed_experts;
        let shared = if self.n_shared_experts > 0 {
            2 * self.hidden_size
                * (self.moe_shared_expert_intermediate_size * u64::from(self.n_shared_experts))
        } else {
            0
        };
        let local_experts = self.local_num_experts(ep_size);
        let experts = local_experts * 2 * self.hidden_size * self.moe_intermediate_size;
        layernorm + gate + shared + experts
    }

    fn mamba_weight_elems(&self) -> u64 {
        let layernorm = self.hidden_size;
        let mamba_hidden = self.mamba_intermediate_size();
        let conv_dim = self.mamba_conv_dim();
        let in_proj_out = mamba_hidden + conv_dim + self.mamba_num_heads;
        let in_proj = self.hidden_size * in_proj_out;
        let in_proj_bias = if self.use_bias { in_proj_out } else { 0 };
        let conv1d = self.conv_kernel * conv_dim;
        let conv1d_bias = if self.use_conv_bias { conv_dim } else { 0 };
        let recurrent = 3 * self.mamba_num_heads;
        let out_proj = mamba_hidden * self.hidden_size;
        let out_proj_bias = if self.use_bias { self.hidden_size } else { 0 };
        let norm = mamba_hidden;
        layernorm
            + in_proj
            + in_proj_bias
            + conv1d
            + conv1d_bias
            + recurrent
            + out_proj
            + out_proj_bias
            + norm
    }

    fn compute_weight_bytes_per_device(
        &self,
        block_kinds: &[HybridBlockKind],
        parallel: ParallelStrategy,
    ) -> u64 {
        let embed = self.vocab_size * self.hidden_size;
        let blocks = block_kinds
            .iter()
            .map(|kind| match kind {
                HybridBlockKind::Mamba => self.mamba_weight_elems(),
                HybridBlockKind::Attention => self.attention_weight_elems(),
                HybridBlockKind::DenseMlp => self.dense_mlp_weight_elems(),
                HybridBlockKind::Moe => self.moe_weight_elems(parallel.ep),
            })
            .sum::<u64>();
        let final_norm = self.hidden_size;
        let lm_head = self.hidden_size * self.vocab_size;
        FP_BYTES * (embed + blocks + final_norm + lm_head)
    }

    fn attention_kv_bytes_per_token(&self) -> u64 {
        2 * self.num_key_value_heads * self.head_dim * FP_BYTES
    }

    fn mamba_state_bytes_per_request(&self) -> u64 {
        let conv_state_elems = (self.conv_kernel - 1) * self.mamba_conv_dim();
        let temporal_state_elems = self.mamba_num_heads * self.mamba_head_dim * self.ssm_state_size;
        conv_state_elems * FP_BYTES + temporal_state_elems * self.mamba_ssm_state_dtype_bytes
    }

    fn compute_kv_bytes_per_token_per_device(&self, block_kinds: &[HybridBlockKind]) -> u64 {
        block_kinds
            .iter()
            .map(|kind| match kind {
                HybridBlockKind::Mamba => 0,
                HybridBlockKind::Attention => self.attention_kv_bytes_per_token(),
                HybridBlockKind::DenseMlp | HybridBlockKind::Moe => 0,
            })
            .sum()
    }

    fn compute_kv_bytes_per_request_per_device(&self, block_kinds: &[HybridBlockKind]) -> u64 {
        block_kinds
            .iter()
            .map(|kind| match kind {
                HybridBlockKind::Mamba => self.mamba_state_bytes_per_request(),
                HybridBlockKind::Attention | HybridBlockKind::DenseMlp | HybridBlockKind::Moe => 0,
            })
            .sum()
    }

    fn compute_scheduler_kv_bytes_per_token(&self, parallel: ParallelStrategy) -> u64 {
        self.kv_bytes_per_token_per_device
            .div_ceil(Self::scheduler_memory_divisor(parallel.ep))
    }

    fn validate(&self, parallel: ParallelStrategy) -> Result<()> {
        if parallel.tp != 1 {
            bail!("nemotron_h only supports tp_size=1");
        }
        if parallel.ep == 0 {
            bail!("ep_size must be positive");
        }
        if self.hidden_size == 0 {
            bail!("hidden_size must be positive");
        }
        if self.intermediate_size == 0 {
            bail!("intermediate_size must be positive");
        }
        if self.num_hidden_layers == 0 {
            bail!("num_hidden_layers must be positive");
        }
        if self.hybrid_override_pattern.len() != self.num_hidden_layers as usize {
            bail!("hybrid_override_pattern must match num_hidden_layers");
        }
        if self.num_attention_heads == 0 {
            bail!("num_attention_heads must be positive");
        }
        if self.head_dim == 0 {
            bail!("head_dim must be positive");
        }
        if self.num_key_value_heads == 0 {
            bail!("num_key_value_heads must be positive");
        }
        if self.vocab_size == 0 {
            bail!("vocab_size must be positive");
        }
        if self.mamba_num_heads == 0 {
            bail!("mamba_num_heads must be positive");
        }
        if self.mamba_head_dim == 0 {
            bail!("mamba_head_dim must be positive");
        }
        if self.n_groups == 0 {
            bail!("n_groups must be positive");
        }
        if self.ssm_state_size == 0 {
            bail!("ssm_state_size must be positive");
        }
        if self.conv_kernel == 0 {
            bail!("conv_kernel must be positive");
        }
        if self.n_routed_experts == 0 {
            bail!("n_routed_experts must be positive");
        }
        if self.num_experts_per_tok == 0 {
            bail!("num_experts_per_tok must be positive");
        }
        if self.num_experts_per_tok > self.n_routed_experts as u32 {
            bail!("num_experts_per_tok must not exceed n_routed_experts");
        }
        if self.moe_intermediate_size == 0 {
            bail!("moe_intermediate_size must be positive");
        }
        if self.mamba_ssm_state_dtype_bytes == 0 {
            bail!("mamba_ssm_state_dtype_bytes must be positive");
        }
        if !self.hidden_size.is_multiple_of(self.num_attention_heads) {
            bail!("hidden_size must be divisible by num_attention_heads");
        }
        if self.num_attention_heads < self.num_key_value_heads
            || !self
                .num_attention_heads
                .is_multiple_of(self.num_key_value_heads)
        {
            bail!("num_attention_heads must be divisible by num_key_value_heads");
        }
        if !self
            .mamba_intermediate_size()
            .is_multiple_of(self.mamba_num_heads)
        {
            bail!("mamba_num_heads must divide the mamba intermediate size");
        }

        for symbol in self.hybrid_override_pattern.chars() {
            let _ = Self::layer_kind(symbol)?;
        }

        Ok(())
    }
}

impl Model for NemotronHModel {
    fn init(&mut self, parallel: ParallelStrategy) -> Result<()> {
        self.validate(parallel)?;

        let block_kinds = self.block_kinds()?;
        self.pre_block_layers = self.build_pre_block_layers();
        let block_plans = block_kinds
            .iter()
            .map(|kind| self.build_block_plan(*kind))
            .collect::<Vec<_>>();
        (self.block_layers, self.block_count) = Self::build_repeated_block_plan(&block_plans);
        self.post_block_layers = self.build_post_block_layers();
        self.weight_bytes_per_device = self.compute_weight_bytes_per_device(&block_kinds, parallel);
        self.kv_bytes_per_token_per_device =
            self.compute_kv_bytes_per_token_per_device(&block_kinds);
        self.kv_bytes_per_request_per_device =
            self.compute_kv_bytes_per_request_per_device(&block_kinds);
        self.scheduler_kv_bytes_per_request = self
            .kv_bytes_per_request_per_device
            .div_ceil(Self::scheduler_memory_divisor(parallel.ep));
        self.scheduler_kv_bytes_per_token = self.compute_scheduler_kv_bytes_per_token(parallel);
        Ok(())
    }

    fn weight_bytes_per_device(&self) -> u64 {
        self.weight_bytes_per_device
    }

    fn kv_bytes_per_token_per_device(&self) -> u64 {
        self.kv_bytes_per_token_per_device
    }

    fn kv_bytes_per_request_per_device(&self) -> u64 {
        self.kv_bytes_per_request_per_device
    }

    fn scheduler_kv_bytes_per_token(&self) -> u64 {
        self.scheduler_kv_bytes_per_token
    }

    fn scheduler_kv_bytes_per_request(&self) -> u64 {
        self.scheduler_kv_bytes_per_request
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
        self.block_count
    }
}

#[cfg(test)]
mod tests {
    use super::NemotronHModel;
    use crate::model::Model;
    use crate::types::ParallelStrategy;

    fn base_model() -> NemotronHModel {
        NemotronHModel {
            hidden_size: 2688,
            intermediate_size: 1856,
            num_hidden_layers: 4,
            hybrid_override_pattern: "M*E-".to_string(),
            num_attention_heads: 32,
            head_dim: 128,
            num_key_value_heads: 2,
            vocab_size: 131072,
            mamba_num_heads: 64,
            mamba_head_dim: 64,
            n_groups: 8,
            ssm_state_size: 128,
            conv_kernel: 4,
            moe_intermediate_size: 1856,
            moe_shared_expert_intermediate_size: 3712,
            n_routed_experts: 128,
            n_shared_experts: 1,
            num_experts_per_tok: 6,
            use_bias: false,
            use_conv_bias: true,
            mamba_ssm_state_dtype_bytes: 4,
            pre_block_layers: Vec::new(),
            block_layers: Vec::new(),
            post_block_layers: Vec::new(),
            block_count: 0,
            weight_bytes_per_device: 0,
            kv_bytes_per_token_per_device: 0,
            kv_bytes_per_request_per_device: 0,
            scheduler_kv_bytes_per_request: 0,
            scheduler_kv_bytes_per_token: 0,
        }
    }

    #[test]
    fn hybrid_patterns_flatten_to_single_block_plan_when_mixed() {
        let mut model = base_model();
        model
            .init(ParallelStrategy {
                tp: 1,
                pp: 1,
                ep: 2,
            })
            .expect("nemotron_h init should succeed");

        assert_eq!(model.num_blocks(), 1);
        assert!(model
            .block_layers()
            .iter()
            .any(|layer| layer.name() == "mamba"));
        assert!(model
            .block_layers()
            .iter()
            .any(|layer| layer.name() == "attention"));
        assert!(model
            .block_layers()
            .iter()
            .any(|layer| layer.name() == "moe"));
        assert!(model
            .block_layers()
            .iter()
            .any(|layer| layer.name() == "ffn1"));
    }
}
