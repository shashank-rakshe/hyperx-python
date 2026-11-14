use std::io::Write;

use anyhow::{bail, Result};
use serde::Serialize;
use serde_json::Value;

#[derive(Serialize)]
struct Frame {
    time_s: f64,
    state: Value,
}

pub struct TraceWriter<W> {
    writer: W,
    last: Option<Frame>,
    written_time: Option<f64>,
}

impl<W: Write> TraceWriter<W> {
    pub fn new(writer: W) -> Self {
        Self {
            writer,
            last: None,
            written_time: None,
        }
    }

    pub fn observe(&mut self, time_s: f64, state: Value) -> Result<()> {
        if !time_s.is_finite() || time_s < 0.0 {
            bail!("trace time must be finite and nonnegative");
        }
        if let Some(last) = &mut self.last {
            if time_s <= last.time_s {
                bail!("trace time must increase strictly");
            }
            if last.state == state {
                last.time_s = time_s;
                return Ok(());
            }
        }
        self.last = Some(Frame { time_s, state });
        self.write_last()
    }

    fn write_last(&mut self) -> Result<()> {
        if let Some(frame) = &self.last {
            serde_json::to_writer(&mut self.writer, frame)?;
            self.writer.write_all(b"\n")?;
            self.written_time = Some(frame.time_s);
        }
        Ok(())
    }

    pub fn finish(mut self) -> Result<()> {
        if self.last.as_ref().map(|frame| frame.time_s) != self.written_time {
            self.write_last()?;
        }
        self.writer.flush()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keeps_changes_and_endpoints_with_arbitrary_nested_state() {
        let mut bytes = Vec::new();
        let mut writer = TraceWriter::new(&mut bytes);
        let first = json!({"component": [null, {"custom": {"bytes": 17, "rate": 0.25}}]});
        let second = json!({"component": [null, {"custom": {"bytes": 19, "rate": 0.5}}]});
        for (time, value) in [(0.0, &first), (1.0, &first), (2.0, &second), (3.0, &second)] {
            writer.observe(time, value.clone()).unwrap();
        }
        writer.finish().unwrap();
        let frames: Vec<Value> = String::from_utf8(bytes)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(
            frames,
            vec![
                json!({"time_s": 0.0, "state": first}),
                json!({"time_s": 2.0, "state": second}),
                json!({"time_s": 3.0, "state": second})
            ]
        );
    }

    #[test]
    fn rejects_invalid_or_repeated_time() {
        for time in [f64::NAN, f64::INFINITY, -1.0, 0.0] {
            let mut writer = TraceWriter::new(Vec::new());
            writer.observe(0.0, Value::Null).unwrap();
            assert!(writer.observe(time, Value::Null).is_err());
        }
    }
}
