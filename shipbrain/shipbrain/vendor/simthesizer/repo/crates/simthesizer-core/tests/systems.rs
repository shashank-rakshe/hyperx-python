mod common;

use common::{close, model, request, run_system, single};
use serde_json::{json, Value};
use simthesizer_core::types::{Request, RequestResult, ResultSubRequest, SubRequest};
use simthesizer_core::{Graph, System};

fn latencies(results: &[RequestResult], id: u64, index: usize) -> &[f64] {
    match &results
        .iter()
        .find(|r| r.request_id == id)
        .unwrap()
        .sub_requests[index]
    {
        ResultSubRequest::Llm { token_latency, .. } => token_latency,
        _ => panic!("expected LLM result"),
    }
}

fn ep() -> Value {
    let child = single();
    let mut runner = child["model_runner"].clone();
    runner["kind"] = json!("moe_ep");
    runner.as_object_mut().unwrap().remove("tp");
    runner["ep"] = json!(2);
    json!({"kind":"moe_ep_multi_instance","model":model(),"schedulers":[child["scheduler"],child["scheduler"]],"model_runner":runner})
}

fn pd() -> Value {
    json!({"kind":"pd_disaggregation","tp":1,"model":model(),"prefill_instances":[single()],
        "decode_instances":[single()],"network_sim":{"kind":"flow"},"link_bw":128.0,"link_latency":0.25})
}

#[test]
fn dag_fan_in_waits_for_the_slowest_tool_and_then_the_interval() {
    let request: Request = serde_json::from_value(
        json!({"request_id":0,"arrival_time":0.0,"initial":[0],"sub_requests":[
            {"kind":"tool_call","input_tokens":0,"output_tokens":0,"duration":1.0,"next":[1,2]},
            {"kind":"tool_call","input_tokens":0,"output_tokens":0,"duration":2.0,"next":[3]},
            {"kind":"tool_call","input_tokens":0,"output_tokens":0,"duration":5.0,"next":[3]},
            {"kind":"llm","input_tokens":4,"output_tokens":1,"interval":1.0,"next":[]}
        ]}),
    )
    .unwrap();
    for config in [single(), ep()] {
        let (result, end) = run_system(config, std::slice::from_ref(&request)).unwrap();
        close(end, 8.0);
        assert_eq!(latencies(&result, 0, 3), &[1.0]);
    }
}

#[test]
fn queueing_and_decode_costs_are_reflected_in_each_requests_latency() {
    let (result, end) = run_system(single(), &[request(0, 0.0, 2), request(1, 0.5, 1)]).unwrap();
    close(end, 3.0);
    assert_eq!(latencies(&result, 0, 0), &[1.0, 1.0]);
    assert_eq!(latencies(&result, 1, 0), &[2.5]);
}

#[test]
fn simultaneous_requests_share_one_iteration_when_batch_capacity_allows() {
    let mut config = single();
    config["scheduler"]["max_batch"] = json!(2);
    let (result, end) = run_system(config, &[request(0, 0.0, 2), request(1, 0.0, 2)]).unwrap();
    close(end, 2.0);
    for id in 0..2 {
        assert_eq!(latencies(&result, id, 0), &[1.0, 1.0]);
    }
}

#[test]
fn independent_instances_and_ep_ranks_make_progress_in_parallel() {
    for config in [
        json!({"kind":"multi_instance","instances":[single(),single()]}),
        ep(),
    ] {
        let (result, end) = run_system(config, &[request(0, 0.0, 3), request(1, 0.0, 1)]).unwrap();
        close(end, 3.0);
        assert_eq!(latencies(&result, 0, 0), &[1.0, 1.0, 1.0]);
        assert_eq!(latencies(&result, 1, 0), &[1.0]);
    }
}

fn load_balanced_systems() -> Vec<Value> {
    let mut expert = ep();
    expert["router"] = json!({"kind":"moe_load_balancing"});
    let multi = json!({"kind":"multi_instance","instances":[single(),single()],
        "router":{"kind":"moe_load_balancing"}});
    let nested = json!({"kind":"multi_instance","instances":[
        {"kind":"multi_instance","instances":[single()]},
        {"kind":"multi_instance","instances":[single()]}],
        "router":{"kind":"moe_load_balancing"}});
    vec![multi, expert, nested]
}

