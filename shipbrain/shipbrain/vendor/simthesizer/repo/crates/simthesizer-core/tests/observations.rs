use std::any::Any;

use anyhow::Result;
use serde::Deserialize;
use serde_json::{json, Value};
use simthesizer_core::types::{NodeID, ParallelStrategy, Request, RequestResult, RequestState};
use simthesizer_core::{Engine, Graph, LogicalHandler, Model, ModelRunner, Module, System};

#[derive(Deserialize)]
struct StepRunner {
    ep: u32,
    duration: f64,
}

simthesizer_core::register_model_runner!(StepRunner, "test_step");

impl Module for StepRunner {}
impl LogicalHandler for StepRunner {
    fn handle(&mut self, _: Box<dyn Any>, _: f64, _: NodeID, _: &mut Graph) -> Result<f64> {
        Ok(self.duration)
    }
}
impl ModelRunner for StepRunner {
    fn parallel_strategy(&self) -> ParallelStrategy {
        ParallelStrategy {
            tp: 1,
            pp: 1,
            ep: self.ep,
        }
    }

    fn add_iteration(
        &mut self,
        _: &dyn Model,
        _: &[RequestState],
        current: NodeID,
        graph: &mut Graph,
    ) -> Result<NodeID> {
        let node = graph.add_logical_node(self as *mut Self as *mut dyn LogicalHandler, ());
        graph.add_edge(current, node)?;
        Ok(node)
    }
}

fn model() -> Value {
    json!({"kind":"llama3_1", "hidden_size":32, "intermediate_size":64,
        "max_position_embeddings":256, "num_attention_heads":4, "num_hidden_layers":1,
        "num_key_value_heads":2, "vocab_size":256})
}

fn scheduler() -> Value {
    json!({"kind":"chunked_prefill", "block_size":4, "max_batch":1,
        "max_num_batched_tokens":8, "device_mem":1048576,
        "device_mem_utilization":1.0, "enable_prefix_caching":true})
}

fn single() -> Value {
    json!({"kind":"single_instance", "model":model(), "scheduler":scheduler(),
        "model_runner":{"kind":"test_step", "ep":1, "duration":1.0}})
}

fn ep() -> Value {
    json!({"kind":"moe_ep_multi_instance", "model":model(),
        "schedulers":[scheduler(),scheduler()],
        "model_runner":{"kind":"test_step", "ep":2, "duration":1.0}})
}

fn request(id: u64, arrival: f64, output: u32) -> Request {
    serde_json::from_value(
        json!({"request_id":id, "arrival_time":arrival, "initial":[0],
        "sub_requests":[{"kind":"llm", "input_tokens":4, "output_tokens":output, "next":[]}]}),
    )
    .unwrap()
}

fn run(
    config: Value,
    requests: &[Request],
    observed: bool,
) -> (Vec<RequestResult>, Vec<(f64, Value)>) {
    let mut system: Box<dyn System> = serde_json::from_value(config).unwrap();
    system.init().unwrap();
    let mut graph = Graph::new();
    for request in requests {
        request.validate().unwrap();
        system
            .add_request_arrival(request.clone(), &mut graph, None, None)
            .unwrap();
    }
    let mut frames = Vec::new();
    let engine = Engine::new(graph, system);
    let result = if observed {
        engine.run_with_observer(|time, system| {
            frames.push((time, system.observe()));
            Ok(())
        })
    } else {
        engine.run()
    }
    .unwrap();
    (result, frames)
}

fn state(running: u64, waiting: u64, tokens: u64) -> Value {
    json!({"running_requests":running,"waiting_requests":waiting,"generation_tokens_total":tokens})
}

#[test]
fn observations_preserve_results_and_distinguish_admission_from_emission() {
    let requests = [request(0, 0.0, 2), request(1, 0.0, 1)];
    let (off, _) = run(single(), &requests, false);
    let (on, frames) = run(single(), &requests, true);
    assert_eq!(
        serde_json::to_value(off).unwrap(),
        serde_json::to_value(on).unwrap()
    );
    let actual: Vec<_> = frames
        .into_iter()
        .map(|(t, s)| (t, s["scheduler"].clone()))
        .collect();
    assert_eq!(
        actual,
        vec![
            (0.0, state(1, 1, 0)),
            (1.0, state(1, 1, 1)),
            (2.0, state(1, 0, 2)),
            (3.0, state(0, 0, 3))
        ]
    );
}

