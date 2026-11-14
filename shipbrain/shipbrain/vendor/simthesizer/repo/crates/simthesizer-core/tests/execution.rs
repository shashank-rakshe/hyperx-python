mod common;

use common::{batch, close, norm, take_compute_calls, take_transfers, Recorder, ToyModel};
use serde_json::json;
use simthesizer_core::types::Layer;
use simthesizer_core::{Engine, Graph, LogicalHandler, ModelRunner};

fn execute(
    model: &ToyModel,
    kind: &str,
    width: u32,
    batches: &[Vec<simthesizer_core::types::RequestState>],
    multi: bool,
) -> f64 {
    take_compute_calls();
    take_transfers();
    let mut config = json!({"kind":kind, "link_bw":1.0, "link_latency":0.0,
        "compute_sim":{"kind":"test_fixed_compute", "per_token":true,
            "costs":{"pre":0.5,"block":1.0,"post":1.5,"moe":1.0}},
        "network_sim":{"kind":"test_recording_network"}});
    config[if kind == "ring" { "tp" } else { "ep" }] = json!(width);
    let mut runner: Box<dyn ModelRunner> = serde_json::from_value(config).unwrap();
    runner.init(model).unwrap();
    let mut recorder = Box::<Recorder>::default();
    let mut graph = Graph::new();
    let ptr = recorder.as_mut() as *mut dyn LogicalHandler;
    let start = graph.add_logical_node(ptr, ("start".to_string(), 0.0));
    let done = if multi {
        runner.add_multi_iteration(model, batches, start, &mut graph)
    } else {
        runner.add_iteration(model, &batches[0], start, &mut graph)
    }
    .unwrap();
    let end = graph.add_logical_node(ptr, ("end".to_string(), 0.0));
    graph.add_edge(done, end).unwrap();
    let events = recorder.events.clone();
    Engine::new(graph, recorder).run().unwrap();
    let time = events.borrow().last().unwrap().1;
    time
}

fn moe(experts: u64, top_k: u32, shared: u32, bytes: u64) -> Layer {
    Layer::Moe {
        name: "moe".into(),
        num_experts: experts,
        num_experts_per_token: top_k,
        num_shared_experts_per_token: shared,
        dispatch_bytes_per_token: bytes,
        combine_bytes_per_token: bytes,
    }
}

#[test]
fn ring_time_matches_two_collective_phases_and_repeated_blocks() {
    let model = ToyModel {
        pre: vec![norm("pre")],
        block: vec![
            norm("block"),
            Layer::AllReduce {
                name: "reduce".into(),
                bytes_per_token: 4,
            },
        ],
        post: vec![norm("post")],
        blocks: 3,
    };
    // Eight payload bytes; each directed ring edge has independent 1 byte/s capacity.
    for (tp, expected) in [(1, 10.0), (2, 34.0), (4, 46.0)] {
        close(execute(&model, "ring", tp, &[batch(2)], false), expected);
        assert_eq!(
            take_compute_calls()
                .iter()
                .map(|c| c.layer.name())
                .collect::<Vec<_>>(),
            ["pre", "block", "post"]
        );
    }
}

#[test]
fn zero_payload_collective_has_no_cost() {
    let model = ToyModel {
        pre: vec![],
        block: vec![Layer::AllReduce {
            name: "reduce".into(),
            bytes_per_token: 0,
        }],
        post: vec![],
        blocks: 4,
    };
    close(execute(&model, "ring", 4, &[batch(2)], false), 0.0);
    assert!(take_compute_calls().is_empty());
}

#[test]
fn moe_all_experts_selected_has_exact_dispatch_compute_combine_time() {
    let model = ToyModel {
        pre: vec![],
        block: vec![moe(2, 2, 0, 1)],
        post: vec![],
        blocks: 1,
    };
    // Dispatch 3 s, four tokens on each rank in parallel 4 s, combine 3 s.
    close(
        execute(&model, "moe_ep", 2, &[batch(3), batch(1)], true),
        10.0,
    );
    let calls = take_compute_calls();
    assert_eq!(calls.len(), 2);
    for call in calls {
        assert_eq!(call.batch[0].q_len, 4);
        assert_eq!(call.context.moe_activated_experts, Some(1));
    }
}

#[test]
fn shared_experts_keep_tokens_at_the_source_rank() {
    let model = ToyModel {
        pre: vec![],
        block: vec![moe(0, 0, 2, 1)],
        post: vec![],
        blocks: 1,
    };
    close(
        execute(&model, "moe_ep", 2, &[batch(3), batch(1)], true),
        3.0,
    );
    let calls = take_compute_calls();
    assert_eq!(
        calls.iter().map(|c| c.batch[0].q_len).collect::<Vec<_>>(),
        [3, 1]
    );
    assert!(calls
        .iter()
        .all(|c| c.context.moe_activated_experts == Some(2)));
    assert!(take_transfers().is_empty());
}