#[test]
fn routing_uses_load_at_arrival_instead_of_workload_file_order() {
    for (index, config) in load_balanced_systems().into_iter().enumerate() {
        for requests in [
            vec![request(0, 0.0, 6), request(1, 0.0, 1), request(2, 2.5, 1)],
            vec![request(2, 2.5, 1), request(0, 0.0, 6), request(1, 0.0, 1)],
        ] {
            let (results, _) = run_system(config.clone(), &requests).unwrap();
            // EP waits for the current wave; independent instances start immediately.
            close(
                latencies(&results, 2, 0)[0],
                if index == 1 { 1.5 } else { 1.0 },
            );
        }
    }
}

#[test]
fn same_time_routing_counts_work_assigned_before_enqueue() {
    let mut large = request(0, 0.0, 1);
    if let SubRequest::Llm { input_tokens, .. } = &mut large.sub_requests[0] {
        *input_tokens = 64;
    }
    for config in load_balanced_systems() {
        let (results, _) = run_system(
            config,
            &[large.clone(), request(1, 0.0, 1), request(2, 0.0, 1)],
        )
        .unwrap();
        // First two roots reserve 64 and 4 tokens; the third belongs with the smaller one.
        close(latencies(&results, 0, 0)[0], 8.0);
        close(latencies(&results, 1, 0)[0], 1.0);
        close(latencies(&results, 2, 0)[0], 2.0);
    }
}

#[test]
fn routing_reservation_moves_to_scheduler_load_and_is_released() {
    use simthesizer_core::{Engine, System};
    let mut system: Box<dyn System> = serde_json::from_value(single()).unwrap();
    system.init().unwrap();
    let mut graph = Graph::new();
    let mut input = request(0, 0.0, 2);
    if let SubRequest::Llm { interval, .. } = &mut input.sub_requests[0] {
        *interval = Some(0.5);
    }
    system
        .add_request_arrival(input, &mut graph, None, None)
        .unwrap();
    let mut frames = Vec::new();
    Engine::new(graph, system)
        .run_with_observer(|time, system| {
            frames.push((time, system.instance_load()));
            Ok(())
        })
        .unwrap();
    let frame = |time| frames.iter().find(|(t, _)| *t == time).unwrap().1;
    assert_eq!(
        (frame(0.0).waiting_requests, frame(0.0).waiting_tokens),
        (1, 4)
    );
    assert_eq!(
        (
            frame(0.5).waiting_requests,
            frame(0.5).running_requests,
            frame(0.5).total_tokens()
        ),
        (0, 1, 4)
    );
    assert_eq!(
        (frame(1.5).running_requests, frame(1.5).total_tokens()),
        (1, 1)
    );
    assert_eq!(frame(2.5), Default::default());
}

#[test]
fn parent_dependency_delays_routing_until_the_request_can_arrive() {
    use simthesizer_core::{Engine, LogicalHandler};
    for (index, config) in load_balanced_systems().into_iter().enumerate() {
        let mut system: Box<dyn System> = serde_json::from_value(config).unwrap();
        system.init().unwrap();
        let mut graph = Graph::new();
        let mut delay = common::Recorder::default();
        let parent = graph.add_logical_node(
            &mut delay as *mut dyn LogicalHandler,
            ("delay".to_string(), 2.5),
        );
        system
            .add_request_arrival(request(0, 0.0, 6), &mut graph, None, None)
            .unwrap();
        system
            .add_request_arrival(request(1, 0.0, 1), &mut graph, None, None)
            .unwrap();
        system
            .add_request_arrival(request(2, 0.0, 1), &mut graph, Some(parent), None)
            .unwrap();
        let results = Engine::new(graph, system).run().unwrap();
        close(
            latencies(&results, 2, 0)[0],
            if index == 1 { 1.5 } else { 1.0 },
        );
    }
}

#[test]
fn routed_pd_children_preserve_completion_sinks_and_seeded_handoff() {
    let mut config = pd();
    let child = json!({"kind":"multi_instance","instances":[single(),single()],
        "router":{"kind":"moe_load_balancing"}});
    config["prefill_instances"] = json!([child]);
    config["decode_instances"] = config["prefill_instances"].clone();
    let (results, end) = run_system(config, &[request(0, 0.0, 3)]).unwrap();
    assert_eq!(latencies(&results, 0, 0), [1.0, 3.25, 1.0]);
    close(end, 5.25);
}

