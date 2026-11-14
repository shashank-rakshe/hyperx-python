#![allow(dead_code)]

use std::any::Any;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use anyhow::Result;
use serde::Deserialize;
use serde_json::{json, Value};
use simthesizer_core::types::{
    ComputeContext, Layer, NodeID, ParallelStrategy, Request, RequestResult, RequestState,
};
use simthesizer_core::{ComputeSimulator, Graph, LogicalHandler, Model, Module, System};

thread_local! {
    static TRANSFERS: RefCell<Vec<(u64,u64,u64)>> = const { RefCell::new(Vec::new()) };
}

pub fn take_transfers() -> Vec<(u64, u64, u64)> {
    TRANSFERS.with(|calls| std::mem::take(&mut *calls.borrow_mut()))
}

#[derive(Deserialize)]
pub struct RecordingNetwork {
    #[serde(skip)]
    flow: simthesizer_core::network_sims::flow::FlowNetworkSimulator,
}
simthesizer_core::register_network_simulator!(RecordingNetwork, "test_recording_network");
impl Module for RecordingNetwork {}
impl simthesizer_core::NetworkSimulator for RecordingNetwork {
    fn add_device(&mut self) -> u64 {
        self.flow.add_device()
    }
    fn add_link(&mut self, src: u64, dst: u64, bandwidth: f64, latency: f64) -> Result<()> {
        self.flow.add_link(src, dst, bandwidth, latency)
    }
    fn simulate(
        &mut self,
        src: u64,
        dst: u64,
        bytes: u64,
        now: f64,
        state: &mut Option<Box<dyn Any>>,
    ) -> Result<simthesizer_core::types::PollResult> {
        if state.is_none() {
            TRANSFERS.with(|calls| calls.borrow_mut().push((src, dst, bytes)));
        }
        self.flow.simulate(src, dst, bytes, now, state)
    }
}

pub fn close(actual: f64, expected: f64) {
    assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
}

pub type Events = Rc<RefCell<Vec<(String, f64)>>>;

#[derive(Default)]
pub struct Recorder {
    pub events: Events,
}

impl Module for Recorder {}
impl LogicalHandler for Recorder {
    fn handle(&mut self, payload: Box<dyn Any>, now: f64, _: NodeID, _: &mut Graph) -> Result<f64> {
        let (label, duration) = *payload.downcast::<(String, f64)>().unwrap();
        self.events.borrow_mut().push((label, now));
        Ok(duration)
    }
}
impl System for Recorder {
    fn instance_load(&self) -> simthesizer_core::types::InstanceLoad {
        Default::default()
    }
    fn init(&mut self) -> Result<()> {
        Ok(())
    }
    fn add_request_arrival(
        &mut self,
        _: Request,
        _: &mut Graph,
        _: Option<NodeID>,
        _: Option<*mut dyn LogicalHandler>,
    ) -> Result<()> {
        unreachable!()
    }
    fn into_results(self: Box<Self>) -> Result<Vec<RequestResult>> {
        Ok(Vec::new())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComputeCall {
    pub layer: Layer,
    pub batch: Vec<RequestState>,
    pub context: ComputeContext,
}

thread_local! {
    static CALLS: RefCell<Vec<ComputeCall>> = const { RefCell::new(Vec::new()) };
}

pub fn take_compute_calls() -> Vec<ComputeCall> {
    CALLS.with(|calls| std::mem::take(&mut *calls.borrow_mut()))
}

#[derive(Deserialize)]
pub struct FixedCompute {
    #[serde(default)]
    pub costs: BTreeMap<String, f64>,
    #[serde(default)]
    pub per_token: bool,
}

simthesizer_core::register_compute_simulator!(FixedCompute, "test_fixed_compute");
impl Module for FixedCompute {}
impl ComputeSimulator for FixedCompute {
    fn init(&mut self, _: ParallelStrategy) -> Result<()> {
        Ok(())
    }
    fn simulate(
        &self,
        layer: &Layer,
        batch: &[RequestState],
        context: ComputeContext,
    ) -> Result<f64> {
        CALLS.with(|calls| {
            calls.borrow_mut().push(ComputeCall {
                layer: layer.clone(),
                batch: batch.to_vec(),
                context,
            })
        });
        let cost = self.costs.get(layer.name()).copied().unwrap_or(0.0);
        Ok(cost
            * if self.per_token {
                batch.iter().map(|r| f64::from(r.q_len)).sum()
            } else {
                1.0
            })
    }
}

pub struct ToyModel {
    pub pre: Vec<Layer>,
    pub block: Vec<Layer>,
    pub post: Vec<Layer>,
    pub blocks: u32,
}
impl Module for ToyModel {}
impl Model for ToyModel {
    fn init(&mut self, _: ParallelStrategy) -> Result<()> {
        Ok(())
    }
    fn weight_bytes_per_device(&self) -> u64 {
        0
    }
    fn kv_bytes_per_token_per_device(&self) -> u64 {
        0
    }
    fn pre_block_layers(&self) -> &[Layer] {
        &self.pre
    }
    fn block_layers(&self) -> &[Layer] {
        &self.block
    }
    fn post_block_layers(&self) -> &[Layer] {
        &self.post
    }
    fn num_blocks(&self) -> u32 {
        self.blocks
    }
}

pub fn norm(name: &str) -> Layer {
    Layer::LayerNorm {
        name: name.into(),
        hidden_size: 4,
    }
}

pub fn batch(tokens: u32) -> Vec<RequestState> {
    vec![RequestState {
        q_len: tokens,
        kv_len: 0,
        lm_head_len: 1,
    }]
}

pub fn model() -> Value {
    json!({"kind":"llama3_1", "hidden_size":32, "intermediate_size":64,
        "max_position_embeddings":256, "num_attention_heads":4, "num_hidden_layers":1,
        "num_key_value_heads":2, "vocab_size":256})
}

pub fn single() -> Value {
    json!({"kind":"single_instance", "model":model(),
        "scheduler":{"kind":"chunked_prefill", "block_size":4, "max_batch":1,
            "max_num_batched_tokens":8, "device_mem":1048576,
            "device_mem_utilization":1.0, "enable_prefix_caching":false},
        "model_runner":{"kind":"ring", "tp":1, "link_bw":128.0, "link_latency":0.0,
            "network_sim":{"kind":"flow"},
            "compute_sim":{"kind":"test_fixed_compute", "costs":{"attention":1.0}}}})
}

pub fn request(id: u64, arrival: f64, output: u32) -> Request {
    serde_json::from_value(
        json!({"request_id":id, "arrival_time":arrival, "initial":[0],
        "sub_requests":[{"kind":"llm", "input_tokens":4, "output_tokens":output, "next":[]}]}),
    )
    .unwrap()
}

pub fn run_system(config: Value, requests: &[Request]) -> Result<(Vec<RequestResult>, f64)> {
    let mut system: Box<dyn System> = serde_json::from_value(config)?;
    system.init()?;
    let mut graph = Graph::new();
    for request in requests {
        system.add_request_arrival(request.clone(), &mut graph, None, None)?;
    }
    let mut end = 0.0;
    let results = simthesizer_core::Engine::new(graph, system).run_with_observer(|time, _| {
        end = time;
        Ok(())
    })?;
    Ok((results, end))
}
