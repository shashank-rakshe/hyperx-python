use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Result};
use serde::Deserialize;

use crate::compute_sim::ComputeSimulator;
use crate::module::Module;
use crate::types::{ComputeContext, Layer, ParallelStrategy, RequestState};

mod profile;
use profile::ShapeProfile;

#[derive(Debug, Default, Clone, Copy)]
struct LatencyAccumulator {
    total: f64,
    count: u32,
}

type Key1Samples = BTreeMap<u64, LatencyAccumulator>;
type Key0Samples = BTreeMap<u64, Key1Samples>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LookupKey {
    key_0: u64,
    key_1: u64,
}

#[derive(Debug, Clone, Copy, Default)]
struct BatchKeys {
    tokens: u64,
    lm_heads: u64,
    attention_compute: u64,
    attention_memory: u64,
}

impl BatchKeys {
    fn from_batch(batch: &[RequestState]) -> Self {
        let mut keys = Self::default();
        for request in batch {
            let q_len = u64::from(request.q_len);
            let kv_len = u64::from(request.kv_len);
            keys.tokens += q_len;
            keys.lm_heads += u64::from(request.lm_head_len);
            keys.attention_memory += kv_len;
            keys.attention_compute += q_len * (q_len / 2 + kv_len);
        }
        keys
    }
}

impl LatencyAccumulator {
    fn record(&mut self, latency: f64) {
        self.total += latency;
        self.count += 1;
    }

    fn mean(self) -> Result<f64> {
        if self.count == 0 {
            bail!("latency accumulator is empty");
        }
        Ok(self.total / f64::from(self.count))
    }
}

#[derive(Debug, Clone)]
struct LookupTable1D {
    keys: Vec<u64>,
    values: Vec<f64>,
}

impl LookupTable1D {
    fn from_samples(samples: BTreeMap<u64, f64>, label: &str) -> Result<Self> {
        if samples.is_empty() {
            bail!("{label} table is empty");
        }

        let (keys, values): (Vec<_>, Vec<_>) = samples.into_iter().unzip();
        Ok(Self { keys, values })
    }

    fn lookup(&self, query: f64) -> f64 {
        self.lookup_above(query, None)
    }

    fn lookup_above(&self, query: f64, boundary: Option<u64>) -> f64 {
        let first = boundary
            .map_or(0, |key| self.keys.partition_point(|sample| *sample <= key))
            .min(self.keys.len() - 1);
        let (lower, upper) = lookup_bounds(&self.keys[first..], query);
        let (lower, upper) = (lower + first, upper + first);
        let lower_value = self.values[lower];
        if lower == upper {
            return lower_value;
        }

        linear_interpolate(
            self.keys[lower] as f64,
            lower_value,
            self.keys[upper] as f64,
            self.values[upper],
            query,
        )
    }
}

#[derive(Debug, Clone)]
struct LookupTable2D {
    key_0: Vec<u64>,
    rows: Vec<LookupTable1D>,
}

impl LookupTable2D {
    fn from_samples(samples: BTreeMap<u64, BTreeMap<u64, f64>>, label: &str) -> Result<Self> {
        if samples.is_empty() {
            bail!("{label} table is empty");
        }

        let mut key_0 = Vec::with_capacity(samples.len());
        let mut rows = Vec::with_capacity(samples.len());
        for (outer_key, inner_samples) in samples {
            key_0.push(outer_key);
            rows.push(LookupTable1D::from_samples(
                inner_samples,
                &format!("{label} inner row {outer_key}"),
            )?);
        }

        Ok(Self { key_0, rows })
    }

    fn lookup(&self, key: LookupKey, layer: &Layer) -> f64 {
        let attention = matches!(layer, Layer::Attention { .. });
        self.interpolate_rows(key.key_0 as f64, |outer, row| {
            let query = if attention && key.key_0 > 0 && outer > 0 {
                // Hold compute/memory constant: one-token decode stays on its boundary.
                key.key_1 as f64 * outer as f64 / key.key_0 as f64
            } else {
                key.key_1 as f64
            };
            // Multi-token attention can use a different kernel even in a mixed batch.
            row.lookup_above(query, (attention && key.key_1 > key.key_0).then_some(outer))
        })
    }

