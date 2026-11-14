use serde_json::{json, Value};
use simthesizer_core::types::{Layer, ParallelStrategy};
use simthesizer_core::Model;

#[test]
fn ep_scheduler_reserves_full_resident_weights_before_request_state() {
    use simthesizer_core::types::ReadySubRequest;
    use simthesizer_core::Scheduler;
    for (config, weights, request_bytes) in [(qwen(), 3056, 64), (nemotron(), 2572, 108)] {
        let model = build(config, 2);
        assert_eq!(model.scheduler_model_weight_bytes(), weights);
        for (capacity, fits) in [(weights + request_bytes, true), (weights - 1, false)] {
            let mut scheduler: Box<dyn Scheduler> = serde_json::from_value(json!({
                "kind":"chunked_prefill","block_size":4,"max_batch":2,"max_num_batched_tokens":8,
                "device_mem":capacity,"device_mem_utilization":1.0,"enable_prefix_caching":false
            }))
            .unwrap();
            scheduler
                .init(
                    model.scheduler_model_weight_bytes(),
                    model.scheduler_kv_bytes_per_request(),
                    model.scheduler_kv_bytes_per_token(),
                    ParallelStrategy {
                        tp: 1,
                        pp: 1,
                        ep: 2,
                    },
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
            if fits {
                assert_eq!(scheduler.schedule().unwrap().len(), 1);
                assert_eq!(scheduler.done_iteration(1.0).len(), 1);
                assert_eq!(scheduler.schedule().unwrap().len(), 1);
                assert_eq!(scheduler.done_iteration(2.0).len(), 1);
                assert!(scheduler.schedule().unwrap().is_empty());
            } else {
                assert!(scheduler.schedule().is_err());
            }
        }
    }
}

fn build(config: Value, ep: u32) -> Box<dyn Model> {
    let mut model: Box<dyn Model> = serde_json::from_value(config).unwrap();
    model.init(ParallelStrategy { tp: 1, pp: 1, ep }).unwrap();
    model
}

fn qwen() -> Value {
    json!({"kind":"qwen3_moe","hidden_size":8,"intermediate_size":12,
        "moe_intermediate_size":6,"num_attention_heads":2,"num_key_value_heads":1,
        "num_hidden_layers":2,"num_experts":3,"num_experts_per_tok":2,
        "vocab_size":16,"decoder_sparse_step":1,"shared_expert_intermediate_size":4})
}

fn nemotron() -> Value {
    json!({"kind":"nemotron_h","hidden_size":8,"intermediate_size":12,
        "num_hidden_layers":4,"hybrid_override_pattern":"M*-E",
        "num_attention_heads":2,"head_dim":4,"num_key_value_heads":1,"vocab_size":16,
        "mamba_num_heads":2,"mamba_head_dim":4,"n_groups":1,"ssm_state_size":3,"conv_kernel":3,
        "moe_intermediate_size":6,"moe_shared_expert_intermediate_size":4,
        "n_routed_experts":3,"n_shared_experts":1,"num_experts_per_tok":2})
}

#[test]
fn qwen_weight_counts_include_replicated_dense_and_uneven_expert_shards() {
    // 264 global elements, 216 attention/norm elements per block,
    // 128 gate/shared elements, and 144 elements per resident expert. BF16.
    for (ep, bytes) in [(1, 3632), (2, 3056), (4, 2480)] {
        let model = build(qwen(), ep);
        assert_eq!(model.weight_bytes_per_device(), bytes, "EP={ep}");
        assert_eq!(model.kv_bytes_per_token_per_device(), 32);
        assert_eq!(model.kv_bytes_per_request_per_device(), 0);
        assert_eq!(model.num_blocks(), 2);
        assert!(model.block_layers().iter().any(|l| matches!(
            l,
            Layer::Moe {
                num_experts: 3,
                num_experts_per_token: 2,
                num_shared_experts_per_token: 1,
                dispatch_bytes_per_token: 22,
                combine_bytes_per_token: 16,
                ..
            }
        )));
    }
}

#[test]
fn mixed_qwen_layers_preserve_order_and_memory() {
    let mut config = qwen();
    config["decoder_sparse_step"] = json!(2);
    let model = build(config, 1);
    assert_eq!(model.num_blocks(), 1);
    assert_eq!(model.weight_bytes_per_device(), 3088);
    let names: Vec<_> = model
        .block_layers()
        .iter()
        .map(Layer::name)
        .filter(|n| matches!(*n, "attention" | "ffn1" | "moe"))
        .collect();
    assert_eq!(names, ["attention", "ffn1", "attention", "moe"]);
}

#[test]
fn qwen_explicit_head_dimension_controls_projection_and_kv_size() {
    let mut config = qwen();
    config["head_dim"] = json!(6);
    let model = build(config, 1);
    assert_eq!(model.kv_bytes_per_token_per_device(), 48);
    assert!(model
        .block_layers()
        .iter()
        .any(|l| matches!(l,Layer::Gemm { name,m:8,n:24 } if name == "qkv_projection")));
    assert!(model
        .block_layers()
        .iter()
        .any(|l| matches!(l,Layer::Gemm { name,m:12,n:8 } if name == "o_projection")));
}

#[test]
fn hybrid_memory_separates_fixed_recurrent_state_from_token_kv() {
    let model = build(nemotron(), 2);
    // BF16 elements: global 264, Mamba 334, attention 200, MLP 200, MoE 288.
    assert_eq!(model.weight_bytes_per_device(), 2572);
    assert_eq!(model.kv_bytes_per_token_per_device(), 16);
    // Conv: 2 timesteps * 14 channels * 2 bytes. SSM: 2 * 4 * 3 * 4 bytes.
    assert_eq!(model.kv_bytes_per_request_per_device(), 152);
    let mut config = nemotron();
    config["mamba_ssm_state_dtype_bytes"] = json!(2);
    let half_state = build(config, 2);
    assert_eq!(half_state.kv_bytes_per_request_per_device(), 104);
    assert_eq!(half_state.kv_bytes_per_token_per_device(), 16);
    assert_eq!(half_state.weight_bytes_per_device(), 2572);
}

#[test]
fn uniform_recurrent_blocks_repeat_without_token_kv() {
    let mut config = nemotron();
    config["hybrid_override_pattern"] = json!("MMMM");
    let model = build(config, 1);
    assert_eq!(model.num_blocks(), 4);
    assert_eq!(
        model
            .block_layers()
            .iter()
            .map(Layer::name)
            .collect::<Vec<_>>(),
        ["layernorm", "mamba"]
    );
    assert_eq!(model.weight_bytes_per_device(), 3200);
    assert_eq!(model.kv_bytes_per_request_per_device(), 608);
    assert_eq!(model.kv_bytes_per_token_per_device(), 0);
}

#[test]
fn invalid_model_configurations_fail_before_execution() {
    for (base, key, value) in [
        (qwen(), "decoder_sparse_step", json!(0)),
        (qwen(), "num_experts_per_tok", json!(4)),
        (qwen(), "mlp_only_layers", json!([2])),
        (nemotron(), "conv_kernel", json!(0)),
        (nemotron(), "hybrid_override_pattern", json!("M*?E")),
        (nemotron(), "hybrid_override_pattern", json!("MM")),
    ] {
        let mut config = base;
        config[key] = value;
        let mut model: Box<dyn Model> = serde_json::from_value(config).unwrap();
        assert!(
            model
                .init(ParallelStrategy {
                    tp: 1,
                    pp: 1,
                    ep: 1
                })
                .is_err(),
            "{key}"
        );
    }
}
