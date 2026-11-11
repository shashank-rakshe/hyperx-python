use std::cell::RefCell;
use std::fs::File;
use std::io::{BufRead, BufReader};

use anyhow::Context;

use super::*;

#[derive(Debug, Deserialize)]
struct RequestShape {
    query: u32,
    context: u32,
}

#[derive(Debug, Deserialize)]
struct Component {
    name: String,
    calls_per_sample: Vec<u64>,
    samples_us: Vec<Option<f64>>,
}

#[derive(Debug, Deserialize)]
struct Worker {
    rank: u32,
    components: Vec<Component>,
}

#[derive(Debug, Deserialize)]
struct Measurement {
    variant: String,
    case: usize,
    requests: Vec<RequestShape>,
    workers: Vec<Worker>,
    #[serde(default)]
    routing: HashMap<String, u64>,
}

#[derive(Debug)]
pub(super) struct ShapeProfile {
    measurements: Vec<Measurement>,
    components: HashMap<String, Vec<String>>,
    tables: RefCell<HashMap<String, LayerLookupTable>>,
}

impl ShapeProfile {
    pub(super) fn load(
        path: &Path,
        variant: Option<&str>,
        components: HashMap<String, Vec<String>>,
        tp: u32,
    ) -> Result<Self> {
        if !path.extension().is_some_and(|ext| ext == "jsonl") {
            bail!(
                "table_lookup requires a .jsonl profile, got {}",
                path.display()
            );
        }
        let file =
            File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
        Self::read(BufReader::new(file), variant, components, tp)
            .with_context(|| format!("invalid profile {}", path.display()))
    }

