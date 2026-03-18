mod commands;
mod config;
mod kdocs;
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
            kdocs::webview::open_kdocs,
            kdocs::webview::close_kdocs,
            kdocs::webview::explore_kdocs_api,
            kdocs::webview::push_players_to_kdocs,
            kdocs::webview::push_log_to_kdocs,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
