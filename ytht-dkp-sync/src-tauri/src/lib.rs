mod commands;
mod config;
mod model;
mod savedvariables;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_config,
            commands::save_config,
            commands::load_dkp,
            commands::save_dkp,
            commands::list_game_versions,
            commands::list_accounts,
            commands::check_sv_path,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
