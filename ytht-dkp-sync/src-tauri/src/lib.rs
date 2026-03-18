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
        .plugin(tauri_plugin_clipboard_manager::init())
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
            kdocs::webview::copy_players_tsv,
            kdocs::webview::copy_log_tsv,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
