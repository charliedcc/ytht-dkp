use crate::model::DkpDatabase;
use chrono::{Local, TimeZone};
use regex::Regex;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const KDOCS_WINDOW_LABEL: &str = "kdocs";

// ── WoW class colors ──

fn class_color(class: &str) -> &'static str {
    match class {
        "WARRIOR" => "#C79C6E",
        "PALADIN" => "#F58CBA",
        "HUNTER" => "#ABD473",
        "ROGUE" => "#FFF569",
        "PRIEST" => "#FFFFFF",
        "DEATHKNIGHT" => "#C41F3B",
        "SHAMAN" => "#0070DE",
        "MAGE" => "#69CCF0",
        "WARLOCK" => "#9482C9",
        "MONK" => "#00FF96",
        "DRUID" => "#FF7D0A",
        "DEMONHUNTER" => "#A330C9",
        "EVOKER" => "#33937F",
        _ => "#CCCCCC",
    }
}

fn class_cn(class: &str) -> &'static str {
    match class {
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
        _ => "未知",
    }
}

// ── WoW item link parsing ──

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Parse WoW item params to extract (item_id, bonus_ids)
/// Format: itemID:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:spec:upgradeType:difficulty:numBonus:bonus1:bonus2:...
fn parse_item_params(params: &str) -> (u64, Vec<u64>) {
    let parts: Vec<&str> = params.split(':').collect();
    let item_id = parts
        .first()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);

    let num_bonus = parts
        .get(12)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);

    let bonus_ids: Vec<u64> = (0..num_bonus)
        .filter_map(|i| parts.get(13 + i).and_then(|s| s.parse::<u64>().ok()))
        .collect();

    (item_id, bonus_ids)
}

fn wowhead_url(item_id: u64, bonus_ids: &[u64]) -> String {
    let mut url = format!("https://cn.wowhead.com/item={}", item_id);
    if !bonus_ids.is_empty() {
        let bonus_str: String = bonus_ids
            .iter()
            .map(|b| b.to_string())
            .collect::<Vec<_>>()
            .join(":");
        url.push_str(&format!("&bonus={}", bonus_str));
    }
    url
}

/// Process text that may contain WoW item links.
/// Returns (html_version, plain_text_version).
///
/// Item link pattern: |c...|Hitem:PARAMS|h[ItemName]|h|r
fn process_item_links(text: &str) -> (String, String) {
    let re = Regex::new(r"\|c[^|]*\|Hitem:([^|]+)\|h\[([^\]]+)\]\|h\|r").unwrap();

    let mut html = String::new();
    let mut plain = String::new();
    let mut last_end = 0;

    for cap in re.captures_iter(text) {
        let m = cap.get(0).unwrap();

        // Text before this match
        let before = &text[last_end..m.start()];
        html.push_str(&html_escape(before));
        plain.push_str(before);

        let item_params = &cap[1];
        let item_name = &cap[2];
        let (item_id, bonus_ids) = parse_item_params(item_params);
        let url = wowhead_url(item_id, &bonus_ids);

        html.push_str(&format!(
            "<a href=\"{}\" style=\"color:#a335ee\">[{}]</a>",
            html_escape(&url),
            html_escape(item_name)
        ));
        plain.push_str(&format!("[{}]", item_name));

        last_end = m.end();
    }

    // Remaining text after last match
    let remaining = &text[last_end..];
    html.push_str(&html_escape(remaining));
    plain.push_str(remaining);

    (html, plain)
}

// ── Timestamp formatting ──

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

/// TSV-escape: replace tabs/newlines
fn tsv_escape(s: &str) -> String {
    s.replace('\t', " ").replace('\n', " ").replace('\r', "")
}

// ── Clipboard helper ──

fn set_clipboard_html(html: &str, plain: &str) -> Result<(), String> {
    let mut clipboard = arboard::Clipboard::new().map_err(|e| format!("无法打开剪贴板: {e}"))?;
    clipboard
        .set_html(html, Some(plain))
        .map_err(|e| format!("写入剪贴板失败: {e}"))?;
    Ok(())
}

// ── KDocs window management ──