#[test]
fn observes_only_after_all_same_time_descendants() {
    let mut config = single();
    config["model_runner"]["duration"] = json!(0.0);
    let (_, frames) = run(config, &[request(0, 0.0, 2), request(1, 0.0, 1)], true);
    assert_eq!(frames, vec![(0.0, json!({"scheduler":state(0,0,3)}))]);
}

#[test]
fn preserves_ep_and_nested_instance_identity_including_idle_instances() {
    let config = json!({"kind":"multi_instance", "instances":[single(),ep()]});
    let requests = [request(0, 1.0, 2), request(1, 1.0, 3), request(2, 1.0, 1)];
    let (off, _) = run(config.clone(), &requests, false);
    let (on, frames) = run(config.clone(), &requests, true);
    assert_eq!(
        serde_json::to_value(off).unwrap(),
        serde_json::to_value(on).unwrap()
    );
    assert!(frames.windows(2).all(|w| w[0].0 < w[1].0));
    assert_eq!(frames[0].0, 0.0);
    for (_, frame) in &frames {
        assert_eq!(
            frame.pointer("/instances/1/schedulers/1").unwrap(),
            &state(0, 0, 0)
        );
    }
    let last = &frames.last().unwrap().1;
    assert_eq!(
        last.pointer("/instances/0/scheduler").unwrap(),
        &state(0, 0, 3)
    );
    assert_eq!(
        last.pointer("/instances/1/schedulers/0").unwrap(),
        &state(0, 0, 3)
    );
    let (_, empty) = run(config, &[], true);
    assert_eq!(empty.len(), 1);
    assert_eq!(empty[0].0, 0.0);
}

#[test]
fn pd_handoff_retains_each_pools_own_emissions() {
    let config = json!({"kind":"pd_disaggregation", "tp":1, "model":model(),
        "prefill_instances":[single()], "decode_instances":[single()],
        "network_sim":{"kind":"flow"}, "link_bw":128.0, "link_latency":0.0});
    let requests = [request(0, 0.0, 3)];
    let (off, _) = run(config.clone(), &requests, false);
    let (on, frames) = run(config, &requests, true);
    assert_eq!(
        serde_json::to_value(off).unwrap(),
        serde_json::to_value(on).unwrap()
    );
    let last = &frames.last().unwrap().1;
    assert_eq!(
        last.pointer("/prefill_instances/0/scheduler").unwrap(),
        &state(0, 0, 1)
    );
    assert_eq!(
        last.pointer("/decode_instances/0/scheduler").unwrap(),
        &state(0, 0, 2)
    );
    assert!(frames.iter().any(|(t, s)| *t >= 1.0
        && s.pointer("/prefill_instances/0/scheduler").unwrap() == &state(0, 0, 1)
        && s.pointer("/decode_instances/0/scheduler").unwrap() == &state(0, 0, 0)));
}

#[test]
fn native_observation_supports_request_dags_and_tool_intervals() {
    let request = serde_json::from_value(json!({"request_id":0,"arrival_time":0.0,"initial":[0],
    "sub_requests":[
        {"kind":"llm","input_tokens":4,"output_tokens":1,"next":[1]},
            {"kind":"tool_call","input_tokens":0,"output_tokens":0,"duration":2.0,"next":[2]},
        {"kind":"llm","input_tokens":4,"output_tokens":1,"next":[],"interval":1.0}
    ]}))
    .unwrap();
    let requests = [request];
    let (off, _) = run(single(), &requests, false);
    let (on, frames) = run(single(), &requests, true);
    assert_eq!(
        serde_json::to_value(off).unwrap(),
        serde_json::to_value(on).unwrap()
    );
    assert_eq!(frames.last().unwrap().0, 5.0);
    assert_eq!(frames.last().unwrap().1["scheduler"], state(0, 0, 2));
}
