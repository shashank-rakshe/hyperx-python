mod common;

use common::request;
use serde_json::json;
use simthesizer_core::types::InstanceLoad;
use simthesizer_core::Router;

fn router(kind: &str) -> Box<dyn Router> {
    serde_json::from_value(json!({"kind":kind})).unwrap()
}

#[test]
fn equal_load_placement_cycles_without_starvation() {
    for kind in ["round_robin", "moe_load_balancing"] {
        let mut r = router(kind);
        let loads = [InstanceLoad::default(); 3];
        let chosen: Vec<_> = (0..9)
            .map(|id| r.select_instance(&request(id, 0.0, 1), &loads).unwrap())
            .collect();
        assert_eq!(chosen, [0, 1, 2, 0, 1, 2, 0, 1, 2]);
    }
}

#[test]
fn load_balancing_reacts_to_tokens_then_request_count() {
    let mut r = router("moe_load_balancing");
    let mut loads = [
        InstanceLoad {
            waiting_requests: 1,
            waiting_tokens: 20,
            ..Default::default()
        },
        InstanceLoad {
            running_requests: 2,
            running_tokens: 8,
            ..Default::default()
        },
    ];
    assert_eq!(r.select_instance(&request(0, 0.0, 1), &loads).unwrap(), 1);
    loads[0].waiting_tokens = 8;
    assert_eq!(r.select_instance(&request(1, 0.0, 1), &loads).unwrap(), 0);
    loads[0].waiting_tokens = 30;
    assert_eq!(r.select_instance(&request(2, 0.0, 1), &loads).unwrap(), 1);
}

#[test]
fn empty_instance_set_is_an_error() {
    for kind in ["round_robin", "moe_load_balancing"] {
        assert!(router(kind)
            .select_instance(&request(0, 0.0, 1), &[])
            .is_err());
    }
}
