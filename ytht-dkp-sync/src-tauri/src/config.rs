use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AppConfig {
    /// WoW installation directory
    #[serde(default)]
    pub wow_path: String,
    /// Game version directory name (e.g. "_retail_", "_classic_", "_classic_era_")
    #[serde(default)]
    pub game_version: String,
    /// Account folder name (e.g. "243775324#1")
    #[serde(default)]
    pub account_name: String,
    /// KDocs spreadsheet URL
    #[serde(default)]
    pub kdocs_url: String,
}

impl AppConfig {
    fn config_path() -> Result<PathBuf> {
        let config_dir = dirs::config_dir()
            .context("Cannot determine config directory")?
            .join("ytht-dkp-sync");
        std::fs::create_dir_all(&config_dir)?;
        Ok(config_dir.join("config.toml"))
    }

    pub fn load() -> Result<Self> {
        let path = Self::config_path()?;
        if path.exists() {
            let content = std::fs::read_to_string(&path)?;
            let config: AppConfig = toml::from_str(&content)?;
            Ok(config)
        } else {
            Ok(AppConfig::default())
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::config_path()?;
        let content = toml::to_string_pretty(self)?;
        std::fs::write(&path, content)?;
        Ok(())
    }

    /// Build the full path to the SavedVariables .lua file
    pub fn saved_variables_path(&self) -> Option<PathBuf> {
        if self.wow_path.is_empty() || self.game_version.is_empty() || self.account_name.is_empty()
        {
            return None;
        }
        let path = PathBuf::from(&self.wow_path)
            .join(&self.game_version)
            .join("WTF")
            .join("Account")
            .join(&self.account_name)
            .join("SavedVariables")
            .join("YTHT_DKP.lua");
        Some(path)
    }
}
