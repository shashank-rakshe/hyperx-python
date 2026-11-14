use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use serde_json::{json, Value};

fn config() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../examples/scenarios/1xrtx-pro-6000--llama3_1_8b--realistic/simthesizer.toml")
}

fn run(workload: &Path, result: &Path, trace: Option<&Path>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_simthesizer"));
    command
        .arg("--config")
        .arg(config())
        .arg("--workload")
        .arg(workload)
        .arg("--output-jsonl")
        .arg(result);
    if let Some(trace) = trace {
        command.arg("--output-engine-trace").arg(trace);
    }
    command.output().unwrap()
}

#[test]
fn trace_on_off_results_match_and_existing_outputs_are_preserved() {
    let root = tempfile::tempdir().unwrap();
    let workload = root.path().join("workload.jsonl");
    let request = json!({"request_id":0,"arrival_time":1.0,"initial":[0],
        "sub_requests":[{"kind":"llm","input_tokens":8,"output_tokens":2,"next":[]}]});
    std::fs::write(&workload, format!("{request}\n")).unwrap();
    let off = root.path().join("off.jsonl");
    let on = root.path().join("on.jsonl");
    let trace = root.path().join("trace.jsonl");
    let result = run(&workload, &off, None);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let result = run(&workload, &on, Some(&trace));
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert_eq!(std::fs::read(&off).unwrap(), std::fs::read(&on).unwrap());
    let bytes = std::fs::read(&trace).unwrap();
    let frames: Vec<Value> = String::from_utf8(bytes.clone())
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames[0]["time_s"], 0.0);
    assert_eq!(
        frames
            .last()
            .unwrap()
            .pointer("/state/scheduler/generation_tokens_total"),
        Some(&json!(2))
    );
    assert!(!run(&workload, &on, Some(&trace)).status.success());
    assert_eq!(std::fs::read(&trace).unwrap(), bytes);
}

#[test]
fn failed_simulation_does_not_publish_trace_and_alias_paths_are_rejected() {
    let root = tempfile::tempdir().unwrap();
    let workload = root.path().join("workload.jsonl");
    let request = json!({"request_id":0,"arrival_time":0.0,"initial":[0],
        "sub_requests":[{"kind":"llm","input_tokens":8,"output_tokens":1,"next":[]}]});
    std::fs::write(&workload, format!("{request}\n{request}\n")).unwrap();
    let trace = root.path().join("trace.jsonl");
    let result = root.path().join("results.jsonl");
    assert!(!run(&workload, &result, Some(&trace)).status.success());
    assert!(!trace.exists());
    std::fs::write(&workload, format!("{request}\n")).unwrap();
    let alias = root.path().join("sub/../trace.jsonl");
    assert!(!run(&workload, &alias, Some(&trace)).status.success());
    assert!(!trace.exists());
}

#[test]
fn malformed_request_semantics_fail_without_publishing_outputs() {
    for request in [
        json!({"request_id":0,"arrival_time":-1.0,"initial":[0],
            "sub_requests":[{"kind":"llm","input_tokens":8,"output_tokens":1,"next":[]}]}),
        json!({"request_id":0,"arrival_time":0.0,"initial":[],
            "sub_requests":[{"kind":"tool_call","input_tokens":0,"output_tokens":0,"next":[0]}]}),
        json!({"request_id":0,"arrival_time":0.0,"initial":[0],
            "sub_requests":[{"kind":"tool_call","input_tokens":0,"output_tokens":0,"duration":-1.0,"next":[]}]}),
    ] {
        let root = tempfile::tempdir().unwrap();
        let workload = root.path().join("workload.jsonl");
        let result = root.path().join("results.jsonl");
        let trace = root.path().join("trace.jsonl");
        std::fs::write(&workload, format!("{request}\n")).unwrap();
        assert!(!run(&workload, &result, Some(&trace)).status.success());
        assert!(!result.exists());
        assert!(!trace.exists());
    }
}