#[test]
fn local_experts_need_no_network_and_remote_results_return_to_the_source() {
    let model = ToyModel {
        pre: vec![],
        block: vec![moe(1, 1, 0, 1)],
        post: vec![],
        blocks: 1,
    };
    close(
        execute(
            &model,
            "moe_ep",
            4,
            &[batch(3), vec![], vec![], vec![]],
            true,
        ),
        3.0,
    );
    assert!(take_transfers().is_empty());
    close(
        execute(
            &model,
            "moe_ep",
            4,
            &[vec![], batch(3), vec![], vec![]],
            true,
        ),
        9.0,
    );
    assert_eq!(take_transfers(), [(1, 0, 3), (0, 1, 3)]);
}

#[test]
fn single_scheduler_dispatch_uses_source_partition_and_expert_destinations() {
    let model = ToyModel {
        pre: vec![],
        block: vec![moe(1, 1, 0, 1)],
        post: vec![],
        blocks: 1,
    };
    // Five tokens split 2/1/1/1. Only ranks 1,2,3 send to the sole expert on rank 0.
    close(execute(&model, "moe_ep", 4, &[batch(5)], false), 7.0);
    let mut transfers = take_transfers();
    transfers.sort_unstable();
    assert_eq!(
        transfers,
        [
            (0, 1, 1),
            (0, 2, 1),
            (0, 3, 1),
            (1, 0, 1),
            (2, 0, 1),
            (3, 0, 1)
        ]
    );
}

#[test]
fn multiple_experts_on_one_rank_share_each_token_payload() {
    let model = ToyModel {
        pre: vec![],
        block: vec![moe(4, 4, 0, 1)],
        post: vec![],
        blocks: 1,
    };
    close(
        execute(&model, "moe_ep", 2, &[batch(3), batch(1)], true),
        10.0,
    );
    assert_eq!(
        take_transfers(),
        [(0, 1, 3), (1, 0, 1), (0, 1, 1), (1, 0, 3)]
    );
    for call in take_compute_calls() {
        assert_eq!(call.batch[0].q_len, 4);
        assert_eq!(call.context.moe_activated_experts, Some(2));
    }
}

#[test]
fn idle_ep_rank_skips_dense_compute() {
    let model = ToyModel {
        pre: vec![norm("pre")],
        block: vec![norm("block")],
        post: vec![norm("post")],
        blocks: 2,
    };
    close(
        execute(&model, "moe_ep", 2, &[batch(3), vec![]], true),
        12.0,
    );
    assert_eq!(take_compute_calls().len(), 3);
}

#[test]
fn sampled_expert_routing_is_reproducible_and_conserves_assignments() {
    let model = ToyModel {
        pre: vec![],
        block: vec![moe(4, 1, 0, 0)],
        post: vec![],
        blocks: 1,
    };
    let first_time = execute(&model, "moe_ep", 4, &[batch(17)], false);
    let first = take_compute_calls();
    close(
        execute(&model, "moe_ep", 4, &[batch(17)], false),
        first_time,
    );
    assert_eq!(first, take_compute_calls());
    assert_eq!(first.iter().map(|c| c.batch[0].q_len).sum::<u32>(), 17);
    assert!(first
        .iter()
        .all(|c| c.context.moe_activated_experts == Some(1)));
}

#[test]
fn invalid_parallel_width_and_expert_selection_are_rejected_at_init() {
    for (kind, width, layer) in [
        ("ring", 0, norm("block")),
        ("moe_ep", 0, norm("block")),
        ("moe_ep", 2, moe(1, 2, 0, 1)),
        ("moe_ep", 2, moe(0, 1, 0, 1)),
    ] {
        let mut config = json!({"kind":kind,"link_bw":1.0,"link_latency":0.0,
            "compute_sim":{"kind":"test_fixed_compute"},"network_sim":{"kind":"flow"}});
        config[if kind == "ring" { "tp" } else { "ep" }] = json!(width);
        let mut runner: Box<dyn ModelRunner> = serde_json::from_value(config).unwrap();
        let model = ToyModel {
            pre: vec![],
            block: vec![layer],
            post: vec![],
            blocks: 1,
        };
        assert!(runner.init(&model).is_err(), "{kind} width={width}");
    }
}
