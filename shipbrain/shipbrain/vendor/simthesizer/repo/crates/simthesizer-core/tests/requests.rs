mod common;

use common::request;
use serde_json::json;
use simthesizer_core::types::{Request, SubRequest};

fn graph(initial: &[usize], successors: &[Vec<usize>]) -> Request {
    serde_json::from_value(json!({"request_id":1,"arrival_time":0,"initial":initial,
        "sub_requests":successors.iter().map(|next| json!({"kind":"tool_call",
            "input_tokens":0,"output_tokens":0,"next":next})).collect::<Vec<_>>()}))
    .unwrap()
}

#[test]
fn fork_join_and_disconnected_dag_components_are_valid() {
    graph(&[0, 1], &[vec![2], vec![2], vec![3, 4], vec![], vec![]])
        .validate()
        .unwrap();
    graph(&[0, 1], &[vec![], vec![]]).validate().unwrap();
}

#[test]
fn cycles_are_rejected_even_when_another_component_has_a_root() {
    for r in [
        graph(&[], &[vec![0]]),
        graph(&[], &[vec![1], vec![0]]),
        graph(&[0], &[vec![], vec![2], vec![1]]),
    ] {
        assert!(r.validate().is_err(), "accepted cyclic graph {r:?}");
    }
}

#[test]
fn invalid_graph_indices_and_roots_are_rejected() {
    for r in [
        graph(&[0], &[]),
        graph(&[1], &[vec![]]),
        graph(&[0, 0], &[vec![]]),
        graph(&[0], &[vec![1]]),
        graph(&[], &[vec![]]),
    ] {
        assert!(r.validate().is_err());
    }
}

#[test]
fn request_times_must_be_finite_and_nonnegative() {
    for value in [-1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let mut r = request(1, 0.0, 1);
        r.arrival_time = value;
        assert!(r.validate().is_err(), "arrival={value}");
        r.arrival_time = 0.0;
        if let SubRequest::Llm { interval, .. } = &mut r.sub_requests[0] {
            *interval = Some(value);
        }
        assert!(r.validate().is_err(), "interval={value}");
        let mut r = graph(&[0], &[vec![]]);
        if let SubRequest::ToolCall { duration, .. } = &mut r.sub_requests[0] {
            *duration = Some(value);
        }
        assert!(r.validate().is_err(), "duration={value}");
    }
}

#[test]
fn seeded_progress_requires_a_consistent_pair() {
    for (known, kv, valid) in [
        (None, None, true),
        (Some(4), Some(0), true),
        (Some(7), Some(7), true),
        (Some(4), None, false),
        (None, Some(0), false),
        (Some(3), Some(0), false),
        (Some(8), Some(0), false),
        (Some(4), Some(5), false),
    ] {
        let mut r = request(1, 0.0, 3);
        if let SubRequest::Llm {
            known_tokens,
            kv_tokens,
            ..
        } = &mut r.sub_requests[0]
        {
            *known_tokens = known;
            *kv_tokens = kv;
        }
        assert_eq!(r.validate().is_ok(), valid, "known={known:?} kv={kv:?}");
    }
}

#[test]
fn llm_token_count_overflow_is_rejected() {
    let mut r = request(1, 0.0, 1);
    if let SubRequest::Llm { input_tokens, .. } = &mut r.sub_requests[0] {
        *input_tokens = u32::MAX;
    }
    assert!(r.validate().is_err());
}
