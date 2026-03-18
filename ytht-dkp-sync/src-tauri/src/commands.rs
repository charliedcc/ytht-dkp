use crate::config::AppConfig;
use crate::model::DkpDatabase;
use crate::savedvariables::{parser, writer};
use std::path::PathBuf;

/// Load config from disk
#[tauri::command]
pub fn get_config() -> Result<AppConfig, String> {
    AppConfig::load().map_err(|e| e.to_string())
}

/// Save config to disk
#[tauri::command]
pub fn save_config(config: AppConfig) -> Result<(), String> {
    config.save().map_err(|e| e.to_string())
}

/// Load DKP data from SavedVariables file
#[tauri::command]
pub fn load_dkp(config: AppConfig) -> Result<DkpDatabase, String> {
    let path = config
        .saved_variables_path()
        .ok_or("WoW path, game version, or account name not configured")?;

    if !path.exists() {
        return Err(format!("SavedVariables file not found: {}", path.display()));
    }

    parser::parse_saved_variables(&path).map_err(|e| e.to_string())
}

/// Save DKP data back to SavedVariables file
#[tauri::command]
pub fn save_dkp(config: AppConfig, db: DkpDatabase) -> Result<(), String> {
    let path = config
        .saved_variables_path()
        .ok_or("WoW path, game version, or account name not configured")?;

    let json_value = serde_json::to_value(&db).map_err(|e| e.to_string())?;
    writer::write_saved_variables(&path, &json_value).map_err(|e| e.to_string())
}

/// Scan WoW directory for available game versions (_retail_, _classic_, etc.)
#[tauri::command]
pub fn list_game_versions(wow_path: String) -> Result<Vec<GameVersion>, String> {
    let base = PathBuf::from(&wow_path);
    if !base.exists() {
        return Err(format!("Directory not found: {}", base.display()));
    }

    let known_versions = [
        ("_retail_", "正式服"),
        ("_classic_", "经典服"),
        ("_classic_era_", "经典旧世"),
        ("_ptr_", "PTR"),
        ("_beta_", "Beta"),
    ];

    let mut versions = Vec::new();
    for (dir_name, label) in &known_versions {
        let dir = base.join(dir_name);
        if dir.is_dir() {
            // Check if WTF/Account exists inside to confirm it's a valid installation
            let wtf = dir.join("WTF").join("Account");
            versions.push(GameVersion {
                dir_name: dir_name.to_string(),
                label: label.to_string(),
                has_wtf: wtf.is_dir(),
            });
        }
    }

    Ok(versions)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct GameVersion {
    pub dir_name: String,
    pub label: String,
    pub has_wtf: bool,
}

/// List available account folders under WTF/Account for a given game version
#[tauri::command]
pub fn list_accounts(wow_path: String, game_version: String) -> Result<Vec<String>, String> {
    let wtf_path = PathBuf::from(&wow_path)
        .join(&game_version)
        .join("WTF")
        .join("Account");

    if !wtf_path.exists() {
        return Err(format!(
            "WTF/Account directory not found: {}",
            wtf_path.display()
        ));
    }

    let mut accounts = Vec::new();
    let entries = std::fs::read_dir(&wtf_path).map_err(|e| e.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
            let name = entry.file_name().to_string_lossy().to_string();
            // Skip special directories
            if name != "SavedVariables" && !name.starts_with('.') {
                accounts.push(name);
            }
        }
    }
    accounts.sort();
    Ok(accounts)
}

/// Check if SavedVariables file exists at the configured path
#[tauri::command]
pub fn check_sv_path(config: AppConfig) -> Result<String, String> {
    match config.saved_variables_path() {
        Some(path) => {
            if path.exists() {
                Ok(path.display().to_string())
            } else {
                Err(format!("File not found: {}", path.display()))
            }
        }
        None => Err("WoW path, game version, or account name not configured".to_string()),
    }
}
