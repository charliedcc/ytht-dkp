use crate::model::DkpDatabase;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const KDOCS_WINDOW_LABEL: &str = "kdocs";

/// Helper JS to show a floating overlay message (since alert() is often blocked by KDocs)
fn overlay_js(id: &str) -> String {
    format!(
        r#"
function __ytht_show_msg(msg, isError) {{
    var existing = document.getElementById('{id}');
    if (existing) existing.remove();
    var div = document.createElement('div');
    div.id = '{id}';
    div.style.cssText = 'position:fixed;top:20px;right:20px;max-width:600px;max-height:80vh;overflow:auto;' +
        'background:' + (isError ? '#2d1b1b' : '#1b2d1b') + ';color:#e0e0e0;' +
        'border:2px solid ' + (isError ? '#ff4444' : '#44ff44') + ';' +
        'border-radius:8px;padding:16px;z-index:2147483647;font-family:monospace;font-size:13px;' +
        'white-space:pre-wrap;box-shadow:0 4px 24px rgba(0,0,0,0.5);';
    var close = document.createElement('div');
    close.textContent = '✕ 关闭';
    close.style.cssText = 'cursor:pointer;text-align:right;color:#aaa;margin-bottom:8px;font-size:12px;';
    close.onclick = function() {{ div.remove(); }};
    div.appendChild(close);
    var content = document.createElement('div');
    content.textContent = msg;
    div.appendChild(content);
    document.body.appendChild(div);
    // Auto-dismiss after 30 seconds
    setTimeout(function() {{ if (div.parentNode) div.remove(); }}, 30000);
}}
"#,
        id = id
    )
}

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

/// Inject JS to explore what APIs are available in the KDocs page
#[tauri::command]
pub async fn explore_kdocs_api(app: AppHandle) -> Result<(), String> {
    eprintln!("[kdocs] explore_kdocs_api called");

    let win = app
        .get_webview_window(KDOCS_WINDOW_LABEL)
        .ok_or_else(|| {
            eprintln!("[kdocs] ERROR: kdocs window not found");
            "请先打开金山文档窗口".to_string()
        })?;

    let overlay = overlay_js("__ytht_explore_overlay");
    let js = format!(
        r#"
(function() {{
    {overlay}

    try {{
        var info = [];
        info.push('=== 金山文档 API 探索 ===');
        info.push('');

        info.push('[全局对象检测]');
        info.push('window.Application: ' + typeof window.Application);
        info.push('window.application: ' + typeof window.application);

        var app = window.Application || window.application;

        if (app) {{
            info.push('');
            info.push('[Application 对象]');
            try {{
                var keys = Object.getOwnPropertyNames(app).slice(0, 30);
                info.push('属性: ' + keys.join(', '));
            }} catch(e) {{
                info.push('获取属性失败: ' + e.message);
            }}

            try {{
                var wb = app.ActiveWorkbook;
                if (wb) {{
                    info.push('');
                    info.push('[工作簿]');
                    info.push('ActiveWorkbook: 存在');

                    var sheet = wb.ActiveSheet;
                    if (sheet) {{
                        info.push('');
                        info.push('[活动工作表]');
                        info.push('Name: ' + (sheet.Name || '未知'));
                        try {{
                            var sheetKeys = Object.getOwnPropertyNames(sheet).slice(0, 30);
                            info.push('属性: ' + sheetKeys.join(', '));
                        }} catch(e) {{}}

                        // Try reading A1
                        try {{
                            var cell = sheet.Range('A1');
                            var val = cell.Value2 !== undefined ? cell.Value2 : cell.Value;
                            info.push('');
                            info.push('[单元格测试 A1]');
                            info.push('Value: ' + JSON.stringify(val));
                        }} catch(e) {{
                            info.push('读取A1失败: ' + e.message);
                        }}

                        // Try writing a test value
                        try {{
                            sheet.Range('A1').Value2 = 'API测试';
                            info.push('写入A1测试: 成功 (值: API测试)');
                        }} catch(e) {{
                            info.push('写入A1失败: ' + e.message);
                        }}
                    }} else {{
                        info.push('ActiveSheet: 不存在');
                    }}

                    // Sheet count
                    try {{
                        if (wb.Sheets) {{
                            info.push('');
                            info.push('[工作表列表]');
                            var count = wb.Sheets.Count;
                            info.push('数量: ' + count);
                            for (var i = 1; i <= Math.min(count, 10); i++) {{
                                info.push('  Sheet ' + i + ': ' + wb.Sheets.Item(i).Name);
                            }}
                        }}
                    }} catch(e) {{
                        info.push('获取工作表列表失败: ' + e.message);
                    }}
                }} else {{
                    info.push('ActiveWorkbook: 不存在');
                }}
            }} catch(e) {{
                info.push('工作簿探索错误: ' + e.message);
            }}
        }} else {{
            info.push('');
            info.push('未找到 Application 对象，搜索其他全局变量...');
            var relevant = Object.keys(window).filter(function(k) {{
                var kl = k.toLowerCase();
                return (kl.includes('app') || kl.includes('sheet') ||
                        kl.includes('book') || kl.includes('cell') ||
                        kl.includes('wps') || kl.includes('kdoc') ||
                        kl.includes('editor') || kl.includes('spread')) &&
                       !kl.startsWith('webkit') && !kl.startsWith('__');
            }});
            info.push('相关变量: ' + (relevant.length > 0 ? relevant.join(', ') : '(无)'));
        }}

        console.log('[YTHT-DKP]', info.join('\n'));
        __ytht_show_msg(info.join('\n'), false);
    }} catch(e) {{
        var errMsg = '探索失败: ' + e.message + '\n' + e.stack;
        console.error('[YTHT-DKP]', errMsg);
        __ytht_show_msg(errMsg, true);
    }}
}})();
"#,
        overlay = overlay
    );

    win.eval(&js).map_err(|e| {
        eprintln!("[kdocs] eval failed: {}", e);
        e.to_string()
    })?;
    eprintln!("[kdocs] explore JS injected successfully");
    Ok(())
}

