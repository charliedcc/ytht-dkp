use crate::model::DkpDatabase;
use chrono::{Local, TimeZone};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_clipboard_manager::ClipboardExt;

const KDOCS_WINDOW_LABEL: &str = "kdocs";

#[tauri::command]
pub async fn open_kdocs(app: AppHandle, url: String) -> Result<(), String> {
    eprintln!("[kdocs] open_kdocs called, url={}", url);

    // If already open, just focus
    if let Some(win) = app.get_webview_window(KDOCS_WINDOW_LABEL) {
        eprintln!("[kdocs] window already exists, focusing");
        win.set_focus().map_err(|e| e.to_string())?;
        return Ok(());
    }

    let parsed_url = url::Url::parse(&url).map_err(|e| format!("无效的URL: {e}"))?;
    WebviewWindowBuilder::new(&app, KDOCS_WINDOW_LABEL, WebviewUrl::External(parsed_url))
        .title("金山文档 - YTHT DKP")
        .inner_size(1280.0, 800.0)
        .build()
        .map_err(|e| {
            eprintln!("[kdocs] failed to build window: {}", e);
            e.to_string()
        })?;

    eprintln!("[kdocs] window created successfully");
    Ok(())
}

#[tauri::command]
pub async fn close_kdocs(app: AppHandle) -> Result<(), String> {
    eprintln!("[kdocs] close_kdocs called");
    if let Some(win) = app.get_webview_window(KDOCS_WINDOW_LABEL) {
        win.close().map_err(|e| e.to_string())?;
        eprintln!("[kdocs] window closed");
    } else {
        eprintln!("[kdocs] no window to close");
    }
    Ok(())
}

fn class_cn(c: &str) -> &str {
    match c {
        "WARRIOR" => "战士",
        "PALADIN" => "圣骑士",
        "HUNTER" => "猎人",
        "ROGUE" => "盗贼",
        "PRIEST" => "牧师",
        "DEATHKNIGHT" => "死亡骑士",
        "SHAMAN" => "萨满",
        "MAGE" => "法师",
        "WARLOCK" => "术士",
        "MONK" => "武僧",
        "DRUID" => "德鲁伊",
        "DEMONHUNTER" => "恶魔猎手",
        "EVOKER" => "唤魔师",
        _ => c,
    }
}

fn format_timestamp(ts: i64) -> String {
    if ts == 0 {
        return String::new();
    }
    Local
        .timestamp_opt(ts, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_default()
}

/// Escape a field for TSV (replace tabs and newlines with spaces)
fn tsv_escape(s: &str) -> String {
    s.replace('\t', " ").replace('\n', " ").replace('\r', "")
}

/// Copy player DKP data to clipboard as TSV
#[tauri::command]
pub async fn copy_players_tsv(app: AppHandle, db: DkpDatabase) -> Result<String, String> {
    eprintln!("[kdocs] copy_players_tsv called, players={}", db.players.len());

    let mut rows: Vec<String> = Vec::new();

    // Header
    rows.push("玩家名\tDKP\t角色列表\t备注\t最后更新".to_string());

    // Sort players by DKP descending
    let mut players: Vec<_> = db.players.iter().collect();
    players.sort_by(|a, b| {
        b.1.dkp
            .partial_cmp(&a.1.dkp)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    for (name, p) in &players {
        let chars = p
            .characters
            .iter()
            .map(|c| format!("{}({})", c.name, class_cn(&c.class)))
            .collect::<Vec<_>>()
            .join(", ");
        let note = p.note.as_deref().unwrap_or("");
        let updated = format_timestamp(p.last_updated.unwrap_or(0));

        rows.push(format!(
            "{}\t{}\t{}\t{}\t{}",
            tsv_escape(name),
            p.dkp,
            tsv_escape(&chars),
            tsv_escape(note),
            updated,
        ));
    }

    let tsv = rows.join("\n");
    app.clipboard()
        .write_text(&tsv)
        .map_err(|e| {
            eprintln!("[kdocs] clipboard write failed: {}", e);
            format!("复制到剪贴板失败: {e}")
        })?;

    let msg = format!("已复制 {} 名玩家数据到剪贴板", players.len());
    eprintln!("[kdocs] {}", msg);
    Ok(msg)
}

/// Copy DKP log entries to clipboard as TSV
#[tauri::command]
pub async fn copy_log_tsv(app: AppHandle, db: DkpDatabase) -> Result<String, String> {
    eprintln!("[kdocs] copy_log_tsv called, log_entries={}", db.log.len());

    let mut rows: Vec<String> = Vec::new();

    // Header
    rows.push("时间\t类型\t玩家\t数额\t原因\t操作者\t已冲红".to_string());

    for entry in &db.log {
        let type_name = match entry.entry_type.as_str() {
            "award" => "加分",
            "deduct" => "扣分",
            "set" => "设置",
            "reverse" => "冲红",
            other => other,
        };
        let amount_str = if entry.entry_type == "set" {
            format!("={}", entry.amount)
        } else if entry.amount >= 0.0 {
            format!("+{}", entry.amount)
        } else {
            format!("{}", entry.amount)
        };
        let reversed = if entry.reversed.unwrap_or(false) {
            "是"
        } else {
            ""
        };

        rows.push(format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}",
            format_timestamp(entry.timestamp),
            type_name,
            tsv_escape(&entry.player),
            amount_str,
            tsv_escape(&entry.reason),
            tsv_escape(&entry.officer),
            reversed,
        ));
    }

    let tsv = rows.join("\n");
    app.clipboard()
        .write_text(&tsv)
        .map_err(|e| {
            eprintln!("[kdocs] clipboard write failed: {}", e);
            format!("复制到剪贴板失败: {e}")
        })?;

    let msg = format!("已复制 {} 条操作记录到剪贴板", db.log.len());
    eprintln!("[kdocs] {}", msg);
    Ok(msg)
}
