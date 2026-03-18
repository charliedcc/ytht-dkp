use serde::{Deserialize, Deserializer, Serialize};
use std::collections::HashMap;

/// Deserialize a Vec that also accepts an empty object {} as empty vec
/// (Lua empty table {} becomes JSON {} not [])
fn vec_or_empty_object<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: for<'a> Deserialize<'a>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    match value {
        serde_json::Value::Array(arr) => {
            let v: Vec<T> = arr
                .into_iter()
                .map(|v| serde_json::from_value(v).map_err(serde::de::Error::custom))
                .collect::<Result<_, _>>()?;
            Ok(v)
        }
        serde_json::Value::Object(map) if map.is_empty() => Ok(Vec::new()),
        _ => Err(serde::de::Error::custom("expected array or empty object")),
    }
}

/// Top-level database matching YTHT_DKP_DB in SavedVariables
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DkpDatabase {
    #[serde(default)]
    pub players: HashMap<String, PlayerData>,
    #[serde(default, deserialize_with = "vec_or_empty_object")]
    pub log: Vec<LogEntry>,
    // Passthrough fields - preserved on round-trip, not modified by sync tool
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sheets: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub point: Option<serde_json::Value>,
    #[serde(default, rename = "currentSheet", skip_serializing_if = "Option::is_none")]
    pub current_sheet: Option<String>,
    #[serde(default, rename = "auctionHistory", skip_serializing_if = "Option::is_none")]
    pub auction_history: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerData {
    #[serde(default)]
    pub dkp: f64,
    #[serde(default, deserialize_with = "vec_or_empty_object")]
    pub characters: Vec<Character>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, rename = "lastUpdated", skip_serializing_if = "Option::is_none")]
    pub last_updated: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Character {
    pub name: String,
    #[serde(default = "default_class")]
    pub class: String,
}

fn default_class() -> String {
    "WARRIOR".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogEntry {
    #[serde(rename = "type")]
    pub entry_type: String,
    #[serde(default)]
    pub player: String,
    #[serde(default)]
    pub amount: f64,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub timestamp: i64,
    #[serde(default)]
    pub officer: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reversed: Option<bool>,
    #[serde(default, rename = "reversedIndex", skip_serializing_if = "Option::is_none")]
    pub reversed_index: Option<usize>,
}