    fn interpolate_rows(&self, outer: f64, at_row: impl Fn(u64, &LookupTable1D) -> f64) -> f64 {
        let (lower, upper) = lookup_bounds(&self.key_0, outer);
        let lower_value = at_row(self.key_0[lower], &self.rows[lower]);
        if lower == upper {
            return lower_value;
        }
        linear_interpolate(
            self.key_0[lower] as f64,
            lower_value,
            self.key_0[upper] as f64,
            at_row(self.key_0[upper], &self.rows[upper]),
            outer,
        )
    }
}

fn mean_samples(samples: Key0Samples) -> Result<BTreeMap<u64, BTreeMap<u64, f64>>> {
    samples
        .into_iter()
        .map(|(outer, inner)| {
            let inner = inner
                .into_iter()
                .map(|(key, value)| value.mean().map(|mean| (key, mean)))
                .collect::<Result<_>>()?;
            Ok((outer, inner))
        })
        .collect()
}

#[derive(Debug)]
struct DecodeLookupTable {
    batch_sizes: Vec<u64>,
    rows: Vec<LookupTable2D>,
}

impl DecodeLookupTable {
    fn from_samples(samples: BTreeMap<u64, Key0Samples>, label: &str) -> Result<Self> {
        let mut batch_sizes = Vec::new();
        let mut rows = Vec::new();
        for (size, samples) in samples {
            batch_sizes.push(size);
            rows.push(LookupTable2D::from_samples(mean_samples(samples)?, label)?);
        }
        Ok(Self { batch_sizes, rows })
    }

    fn lookup(&self, batch: &[RequestState]) -> f64 {
        let size = batch.len() as f64;
        let max_kv = batch.iter().map(|r| r.kv_len).max().unwrap_or(0) as f64;
        let total_kv: f64 = batch.iter().map(|r| f64::from(r.kv_len)).sum();
        let (lower, upper) = lookup_bounds(&self.batch_sizes, size);
        let at_size = |index: usize| {
            // Preserve mean/max KV across sampled batch sizes and maximum lengths.
            self.rows[index].interpolate_rows(max_kv, |sample_max, row| {
                let query = if max_kv == 0.0 {
                    0.0
                } else {
                    total_kv * self.batch_sizes[index] as f64 / size * sample_max as f64 / max_kv
                };
                row.lookup(query)
            })
        };
        if lower == upper {
            return at_size(lower);
        }
        linear_interpolate(
            self.batch_sizes[lower] as f64,
            at_size(lower),
            self.batch_sizes[upper] as f64,
            at_size(upper),
            size,
        )
    }
}

#[derive(Debug)]
struct LayerLookupTable {
    samples: LookupTable2D,
    decode: Option<DecodeLookupTable>,
}

impl LayerLookupTable {
    fn from_samples(
        samples: Key0Samples,
        decode: BTreeMap<u64, Key0Samples>,
        label: &str,
    ) -> Result<Self> {
        Ok(Self {
            samples: LookupTable2D::from_samples(mean_samples(samples)?, label)?,
            decode: if decode.is_empty() {
                None
            } else {
                Some(DecodeLookupTable::from_samples(decode, label)?)
            },
        })
    }