    fn read(
        reader: impl BufRead,
        variant: Option<&str>,
        components: HashMap<String, Vec<String>>,
        tp: u32,
    ) -> Result<Self> {
        let mut metadata = HashMap::new();
        let mut measurements = Vec::new();
        let mut complete = None;
        for (index, line) in reader.lines().enumerate() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            if complete.is_some() {
                bail!("profile has records after complete");
            }
            let record: serde_json::Value =
                serde_json::from_str(&line).with_context(|| format!("line {}", index + 1))?;
            match record["type"].as_str() {
                Some("metadata") => {
                    if record["format_version"] != 1 {
                        bail!("unsupported profile format_version");
                    }
                    let name = record["variant"]
                        .as_str()
                        .context("missing variant")?
                        .to_owned();
                    let engine = record["engine"].as_object().context("missing engine")?;
                    let degree = match engine.get("tensor_parallel_size") {
                        None => 1,
                        Some(value) => value
                            .as_u64()
                            .filter(|n| *n > 0)
                            .context("invalid tensor_parallel_size")?,
                    };
                    if metadata.insert(name, degree).is_some() {
                        bail!("duplicate profile variant metadata");
                    }
                }
                Some("measurement") => {
                    measurements.push(serde_json::from_value::<Measurement>(record)?)
                }
                Some("complete") => {
                    complete = Some((
                        record["cases"].as_u64().context("missing complete.cases")?,
                        record["variants"]
                            .as_u64()
                            .context("missing complete.variants")?,
                    ))
                }
                _ => bail!("unknown profile record type"),
            }
        }
        let (cases, variants) =
            complete.context("profile is incomplete: missing complete record")?;
        if variants != metadata.len() as u64 || cases == 0 {
            bail!("profile completion counts do not match metadata");
        }
        let mut observed = std::collections::HashSet::new();
        for row in &measurements {
            if !metadata.contains_key(&row.variant)
                || row.case as u64 >= cases
                || !observed.insert((&row.variant, row.case))
            {
                bail!("unknown variant or duplicate/out-of-range profile case");
            }
        }
        if measurements.len() as u64
            != cases
                .checked_mul(variants)
                .context("profile count overflow")?
        {
            bail!("profile completion counts do not match measurements");
        }
        let variant = match variant {
            Some(name) => name,
            None if metadata.len() == 1 => metadata.keys().next().unwrap(),
            None => bail!("set profile_variant when a profile contains multiple variants"),
        };
        if metadata.get(variant) != Some(&u64::from(tp)) {
            bail!("profile variant '{variant}' is missing or has a different TP degree");
        }
        measurements.retain(|row| row.variant == variant);
        if measurements.is_empty() {
            bail!("profile variant '{variant}' has no measurements");
        }
        for row in &measurements {
            if row.requests.is_empty()
                || row
                    .requests
                    .iter()
                    .any(|r| r.query == 0 || r.query.checked_add(r.context).is_none())
            {
                bail!("profile batches require positive query lengths");
            }
            if !row.routing.is_empty() {
                bail!("JSONL table lookup does not yet support forced MoE routing");
            }
            if row.workers.iter().filter(|w| w.rank == 0).count() != 1 {
                bail!("profile measurement requires exactly one rank-0 worker");
            }
        }
        Ok(Self {
            measurements,
            components,
            tables: RefCell::new(HashMap::new()),
        })
    }

    pub(super) fn lookup(
        &self,
        layer: &Layer,
        key: LookupKey,
        batch: &[RequestState],
    ) -> Result<f64> {
        let mut tables = self.tables.borrow_mut();
        if !tables.contains_key(layer.name()) {
            tables.insert(layer.name().to_owned(), self.build_table(layer)?);
        }
        tables[layer.name()].lookup(layer, key, batch)
    }

    fn build_table(&self, layer: &Layer) -> Result<LayerLookupTable> {
        let default = vec![layer.name().to_owned()];
        let names = self.components.get(layer.name()).unwrap_or(&default);
        if names.is_empty() {
            bail!("empty component mapping for '{}'", layer.name());
        }
        let mut samples: Key0Samples = BTreeMap::new();
        let mut decode_samples: BTreeMap<u64, Key0Samples> = BTreeMap::new();
        for measurement in &self.measurements {
            let worker = measurement.workers.iter().find(|w| w.rank == 0).unwrap();
            let selected = worker
                .components
                .iter()
                .filter(|c| names.contains(&c.name))
                .collect::<Vec<_>>();
            if names
                .iter()
                .any(|name| !selected.iter().any(|c| &c.name == name))
            {
                bail!("missing profile component for '{}'", layer.name());
            }
            let Some(latency) = component_latency(&selected)? else {
                continue;
            };
            let batch = measurement
                .requests
                .iter()
                .map(|r| RequestState {
                    q_len: r.query,
                    kv_len: r.context,
                    lm_head_len: 1,
                })
                .collect::<Vec<_>>();
            let key = TableLookupComputeSimulator::lookup_params(
                layer,
                &batch,
                ComputeContext::default(),
                &[],
            )?;
            samples
                .entry(key.key_0)
                .or_default()
                .entry(key.key_1)
                .or_default()
                .record(latency);
            if matches!(layer, Layer::Attention { .. }) && batch.iter().all(|r| r.q_len == 1) {
                let max_kv = batch.iter().map(|r| u64::from(r.kv_len)).max().unwrap();
                decode_samples
                    .entry(batch.len() as u64)
                    .or_default()
                    .entry(max_kv)
                    .or_default()
                    .entry(key.key_0)
                    .or_default()
                    .record(latency);
            }
        }
        LayerLookupTable::from_samples(samples, decode_samples, layer.name())
    }
}

