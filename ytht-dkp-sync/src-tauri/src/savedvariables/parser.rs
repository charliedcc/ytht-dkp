use anyhow::{anyhow, Context, Result};
use mlua::prelude::*;
use std::path::Path;

use crate::model::DkpDatabase;

/// Parse a WoW SavedVariables .lua file into DkpDatabase
pub fn parse_saved_variables(path: &Path) -> Result<DkpDatabase> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read: {}", path.display()))?;
    parse_saved_variables_str(&content)
}

/// Parse SavedVariables content string into DkpDatabase
pub fn parse_saved_variables_str(content: &str) -> Result<DkpDatabase> {
    let lua = Lua::new();

    lua.load(content)
        .exec()
        .map_err(|e| anyhow!("Lua exec error: {e}"))?;

    let globals = lua.globals();
    let db_table: LuaValue = globals
        .get("YTHT_DKP_DB")
        .map_err(|e| anyhow!("YTHT_DKP_DB not found: {e}"))?;

    let json_value = lua_value_to_json(&db_table)?;
    let db: DkpDatabase = serde_json::from_value(json_value)
        .context("Failed to deserialize DkpDatabase")?;

    Ok(db)
}

/// Convert mlua::Value to serde_json::Value
fn lua_value_to_json(value: &LuaValue) -> Result<serde_json::Value> {
    match value {
        LuaValue::Nil => Ok(serde_json::Value::Null),
        LuaValue::Boolean(b) => Ok(serde_json::Value::Bool(*b)),
        LuaValue::Integer(i) => Ok(serde_json::Value::Number((*i).into())),
        LuaValue::Number(n) => {
            if let Some(num) = serde_json::Number::from_f64(*n) {
                Ok(serde_json::Value::Number(num))
            } else {
                Ok(serde_json::Value::Null)
            }
        }
        LuaValue::String(s) => {
            let s = s.to_str().map_err(|e| anyhow!("UTF-8 error: {e}"))?.to_string();
            Ok(serde_json::Value::String(s))
        }
        LuaValue::Table(table) => {
            if is_lua_array(table) {
                let mut arr = Vec::new();
                for pair in table.clone().sequence_values::<LuaValue>() {
                    let val = pair.map_err(|e| anyhow!("Lua sequence error: {e}"))?;
                    arr.push(lua_value_to_json(&val)?);
                }
                Ok(serde_json::Value::Array(arr))
            } else {
                let mut map = serde_json::Map::new();
                for pair in table.clone().pairs::<LuaValue, LuaValue>() {
                    let (key, val) = pair.map_err(|e| anyhow!("Lua pairs error: {e}"))?;
                    let key_str = match &key {
                        LuaValue::String(s) => {
                            s.to_str().map_err(|e| anyhow!("Key UTF-8 error: {e}"))?.to_string()
                        }
                        LuaValue::Integer(i) => i.to_string(),
                        LuaValue::Number(n) => n.to_string(),
                        _ => continue,
                    };
                    map.insert(key_str, lua_value_to_json(&val)?);
                }
                Ok(serde_json::Value::Object(map))
            }
        }
        _ => Ok(serde_json::Value::Null),
    }
}

/// Check if a Lua table is a sequential array (keys 1..n with no gaps)
fn is_lua_array(table: &LuaTable) -> bool {
    let len = table.raw_len();
    if len == 0 {
        for pair in table.clone().pairs::<LuaValue, LuaValue>() {
            if let Ok((key, _)) = pair {
                return matches!(key, LuaValue::Integer(_));
            }
        }
        return false;
    }
    let mut count = 0;
    for pair in table.clone().pairs::<LuaValue, LuaValue>() {
        if pair.is_ok() {
            count += 1;
        }
    }
    count == len
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_empty_db() {
        let lua = r#"YTHT_DKP_DB = { ["players"] = {}, ["log"] = {} }"#;
        let db = parse_saved_variables_str(lua).unwrap();
        assert!(db.players.is_empty());
        assert!(db.log.is_empty());
    }

    #[test]
    fn test_parse_with_chinese_names() {
        let lua = r#"
YTHT_DKP_DB = {
    ["players"] = {
        ["响当当"] = {
            ["dkp"] = 150,
            ["characters"] = {
                { ["name"] = "响当当", ["class"] = "WARRIOR" },
                { ["name"] = "小号", ["class"] = "MAGE" },
            },
            ["note"] = "团长",
            ["lastUpdated"] = 1710700000,
        },
    },
    ["log"] = {
        {
            ["type"] = "award",
            ["player"] = "响当当",
            ["amount"] = 10,
            ["reason"] = "集合加分",
            ["timestamp"] = 1710700000,
            ["officer"] = "团长",
        },
        {
            ["type"] = "set",
            ["player"] = "响当当",
            ["amount"] = 150,
            ["reason"] = "CSV导入",
            ["timestamp"] = 1710700001,
            ["officer"] = "团长",
        },
    },
    ["options"] = { ["gatherPoints"] = 10 },
}
"#;
        let db = parse_saved_variables_str(lua).unwrap();
        assert_eq!(db.players.len(), 1);
        let p = db.players.get("响当当").unwrap();
        assert_eq!(p.dkp, 150.0);
        assert_eq!(p.characters.len(), 2);
        assert_eq!(p.characters[0].class, "WARRIOR");
        assert_eq!(p.note.as_deref(), Some("团长"));

        assert_eq!(db.log.len(), 2);
        assert_eq!(db.log[0].entry_type, "award");
        assert_eq!(db.log[1].entry_type, "set");
        assert!(db.options.is_some());
    }
}