/// Push player DKP data to a KDocs sheet
#[tauri::command]
pub async fn push_players_to_kdocs(
    app: AppHandle,
    db: DkpDatabase,
    sheet_index: usize,
) -> Result<(), String> {
    eprintln!(
        "[kdocs] push_players_to_kdocs called, sheet_index={}, players={}",
        sheet_index,
        db.players.len()
    );

    let win = app
        .get_webview_window(KDOCS_WINDOW_LABEL)
        .ok_or_else(|| {
            eprintln!("[kdocs] ERROR: kdocs window not found");
            "请先打开金山文档窗口".to_string()
        })?;

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

    // Sort players by DKP descending
    let mut players: Vec<_> = db.players.iter().collect();
    players.sort_by(|a, b| {
        b.1.dkp
            .partial_cmp(&a.1.dkp)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let data: Vec<serde_json::Value> = players
        .iter()
        .map(|(name, p)| {
            let chars = p
                .characters
                .iter()
                .map(|c| format!("{}({})", c.name, class_cn(&c.class)))
                .collect::<Vec<_>>()
                .join(",");
            serde_json::json!({
                "name": name,
                "dkp": p.dkp,
                "characters": chars,
                "note": p.note.as_deref().unwrap_or(""),
                "lastUpdated": p.last_updated.unwrap_or(0),
            })
        })
        .collect();

    let data_json = serde_json::to_string(&data).map_err(|e| e.to_string())?;

    let overlay = overlay_js("__ytht_push_overlay");
    let js = format!(
        r#"
(function() {{
    {overlay}

    try {{
        var app = window.Application || window.application;
        if (!app) throw new Error('未找到 Application API，请确保文档已完全加载');

        var wb = app.ActiveWorkbook;
        if (!wb) throw new Error('未找到工作簿');

        var sheet = wb.Sheets.Item({sheet_idx});
        if (!sheet) throw new Error('未找到工作表 #{sheet_idx}');

        var data = {data_json};

        // Write headers
        var headers = ['玩家名', 'DKP', '角色列表', '备注', '最后更新'];
        for (var c = 0; c < headers.length; c++) {{
            sheet.Cells(1, c + 1).Value2 = headers[c];
        }}

        // Write data rows
        for (var i = 0; i < data.length; i++) {{
            var row = i + 2;
            sheet.Cells(row, 1).Value2 = data[i].name;
            sheet.Cells(row, 2).Value2 = data[i].dkp;
            sheet.Cells(row, 3).Value2 = data[i].characters;
            sheet.Cells(row, 4).Value2 = data[i].note;
            if (data[i].lastUpdated > 0) {{
                var d = new Date(data[i].lastUpdated * 1000);
                sheet.Cells(row, 5).Value2 = d.toLocaleString('zh-CN');
            }}
        }}

        var msg = '成功写入 ' + data.length + ' 名玩家数据到工作表「' + sheet.Name + '」';
        console.log('[YTHT-DKP]', msg);
        __ytht_show_msg(msg, false);
    }} catch(e) {{
        var errMsg = '写入失败: ' + e.message;
        console.error('[YTHT-DKP]', errMsg);
        __ytht_show_msg(errMsg, true);
    }}
}})();
"#,
        overlay = overlay,
        sheet_idx = sheet_index,
        data_json = data_json,
    );

    win.eval(&js).map_err(|e| {
        eprintln!("[kdocs] eval failed: {}", e);
        e.to_string()
    })?;
    eprintln!("[kdocs] push_players JS injected successfully");
    Ok(())
}

/// Push DKP log entries to a KDocs sheet
#[tauri::command]
pub async fn push_log_to_kdocs(
    app: AppHandle,
    db: DkpDatabase,
    sheet_index: usize,
) -> Result<(), String> {
    eprintln!(
        "[kdocs] push_log_to_kdocs called, sheet_index={}, log_entries={}",
        sheet_index,
        db.log.len()
    );

    let win = app
        .get_webview_window(KDOCS_WINDOW_LABEL)
        .ok_or_else(|| {
            eprintln!("[kdocs] ERROR: kdocs window not found");
            "请先打开金山文档窗口".to_string()
        })?;

    let data: Vec<serde_json::Value> = db
        .log
        .iter()
        .map(|entry| {
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
            serde_json::json!({
                "timestamp": entry.timestamp,
                "type": type_name,
                "player": entry.player,
                "amount": amount_str,
                "reason": entry.reason,
                "officer": entry.officer,
                "reversed": entry.reversed.unwrap_or(false),
            })
        })
        .collect();

    let data_json = serde_json::to_string(&data).map_err(|e| e.to_string())?;

    let overlay = overlay_js("__ytht_push_overlay");
    let js = format!(
        r#"
(function() {{
    {overlay}

    try {{
        var app = window.Application || window.application;
        if (!app) throw new Error('未找到 Application API，请确保文档已完全加载');

        var wb = app.ActiveWorkbook;
        if (!wb) throw new Error('未找到工作簿');

        var sheet = wb.Sheets.Item({sheet_idx});
        if (!sheet) throw new Error('未找到工作表 #{sheet_idx}');

        var data = {data_json};

        // Write headers
        var headers = ['时间', '类型', '玩家', '数额', '原因', '操作者', '已冲红'];
        for (var c = 0; c < headers.length; c++) {{
            sheet.Cells(1, c + 1).Value2 = headers[c];
        }}

        // Write data rows
        for (var i = 0; i < data.length; i++) {{
            var row = i + 2;
            if (data[i].timestamp > 0) {{
                var d = new Date(data[i].timestamp * 1000);
                sheet.Cells(row, 1).Value2 = d.toLocaleString('zh-CN');
            }}
            sheet.Cells(row, 2).Value2 = data[i].type;
            sheet.Cells(row, 3).Value2 = data[i].player;
            sheet.Cells(row, 4).Value2 = data[i].amount;
            sheet.Cells(row, 5).Value2 = data[i].reason;
            sheet.Cells(row, 6).Value2 = data[i].officer;
            sheet.Cells(row, 7).Value2 = data[i].reversed ? '是' : '';
        }}

        var msg = '成功写入 ' + data.length + ' 条操作记录到工作表「' + sheet.Name + '」';
        console.log('[YTHT-DKP]', msg);
        __ytht_show_msg(msg, false);
    }} catch(e) {{
        var errMsg = '写入失败: ' + e.message;
        console.error('[YTHT-DKP]', errMsg);
        __ytht_show_msg(errMsg, true);
    }}
}})();
"#,
        overlay = overlay,
        sheet_idx = sheet_index,
        data_json = data_json,
    );

    win.eval(&js).map_err(|e| {
        eprintln!("[kdocs] eval failed: {}", e);
        e.to_string()
    })?;
    eprintln!("[kdocs] push_log JS injected successfully");
    Ok(())
}