    fn lookup(&self, layer: &Layer, key: LookupKey, batch: &[RequestState]) -> Result<f64> {
        let latency = if matches!(layer, Layer::Attention { .. })
            && !batch.is_empty()
            && batch.iter().all(|r| r.q_len == 1)
        {
            self.decode.as_ref().map_or_else(
                || self.samples.lookup(key, layer),
                |table| table.lookup(batch),
            )
        } else {
            self.samples.lookup(key, layer)
        };
        validate_latency(latency, layer.name())?;
        Ok(latency)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TableLookupComputeSimulator {
    perf_dir: PathBuf,

    #[serde(default)]
    profile_variant: Option<String>,

    #[serde(default)]
    components: HashMap<String, Vec<String>>,

    #[serde(default)]
    cudagraph_capture_sizes: Vec<u32>,

    #[serde(skip_deserializing, default)]
    profile: Option<ShapeProfile>,
}

crate::register_compute_simulator!(TableLookupComputeSimulator, "table_lookup");

impl TableLookupComputeSimulator {
    fn lookup_params(
        layer: &Layer,
        batch: &[RequestState],
        context: ComputeContext,
        capture_sizes: &[u32],
    ) -> Result<LookupKey> {
        let keys = BatchKeys::from_batch(batch);
        let padded_tokens = capture_sizes
            .iter()
            .map(|size| u64::from(*size))
            .find(|size| *size >= keys.tokens)
            .unwrap_or(keys.tokens);
        let key = match layer {
            Layer::Attention { .. } | Layer::Mamba { .. } => LookupKey {
                key_0: keys.attention_memory,
                key_1: keys.attention_compute,
            },
            Layer::Sampler { .. } => LookupKey {
                key_0: 0,
                key_1: keys.lm_heads,
            },
            Layer::Gemm { name, .. } if name == "lm_head" => LookupKey {
                key_0: 0,
                key_1: keys.lm_heads,
            },
            Layer::Embedding { .. }
            | Layer::LayerNorm { .. }
            | Layer::Gemm { .. }
            | Layer::Rope { .. }
            | Layer::Act { .. } => LookupKey {
                key_0: 0,
                key_1: padded_tokens,
            },
            Layer::Moe { .. } => LookupKey {
                key_0: keys.tokens,
                key_1: context
                    .moe_activated_experts
                    .ok_or_else(|| anyhow!("moe layer requires activated expert context"))?,
            },
            Layer::AllReduce { .. } => bail!("all-reduce layer cannot be simulated as compute"),
        };
        Ok(key)
    }
}

impl Module for TableLookupComputeSimulator {
    fn resolve_path(&mut self, base_dir: &Path) -> Result<()> {
        if self.perf_dir.is_relative() {
            self.perf_dir = base_dir.join(&self.perf_dir);
        }
        Ok(())
    }
}

impl ComputeSimulator for TableLookupComputeSimulator {
    fn init(&mut self, parallel: ParallelStrategy) -> Result<()> {
        if self.cudagraph_capture_sizes.contains(&0) {
            bail!("cudagraph_capture_sizes must be positive");
        }
        self.cudagraph_capture_sizes.sort_unstable();
        self.cudagraph_capture_sizes.dedup();
        self.profile = Some(ShapeProfile::load(
            &self.perf_dir,
            self.profile_variant.as_deref(),
            self.components.clone(),
            parallel.tp,
        )?);
        Ok(())
    }

    fn simulate(
        &self,
        layer: &Layer,
        batch: &[RequestState],
        context: ComputeContext,
    ) -> Result<f64> {
        let profile = self
            .profile
            .as_ref()
            .ok_or_else(|| anyhow!("compute simulator must be initialized before use"))?;
        let key = Self::lookup_params(layer, batch, context, &self.cudagraph_capture_sizes)?;
        profile.lookup(layer, key, batch)
    }
}

fn validate_latency(latency: f64, layer_name: &str) -> Result<()> {
    if !latency.is_finite() || latency < 0.0 {
        bail!("computed invalid latency for layer '{layer_name}'");
    }
    Ok(())
}

fn lookup_bounds(keys: &[u64], query: f64) -> (usize, usize) {
    debug_assert!(!keys.is_empty());
    if keys.len() == 1 {
        return (0, 0);
    }

    match keys.binary_search_by(|key| (*key as f64).total_cmp(&query)) {
        Ok(index) => (index, index),
        Err(0) => (0, 0),
        Err(index) if index >= keys.len() => (keys.len() - 2, keys.len() - 1),
        Err(index) => (index - 1, index),
    }
}

fn linear_interpolate(x0: f64, y0: f64, x1: f64, y1: f64, query: f64) -> f64 {
    if x0 == x1 {
        return y0;
    }
    let span = x1 - x0;
    let offset = (query - x0).max(0.0);
    y0 + (y1 - y0) * (offset / span)
}

#[cfg(test)]
mod tests {
    use super::{
        BatchKeys, DecodeLookupTable, LatencyAccumulator, LayerLookupTable, LookupKey,
        LookupTable1D, LookupTable2D, TableLookupComputeSimulator,
    };
    use crate::types::{ComputeContext, Layer, RequestState};

    fn attention() -> Layer {
        Layer::Attention {
            name: "attention".into(),
            num_q_heads: 32,
            num_kv_heads: 8,
            head_dim: 128,
        }
    }

    fn attention_table() -> LookupTable2D {
        LookupTable2D::from_samples(
            [
                (0, [(8, 100.0), (16, 200.0)].into()),
                (8, [(8, 10.0), (16, 40.0), (32, 100.0)].into()),
                (16, [(16, 20.0), (32, 80.0), (64, 200.0)].into()),
            ]
            .into(),
            "attention",
        )
        .unwrap()
    }

    #[test]
    fn dense_lookup_clamps_below_and_extrapolates_above_samples() {
        let table = LookupTable1D::from_samples([(4, 2.0), (8, 6.0)].into(), "dense").unwrap();
        for (tokens, latency) in [(0.0, 2.0), (4.0, 2.0), (6.0, 4.0), (8.0, 6.0), (12.0, 10.0)] {
            assert_eq!(table.lookup(tokens), latency);
        }
        let singleton = LookupTable1D::from_samples([(4, 2.0)].into(), "dense").unwrap();
        assert_eq!(singleton.lookup(100.0), 2.0);
    }

    #[test]
    fn negative_extrapolated_cost_fails_instead_of_reversing_time() {
        let sample = |total| LatencyAccumulator { total, count: 1 };
        let table = LayerLookupTable::from_samples(
            [(0, [(4, sample(6.0)), (8, sample(2.0))].into())].into(),
            Default::default(),
            "dense",
        )
        .unwrap();
        let layer = Layer::LayerNorm {
            name: "dense".into(),
            hidden_size: 8,
        };
        assert!(table
            .lookup(
                &layer,
                LookupKey {
                    key_0: 0,
                    key_1: 12
                },
                &[]
            )
            .is_err());
    }

    #[test]
    fn moe_cost_requires_expert_context_and_collectives_are_not_compute() {
        let layer = Layer::Moe {
            name: "moe".into(),
            num_experts: 4,
            num_experts_per_token: 2,
            num_shared_experts_per_token: 0,
            dispatch_bytes_per_token: 16,
            combine_bytes_per_token: 16,
        };
        let batch = [RequestState {
            q_len: 3,
            kv_len: 8,
            lm_head_len: 1,
        }];
        assert!(TableLookupComputeSimulator::lookup_params(
            &layer,
            &batch,
            ComputeContext::default(),
            &[]
        )
        .is_err());
        assert_eq!(
            TableLookupComputeSimulator::lookup_params(
                &layer,
                &batch,
                ComputeContext {
                    moe_activated_experts: Some(2)
                },
                &[8]
            )
            .unwrap(),
            LookupKey { key_0: 3, key_1: 2 }
        );
        let collective = Layer::AllReduce {
            name: "reduce".into(),
            bytes_per_token: 16,
        };
        assert!(TableLookupComputeSimulator::lookup_params(
            &collective,
            &batch,
            ComputeContext::default(),
            &[]
        )
        .is_err());
    }

    #[test]
    fn attention_decode_interpolates_along_single_token_boundary() {
        let table = attention_table();
        // Multi-token samples must not affect interpolation or extrapolation.
        for (memory, expected) in [(8, 10.0), (12, 15.0), (16, 20.0), (24, 30.0)] {
            assert_eq!(
                table.lookup(
                    LookupKey {
                        key_0: memory,
                        key_1: memory
                    },
                    &attention()
                ),
                expected,
            );
        }
    }

    #[test]
    fn attention_preserves_fractional_compute_to_memory_ratio() {
        let table = attention_table();
        for (compute, expected) in [(13, 60.0), (24, 60.0), (25, 63.75), (30, 82.5)] {
            let actual = table.lookup(
                LookupKey {
                    key_0: 12,
                    key_1: compute,
                },
                &attention(),
            );
            assert!((actual - expected).abs() < 1e-10);
        }
        assert_eq!(
            table.lookup(
                LookupKey {
                    key_0: 8,
                    key_1: 16
                },
                &attention()
            ),
            40.0
        );
        // Prefill without cached KV retains its raw compute axis.
        assert_eq!(
            table.lookup(
                LookupKey {
                    key_0: 0,
                    key_1: 12
                },
                &attention()
            ),
            150.0
        );
    }

    #[test]
    fn other_layers_keep_cartesian_interpolation() {
        let layer = Layer::Moe {
            name: "moe".into(),
            num_experts: 64,
            num_experts_per_token: 2,
            num_shared_experts_per_token: 0,
            dispatch_bytes_per_token: 1,
            combine_bytes_per_token: 1,
        };
        assert_eq!(
            attention_table().lookup(
                LookupKey {
                    key_0: 12,
                    key_1: 12
                },
                &layer
            ),
            22.5
        );
    }

    #[test]
    fn decode_interpolation_preserves_length_distribution() {
        let samples = [2, 4]
            .into_iter()
            .map(|n| {
                let rows = [0, 8, 16]
                    .into_iter()
                    .map(|max_kv| {
                        let inner = [max_kv, n * max_kv]
                            .into_iter()
                            .map(|total| {
                                let mut value = LatencyAccumulator::default();
                                value.record((n + max_kv + total) as f64);
                                (total, value)
                            })
                            .collect();
                        (max_kv, inner)
                    })
                    .collect();
                (n, rows)
            })
            .collect();
        let table = DecodeLookupTable::from_samples(samples, "attention").unwrap();
        for (lengths, expected) in [([10, 10, 5], 38.0), ([15, 5, 5], 43.0), ([0, 0, 0], 3.0)] {
            let batch = lengths.map(|kv_len| RequestState {
                q_len: 1,
                kv_len,
                lm_head_len: 1,
            });
            assert!((table.lookup(&batch) - expected).abs() < 1e-10);
        }
    }

    #[test]
    fn decode_samples_are_optional_and_only_price_single_token_attention() {
        let sample = |total| LatencyAccumulator { total, count: 1 };
        let mut table = LayerLookupTable::from_samples(
            [(8, [(8, sample(10.0))].into())].into(),
            [(2, [(4, [(8, sample(20.0))].into())].into())].into(),
            "attention",
        )
        .unwrap();
        let mut batch = [RequestState {
            q_len: 1,
            kv_len: 4,
            lm_head_len: 1,
        }; 2];
        let key = LookupKey { key_0: 8, key_1: 8 };
        assert_eq!(table.lookup(&attention(), key, &batch).unwrap(), 20.0);
        batch[0].q_len = 2;
        assert_eq!(table.lookup(&attention(), key, &batch).unwrap(), 10.0);
        batch[0].q_len = 1;
        table.decode = None;
        assert_eq!(table.lookup(&attention(), key, &batch).unwrap(), 10.0);
    }

    #[test]
    fn graph_padding_prices_dense_rows_without_adding_requests_or_kv() {
        let batch = [RequestState {
            q_len: 1,
            kv_len: 8,
            lm_head_len: 1,
        }; 3];
        let lookup = |layer| {
            TableLookupComputeSimulator::lookup_params(
                &layer,
                &batch,
                ComputeContext::default(),
                &[1, 2, 4, 8],
            )
            .unwrap()
        };
        assert_eq!(
            lookup(Layer::Gemm {
                name: "qkv_projection".into(),
                m: 1,
                n: 1
            })
            .key_1,
            4
        );
        assert_eq!(
            lookup(Layer::Gemm {
                name: "lm_head".into(),
                m: 1,
                n: 1
            })
            .key_1,
            3
        );
        assert_eq!(
            lookup(attention()),
            LookupKey {
                key_0: 24,
                key_1: 24
            }
        );
    }

    #[test]
    fn mamba_uses_attention_lookup_keys() {
        let batch = vec![
            RequestState {
                q_len: 4,
                kv_len: 8,
                lm_head_len: 1,
            },
            RequestState {
                q_len: 2,
                kv_len: 16,
                lm_head_len: 1,
            },
        ];
        let keys = BatchKeys::from_batch(&batch);

        let layer = Layer::Mamba {
            name: "mamba".to_string(),
            num_heads: 64,
            head_dim: 64,
            state_size: 128,
            conv_kernel_size: 4,
        };
        let key = TableLookupComputeSimulator::lookup_params(
            &layer,
            &batch,
            ComputeContext::default(),
            &[],
        )
        .expect("mamba layer lookup should succeed");

        assert_eq!(
            key,
            LookupKey {
                key_0: keys.attention_memory,
                key_1: keys.attention_compute,
            }
        );
    }
}