fn component_latency(components: &[&Component]) -> Result<Option<f64>> {
    let count = components
        .first()
        .context("no selected profile components")?
        .samples_us
        .len();
    if count == 0
        || components
            .iter()
            .any(|c| c.samples_us.len() != count || c.calls_per_sample.len() != count)
    {
        bail!("inconsistent component sample counts");
    }
    let mut samples = Vec::new();
    for index in 0..count {
        let mut calls = 0;
        let mut total = 0.0;
        for component in components {
            let n = component.calls_per_sample[index];
            match (n, component.samples_us[index]) {
                (0, None) => {}
                (n, Some(us)) if n > 0 && us.is_finite() && us >= 0.0 => {
                    calls += n;
                    total += us * n as f64;
                }
                _ => bail!("invalid calls or latency for '{}'", component.name),
            }
        }
        if calls > 0 {
            samples.push(total / calls as f64 * 1e-6);
        }
    }
    samples.sort_by(f64::total_cmp);
    Ok(if samples.is_empty() {
        None
    } else {
        Some((samples[(samples.len() - 1) / 2] + samples[samples.len() / 2]) / 2.0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    #[test]
    fn rejects_csv_profiles() {
        let error =
            ShapeProfile::load(Path::new("profile.csv"), None, HashMap::new(), 1).unwrap_err();
        assert!(error.to_string().contains("requires a .jsonl profile"));
    }

    fn fixture() -> Vec<Value> {
        vec![
            json!({"type": "metadata", "format_version": 1, "variant": "test", "engine": {}}),
            json!({"type": "measurement", "variant": "test", "case": 0,
                "requests": [{"query": 1, "context": 8}, {"query": 1, "context": 24}],
                "workers": [{"rank": 0, "components": [{"name": "attn", "calls_per_sample": [96], "samples_us": [10.0]}]}]}),
            json!({"type": "measurement", "variant": "test", "case": 1,
                "requests": [{"query": 1, "context": 16}, {"query": 1, "context": 16}],
                "workers": [{"rank": 0, "components": [{"name": "attn", "calls_per_sample": [96], "samples_us": [20.0]}]}]}),
            json!({"type": "complete", "cases": 2, "variants": 1}),
        ]
    }

    fn read_fixture(records: &[Value], tp: u32) -> Result<ShapeProfile> {
        let text = records
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        ShapeProfile::read(
            text.as_bytes(),
            None,
            [("attention".into(), vec!["attn".into()])].into(),
            tp,
        )
    }

    #[test]
    fn jsonl_preserves_decode_batch_shape_and_microsecond_units() {
        let profile = read_fixture(&fixture(), 1).unwrap();
        let layer = Layer::Attention {
            name: "attention".into(),
            num_q_heads: 32,
            num_kv_heads: 8,
            head_dim: 128,
        };
        for (contexts, expected) in [([8, 24], 10e-6), ([16, 16], 20e-6)] {
            let batch = contexts.map(|kv_len| RequestState {
                q_len: 1,
                kv_len,
                lm_head_len: 1,
            });
            let key = TableLookupComputeSimulator::lookup_params(
                &layer,
                &batch,
                ComputeContext::default(),
                &[],
            )
            .unwrap();
            assert!((profile.lookup(&layer, key, &batch).unwrap() - expected).abs() < 1e-12);
        }
    }

    #[test]
    fn rejects_incomplete_profiles_wrong_tp_and_duplicate_cases() {
        let mut records = fixture();
        assert!(read_fixture(&records, 2).is_err());
        assert!(read_fixture(&records[..3], 1).is_err());
        records[2]["case"] = json!(0);
        assert!(read_fixture(&records, 1).is_err());
    }

    #[test]
    fn combines_norms_by_invocations_before_taking_median() {
        let a = Component {
            name: "input".into(),
            calls_per_sample: vec![1, 1, 1],
            samples_us: vec![Some(2.0), Some(4.0), Some(100.0)],
        };
        let b = Component {
            name: "post".into(),
            calls_per_sample: vec![3, 3, 3],
            samples_us: vec![Some(6.0), Some(8.0), Some(0.0)],
        };
        assert!((component_latency(&[&a, &b]).unwrap().unwrap() - 7e-6).abs() < 1e-12);
    }

    #[test]
    fn distinguishes_uncalled_from_zero_gpu_work() {
        let mut row = Component {
            name: "norm".into(),
            calls_per_sample: vec![0],
            samples_us: vec![None],
        };
        assert_eq!(component_latency(&[&row]).unwrap(), None);
        row.calls_per_sample[0] = 1;
        assert!(component_latency(&[&row]).is_err());
        row.samples_us[0] = Some(0.0);
        assert_eq!(component_latency(&[&row]).unwrap(), Some(0.0));
    }
}
