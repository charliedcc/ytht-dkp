use anyhow::{Context, Result};
use std::path::Path;

/// Write a serde_json::Value as a Lua SavedVariables file
pub fn write_saved_variables(path: &Path, value: &serde_json::Value) -> Result<()> {
    // Create backup first
    if path.exists() {
        let backup = path.with_extension("lua.bak");
        std::fs::copy(path, &backup)
            .with_context(|| format!("Failed to create backup: {}", backup.display()))?;
    }

    let mut output = String::new();
    output.push_str("YTHT_DKP_DB = ");
    write_lua_value(&mut output, value, 0);
    output.push('\n');

    std::fs::write(path, &output)
        .with_context(|| format!("Failed to write: {}", path.display()))?;
    Ok(())
}

fn write_lua_value(out: &mut String, value: &serde_json::Value, indent: usize) {
    match value {
        serde_json::Value::Null => out.push_str("nil"),
        serde_json::Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                out.push_str(&i.to_string());
            } else if let Some(f) = n.as_f64() {
                if f.fract() == 0.0 && f.abs() < 1e15 {
                    out.push_str(&format!("{:.0}", f));
                } else {
                    out.push_str(&f.to_string());
                }
            }
        }
        serde_json::Value::String(s) => {
            out.push('"');
            for ch in s.chars() {
                match ch {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\r' => out.push_str("\\r"),
                    '\t' => out.push_str("\\t"),
                    _ => out.push(ch),
                }
            }
            out.push('"');
        }
        serde_json::Value::Array(arr) => {
            out.push_str("{\n");
            for (i, item) in arr.iter().enumerate() {
                write_indent(out, indent + 1);
                write_lua_value(out, item, indent + 1);
                out.push_str(", -- [");
                out.push_str(&(i + 1).to_string());
                out.push_str("]\n");
            }
            write_indent(out, indent);
            out.push('}');
        }
        serde_json::Value::Object(map) => {
            out.push_str("{\n");
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            for key in keys {
                let val = &map[key];
                write_indent(out, indent + 1);
                out.push_str("[\"");
                for ch in key.chars() {
                    match ch {
                        '"' => out.push_str("\\\""),
                        '\\' => out.push_str("\\\\"),
                        _ => out.push(ch),
                    }
                }
                out.push_str("\"] = ");
                write_lua_value(out, val, indent + 1);
                out.push_str(",\n");
            }
            write_indent(out, indent);
            out.push('}');
        }
    }
}

fn write_indent(out: &mut String, level: usize) {
    for _ in 0..level {
        out.push_str("    ");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_write_roundtrip_format() {
        let value = json!({
            "players": {
                "响当当": {
                    "dkp": 150,
                    "characters": [
                        { "name": "响当当", "class": "WARRIOR" }
                    ]
                }
            },
            "log": []
        });
        let mut output = String::new();
        output.push_str("YTHT_DKP_DB = ");
        write_lua_value(&mut output, &value, 0);
        output.push('\n');

        assert!(output.contains("[\"响当当\"]"));
        assert!(output.contains("[\"dkp\"] = 150"));
        assert!(output.contains("\"WARRIOR\""));
    }
}