#[test]
fn pd_token_timing_includes_transfer_and_preserves_original_metadata() {
    let mut input = request(0, 2.0, 3);
    if let SubRequest::Llm {
        interval, model, ..
    } = &mut input.sub_requests[0]
    {
        *interval = Some(0.5);
        *model = Some("model-revision".into());
    }
    let (result, end) = run_system(pd(), &[input]).unwrap();
    // 4 tokens * 64 KV bytes / 128 B/s + 0.25 s = 2.25 s transfer.
    assert_eq!(latencies(&result, 0, 0), &[1.0, 3.25, 1.0]);
    close(end, 7.75);
    match &result[0].sub_requests[0] {
        ResultSubRequest::Llm {
            interval, model, ..
        } => {
            assert_eq!(*interval, Some(0.5));
            assert_eq!(model.as_deref(), Some("model-revision"));
        }
        _ => unreachable!(),
    }
}

#[test]
fn pd_single_output_needs_no_decode_or_transfer() {
    let (result, end) = run_system(pd(), &[request(0, 0.0, 1)]).unwrap();
    assert_eq!(latencies(&result, 0, 0), &[1.0]);
    close(end, 1.0);
}

#[test]
fn pd_rejects_external_seeded_progress_instead_of_resetting_it() {
    for (known, kv) in [(4, 0), (4, 3), (5, 4)] {
        let mut input = request(0, 0.0, 3);
        if let SubRequest::Llm {
            known_tokens,
            kv_tokens,
            ..
        } = &mut input.sub_requests[0]
        {
            *known_tokens = Some(known);
            *kv_tokens = Some(kv);
        }
        let error = run_system(pd(), &[input]).unwrap_err();
        assert!(error.to_string().contains("seeded progress"), "{error}");
    }
}

#[test]
fn pd_first_decode_itl_includes_queueing_behind_another_request() {
    let mut config = pd();
    config["link_bw"] = json!(256.0);
    config["link_latency"] = json!(2.0);
    let (result, end) = run_system(config, &[request(0, 0.0, 4), request(1, 0.0, 2)]).unwrap();
    // Prefills end at 1 and 2; transfers end at 4 and 5. Decode 0 occupies [4,7].
    assert_eq!(latencies(&result, 0, 0), &[1.0, 4.0, 1.0, 1.0]);
    assert_eq!(latencies(&result, 1, 0), &[2.0, 6.0]);
    close(end, 8.0);
}

#[test]
fn zero_output_does_not_fabricate_tokens() {
    for config in [single(), ep(), pd()] {
        let (result, _) = run_system(config, &[request(0, 0.0, 0)]).unwrap();
        assert!(latencies(&result, 0, 0).is_empty());
    }
}

#[test]
fn systems_reject_result_collection_with_pending_requests() {
    for config in [
        single(),
        ep(),
        pd(),
        json!({"kind":"multi_instance","instances":[single()]}),
    ] {
        let kind = config["kind"].clone();
        let mut system: Box<dyn System> = serde_json::from_value(config).unwrap();
        system.init().unwrap();
        let mut graph = Graph::new();
        system
            .add_request_arrival(request(0, 0.0, 1), &mut graph, None, None)
            .unwrap();
        drop(graph);
        assert!(
            system.into_results().is_err(),
            "{kind} discarded unfinished work"
        );
    }
}

#[test]
fn empty_systems_return_empty_results() {
    for config in [
        single(),
        ep(),
        pd(),
        json!({"kind":"multi_instance","instances":[single()]}),
    ] {
        let (result, end) = run_system(config, &[]).unwrap();
        assert!(result.is_empty());
        close(end, 0.0);
    }
}

#[test]
fn pd_validates_the_original_request_before_splitting_it() {
    let mut system: Box<dyn System> = serde_json::from_value(pd()).unwrap();
    system.init().unwrap();
    let mut input = request(0, 0.0, 1);
    input.initial.clear();
    assert!(system
        .add_request_arrival(input, &mut Graph::new(), None, None)
        .is_err());
}
