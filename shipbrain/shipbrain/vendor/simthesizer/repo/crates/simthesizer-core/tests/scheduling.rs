use serde_json::json;
use simthesizer_core::types::{ParallelStrategy, ReadySubRequest};
use simthesizer_core::Scheduler;

fn scheduler(budget: u32, max_batch: usize, memory: u64, fixed_state: u64) -> Box<dyn Scheduler> {
    let mut s: Box<dyn Scheduler> = serde_json::from_value(json!({"kind":"chunked_prefill",
        "block_size":4,"max_batch":max_batch,"max_num_batched_tokens":budget,
        "device_mem":memory,"device_mem_utilization":1.0,"enable_prefix_caching":false}))
    .unwrap();
    s.init(
        100,
        fixed_state,
        2,
        ParallelStrategy {
            tp: 1,
            pp: 1,
            ep: 1,
        },
    )
    .unwrap();
    s
}

fn request(id: u64, input: u32, output: u32) -> ReadySubRequest {
    ReadySubRequest {
        request_id: id,
        subrequest_index: 0,
        completion_node_id: id,
        arrival_time: 0.0,
        input_tokens: input,
        output_tokens: output,
        known_tokens: input,
        kv_tokens: 0,
        input_token_ids: None,
        output_token_ids: None,
    }
}

#[test]
fn token_budget_and_batch_limit_conserve_work_across_chunk_boundaries() {
    for budget in [1, 3, 4, 5, 16] {
        for max_batch in [1, 2, 4] {
            let mut s = scheduler(budget, max_batch, 10000, 0);
            for (id, input, output) in [(0, 3, 1), (1, 4, 3), (2, 5, 2)] {
                s.enqueue_sub_request(request(id, input, output));
            }
            let mut total_q = 0;
            let mut completed = Vec::new();
            for tick in 1..=40 {
                let batch = s.schedule().unwrap();
                if batch.is_empty() {
                    break;
                }
                let q = batch.iter().map(|r| r.q_len).sum::<u32>();
                assert!(q <= budget);
                assert!(batch.len() <= max_batch);
                assert!(batch.iter().all(|r| r.q_len > 0));
                total_q += q;
                completed.extend(s.done_iteration(f64::from(tick)));
            }
            completed.sort_by_key(|c| c.request_id);
            assert_eq!(
                completed
                    .iter()
                    .map(|c| c.token_latency.len())
                    .collect::<Vec<_>>(),
                [1, 3, 2]
            );
            // Each prompt is computed once; the final sampled token needs no forward pass.
            assert_eq!(total_q, 3 + 4 + 5 + 2 + 1);
            assert_eq!(s.instance_load().total_requests(), 0);
        }
    }
}

#[test]
fn fixed_state_and_block_rounding_control_admission_and_release() {
    // 100 weight + 10 recurrent state + one four-token KV block * 2 bytes = 118.
    let mut s = scheduler(8, 2, 118, 10);
    s.enqueue_sub_request(request(0, 3, 1));
    s.enqueue_sub_request(request(1, 3, 1));
    assert_eq!(s.schedule().unwrap().len(), 1);
    assert_eq!(s.done_iteration(1.0)[0].request_id, 0);
    assert_eq!(s.schedule().unwrap().len(), 1);
    assert_eq!(s.done_iteration(2.0)[0].request_id, 1);
    assert!(s.schedule().unwrap().is_empty());
    let mut too_small = scheduler(8, 1, 117, 10);
    too_small.enqueue_sub_request(request(0, 3, 1));
    assert!(too_small.schedule().is_err());
}

#[test]
fn an_iteration_cannot_be_scheduled_twice() {
    let mut s = scheduler(4, 1, 1000, 0);
    s.enqueue_sub_request(request(0, 4, 2));
    assert_eq!(s.schedule().unwrap().len(), 1);
    assert!(s.schedule().unwrap().is_empty());
    assert!(s.done_iteration(1.0).is_empty());
    assert_eq!(s.schedule().unwrap()[0].q_len, 1);
    assert_eq!(s.done_iteration(2.0)[0].token_latency, [1.0, 1.0]);
}