#[tauri::command]
pub async fn open_kdocs(app: AppHandle, url: String) -> Result<(), String> {
    eprintln!("[kdocs] open_kdocs called, url={}", url);

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

// ── Clipboard copy commands ──

/// Copy player DKP data to clipboard as rich text (HTML table with class colors)
#[tauri::command]
pub async fn copy_players_tsv(db: DkpDatabase) -> Result<String, String> {
    eprintln!(
        "[kdocs] copy_players_tsv called, players={}",
        db.players.len()
    );

    // Sort players by DKP descending
    let mut players: Vec<_> = db.players.iter().collect();
    players.sort_by(|a, b| {
        b.1.dkp
            .partial_cmp(&a.1.dkp)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // ── Build HTML table ──
    let mut html = String::from(
        "<table><tr>\
         <th>玩家名</th><th>DKP</th><th>角色列表</th><th>备注</th><th>最后更新</th>\
         </tr>",
    );

    // ── Build plain text TSV ──
    let mut tsv_rows: Vec<String> = vec!["玩家名\tDKP\t角色列表\t备注\t最后更新".to_string()];

    for (name, p) in &players {
        // Characters with class colors (HTML)
        let chars_html: String = p
            .characters
            .iter()
            .map(|c| {
                format!(
                    "<span style=\"color:{}\">{}({})</span>",
                    class_color(&c.class),
                    html_escape(&c.name),
                    class_cn(&c.class)
                )
            })
            .collect::<Vec<_>>()
            .join(", ");

        // Characters plain text
        let chars_plain: String = p
            .characters
            .iter()
            .map(|c| format!("{}({})", c.name, class_cn(&c.class)))
            .collect::<Vec<_>>()
            .join(", ");

        let note = p.note.as_deref().unwrap_or("");
        let updated = format_timestamp(p.last_updated.unwrap_or(0));

        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            html_escape(name),
            p.dkp,
            chars_html,
            html_escape(note),
            updated,
        ));

        tsv_rows.push(format!(
            "{}\t{}\t{}\t{}\t{}",
            tsv_escape(name),
            p.dkp,
            tsv_escape(&chars_plain),
            tsv_escape(note),
            updated,
        ));
    }

    html.push_str("</table>");
    let tsv = tsv_rows.join("\n");

    set_clipboard_html(&html, &tsv)?;

    let msg = format!("已复制 {} 名玩家数据到剪贴板", players.len());
    eprintln!("[kdocs] {}", msg);
    Ok(msg)
}

/// Copy DKP log entries to clipboard as rich text (HTML table with item links)
#[tauri::command]
pub async fn copy_log_tsv(db: DkpDatabase) -> Result<String, String> {
    eprintln!(
        "[kdocs] copy_log_tsv called, log_entries={}",
        db.log.len()
    );

    // ── Build HTML table ──
    let mut html = String::from(
        "<table><tr>\
         <th>时间</th><th>类型</th><th>玩家</th><th>数额</th><th>原因</th><th>操作者</th><th>已冲红</th>\
         </tr>",
    );

    // ── Build plain text TSV ──
    let mut tsv_rows: Vec<String> =
        vec!["时间\t类型\t玩家\t数额\t原因\t操作者\t已冲红".to_string()];

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
        let ts = format_timestamp(entry.timestamp);

        // Process item links in reason field
        let (reason_html, reason_plain) = process_item_links(&entry.reason);

        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            ts,
            type_name,
            html_escape(&entry.player),
            html_escape(&amount_str),
            reason_html,
            html_escape(&entry.officer),
            reversed,
        ));

        tsv_rows.push(format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}",
            ts,
            type_name,
            tsv_escape(&entry.player),
            amount_str,
            tsv_escape(&reason_plain),
            tsv_escape(&entry.officer),
            reversed,
        ));
    }

    html.push_str("</table>");
    let tsv = tsv_rows.join("\n");

    set_clipboard_html(&html, &tsv)?;

    let msg = format!("已复制 {} 条操作记录到剪贴板", db.log.len());
    eprintln!("[kdocs] {}", msg);
    Ok(msg)
}
