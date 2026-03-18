import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

interface Character {
  name: string;
  class: string;
}

interface PlayerData {
  dkp: number;
  characters: Character[];
  note?: string;
  lastUpdated?: number;
}

interface LogEntry {
  type: string;
  player: string;
  amount: number;
  reason: string;
  timestamp: number;
  officer: string;
  reversed?: boolean;
  reversedIndex?: number;
}

interface DkpDatabase {
  players: Record<string, PlayerData>;
  log: LogEntry[];
}

interface GameVersion {
  dir_name: string;
  label: string;
  has_wtf: boolean;
}

interface AppConfig {
  wow_path: string;
  game_version: string;
  account_name: string;
  kdocs_url: string;
}

const CLASS_COLORS: Record<string, string> = {
  WARRIOR: "#C79C6E", PALADIN: "#F58CBA", HUNTER: "#ABD473",
  ROGUE: "#FFF569", PRIEST: "#FFFFFF", DEATHKNIGHT: "#C41F3B",
  SHAMAN: "#0070DE", MAGE: "#69CCF0", WARLOCK: "#9482C9",
  MONK: "#00FF96", DRUID: "#FF7D0A", DEMONHUNTER: "#A330C9",
  EVOKER: "#33937F",
};

const CLASS_NAMES: Record<string, string> = {
  WARRIOR: "战士", PALADIN: "圣骑士", HUNTER: "猎人",
  ROGUE: "盗贼", PRIEST: "牧师", DEATHKNIGHT: "死亡骑士",
  SHAMAN: "萨满", MAGE: "法师", WARLOCK: "术士",
  MONK: "武僧", DRUID: "德鲁伊", DEMONHUNTER: "恶魔猎手",
  EVOKER: "唤魔师",
};

const TYPE_NAMES: Record<string, string> = {
  award: "加分", deduct: "扣分", set: "设置", reverse: "冲红",
};

type TabKey = "config" | "players" | "log" | "kdocs";

function App() {
  const [tab, setTab] = useState<TabKey>("config");
  const [config, setConfig] = useState<AppConfig>({ wow_path: "", game_version: "", account_name: "", kdocs_url: "" });
  const [db, setDb] = useState<DkpDatabase | null>(null);
  const [gameVersions, setGameVersions] = useState<GameVersion[]>([]);
  const [accounts, setAccounts] = useState<string[]>([]);
  const [status, setStatus] = useState("");
  const [svPath, setSvPath] = useState("");

  useEffect(() => {
    invoke<AppConfig>("get_config").then(setConfig).catch(() => {});
  }, []);

  // Scan game versions when wow_path changes
  useEffect(() => {
    if (config.wow_path) {
      invoke<GameVersion[]>("list_game_versions", { wowPath: config.wow_path })
        .then((versions) => {
          setGameVersions(versions);
          // Auto-select if only one version with WTF
          const withWtf = versions.filter((v) => v.has_wtf);
          if (withWtf.length === 1 && !config.game_version) {
            setConfig((c) => ({ ...c, game_version: withWtf[0].dir_name }));
          }
        })
        .catch(() => setGameVersions([]));
    } else {
      setGameVersions([]);
    }
  }, [config.wow_path]);

  // Scan accounts when game_version changes
  useEffect(() => {
    if (config.wow_path && config.game_version) {
      invoke<string[]>("list_accounts", { wowPath: config.wow_path, gameVersion: config.game_version })
        .then((accs) => {
          setAccounts(accs);
          // Auto-select if only one account
          if (accs.length === 1 && !config.account_name) {
            setConfig((c) => ({ ...c, account_name: accs[0] }));
          }
        })
        .catch(() => setAccounts([]));
    } else {
      setAccounts([]);
    }
  }, [config.wow_path, config.game_version]);

  // Check SV path when account changes
  useEffect(() => {
    if (config.wow_path && config.game_version && config.account_name) {
      invoke<string>("check_sv_path", { config })
        .then(setSvPath)
        .catch((e) => setSvPath(`未找到: ${e}`));
    } else {
      setSvPath("");
    }
  }, [config.wow_path, config.game_version, config.account_name]);

  const handleSaveConfig = async () => {
    try {
      await invoke("save_config", { config });
      setStatus("配置已保存");
    } catch (e) {
      setStatus(`保存失败: ${e}`);
    }
  };

  const handleLoadDkp = async () => {
    try {
      const data = await invoke<DkpDatabase>("load_dkp", { config });
      setDb(data);
      const n = Object.keys(data.players).length;
      setStatus(`已加载: ${n} 名玩家, ${data.log.length} 条记录`);
      setTab("players");
    } catch (e) {
      setStatus(`加载失败: ${e}`);
    }
  };

  const sortedPlayers = db
    ? Object.entries(db.players).sort(([, a], [, b]) => b.dkp - a.dkp)
    : [];

  const formatTime = (ts: number) => {
    if (!ts) return "-";
    return new Date(ts * 1000).toLocaleString("zh-CN", {
      month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
    });
  };

  return (
    <div className="app">
      <header className="header">
        <h1>YTHT DKP Sync</h1>
        <nav className="tabs">
          <button className={tab === "config" ? "active" : ""} onClick={() => setTab("config")}>配置</button>
          <button className={tab === "players" ? "active" : ""} onClick={() => setTab("players")}>DKP 数据</button>
          <button className={tab === "log" ? "active" : ""} onClick={() => setTab("log")}>操作记录</button>
          <button className={tab === "kdocs" ? "active" : ""} onClick={() => setTab("kdocs")}>金山文档</button>
        </nav>
      </header>

      {status && <div className="status-bar">{status}</div>}

      <main className="content">
        {tab === "config" && (
          <div className="config-panel">
            <div className="form-group">
              <label>WoW 安装目录</label>
              <input
                type="text"
                value={config.wow_path}
                onChange={(e) => setConfig({ ...config, wow_path: e.target.value, game_version: "", account_name: "" })}
                placeholder="例: C:\Program Files (x86)\World of Warcraft"
              />
            </div>
            <div className="form-group">
              <label>游戏版本</label>
              {gameVersions.length > 0 ? (
                <select
                  value={config.game_version}
                  onChange={(e) => setConfig({ ...config, game_version: e.target.value, account_name: "" })}
                >
                  <option value="">-- 选择版本 --</option>
                  {gameVersions.map((v) => (
                    <option key={v.dir_name} value={v.dir_name} disabled={!v.has_wtf}>
                      {v.label} ({v.dir_name}){!v.has_wtf ? " - 无WTF数据" : ""}
                    </option>
                  ))}
                </select>
              ) : (
                <div className="sv-path">{config.wow_path ? "未检测到游戏版本" : "请先填写 WoW 目录"}</div>
              )}
            </div>
            <div className="form-group">
              <label>账号</label>
              {accounts.length > 0 ? (
                <select
                  value={config.account_name}
                  onChange={(e) => setConfig({ ...config, account_name: e.target.value })}
                >
                  <option value="">-- 选择账号 --</option>
                  {accounts.map((a) => <option key={a} value={a}>{a}</option>)}
                </select>
              ) : (
                <div className="sv-path">{config.game_version ? "未找到账号文件夹" : "请先选择游戏版本"}</div>
              )}
            </div>
            <div className="form-group">
              <label>SavedVariables 路径</label>
              <div className="sv-path">{svPath || "请先完成上述配置"}</div>
            </div>
            <div className="form-group">
              <label>金山文档 URL</label>
              <input
                type="text"
                value={config.kdocs_url}
                onChange={(e) => setConfig({ ...config, kdocs_url: e.target.value })}
                placeholder="https://www.kdocs.cn/l/..."
              />
            </div>
            <div className="button-row">
              <button className="btn-primary" onClick={handleSaveConfig}>保存配置</button>
              <button className="btn-primary" onClick={handleLoadDkp}>加载 DKP 数据</button>
            </div>
          </div>
        )}

        {tab === "players" && (
          <div className="players-panel">
            <div className="toolbar">
              <span className="count">{sortedPlayers.length} 名玩家</span>
              <button className="btn-primary" onClick={handleLoadDkp}>刷新</button>
            </div>
            <table className="data-table">
              <thead>
                <tr>
                  <th style={{ width: 40 }}>#</th>
                  <th style={{ width: 120 }}>玩家名</th>
                  <th style={{ width: 80 }}>DKP</th>
                  <th>角色列表</th>
                  <th style={{ width: 100 }}>最后更新</th>
                </tr>
              </thead>
              <tbody>
                {sortedPlayers.map(([name, data], i) => (
                  <tr key={name} className={i % 2 === 0 ? "even" : "odd"}>
                    <td>{i + 1}</td>
                    <td className="player-name">{name}</td>
                    <td className="dkp-value">{data.dkp}</td>
                    <td>
                      {data.characters.map((c) => (
                        <span key={c.name} style={{ color: CLASS_COLORS[c.class] || "#ccc", marginRight: 8 }}>
                          {c.name}({CLASS_NAMES[c.class] || c.class})
                        </span>
                      ))}
                    </td>
                    <td className="timestamp">{formatTime(data.lastUpdated || 0)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {tab === "log" && (
          <div className="log-panel">
            <div className="toolbar">
              <span className="count">{db?.log.length || 0} 条记录</span>
            </div>
            <table className="data-table">
              <thead>
                <tr>
                  <th style={{ width: 40 }}>#</th>
                  <th style={{ width: 110 }}>时间</th>
                  <th style={{ width: 60 }}>类型</th>
                  <th style={{ width: 100 }}>玩家</th>
                  <th style={{ width: 80 }}>数额</th>
                  <th>原因</th>
                  <th style={{ width: 80 }}>操作者</th>
                  <th style={{ width: 50 }}>冲红</th>
                </tr>
              </thead>
              <tbody>
                {(db?.log || []).slice().reverse().map((entry, i) => {
                  const idx = (db?.log.length || 0) - i;
                  const amountStr = entry.type === "set"
                    ? `=${entry.amount}`
                    : (entry.amount >= 0 ? `+${entry.amount}` : `${entry.amount}`);
                  return (
                    <tr key={idx} className={`${i % 2 === 0 ? "even" : "odd"} ${entry.reversed ? "reversed" : ""}`}>
                      <td>{idx}</td>
                      <td className="timestamp">{formatTime(entry.timestamp)}</td>
                      <td>{TYPE_NAMES[entry.type] || entry.type}</td>
                      <td>{entry.player}</td>
                      <td className={`amount ${entry.amount >= 0 ? "positive" : "negative"}`}>{amountStr}</td>
                      <td>{entry.reason}</td>
                      <td>{entry.officer}</td>
                      <td>{entry.reversed ? "是" : ""}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {tab === "kdocs" && (
          <div className="config-panel">
            <div className="form-group">
              <label>金山文档 URL</label>
              <div className="sv-path">{config.kdocs_url || "请先在配置页设置金山文档 URL"}</div>
            </div>

            <div className="button-row">
              <button
                className="btn-primary"
                disabled={!config.kdocs_url}
                onClick={async () => {
                  try {
                    await invoke("open_kdocs", { url: config.kdocs_url });
                    setStatus("金山文档窗口已打开，请先登录");
                  } catch (e) {
                    setStatus(`打开失败: ${e}`);
                  }
                }}
              >
                打开文档
              </button>
              <button
                className="btn-primary"
                onClick={async () => {
                  try {
                    await invoke("close_kdocs");
                    setStatus("金山文档窗口已关闭");
                  } catch (e) {
                    setStatus(`关闭失败: ${e}`);
                  }
                }}
              >
                关闭文档
              </button>
            </div>

            <div style={{ marginTop: 24, borderTop: "1px solid #0f3460", paddingTop: 16 }}>
              <div className="form-group">
                <label>API 测试</label>
                <p style={{ color: "#668899", fontSize: 12, marginBottom: 8 }}>
                  请先打开文档并登录，等待文档完全加载后再操作
                </p>
              </div>
              <div className="button-row">
                <button
                  className="btn-primary"
                  onClick={async () => {
                    try {
                      await invoke("explore_kdocs_api");
                      setStatus("已注入探索脚本，请查看弹窗");
                    } catch (e) {
                      setStatus(`探索失败: ${e}`);
                    }
                  }}
                >
                  探索 API
                </button>
              </div>
            </div>

            <div style={{ marginTop: 24, borderTop: "1px solid #0f3460", paddingTop: 16 }}>
              <div className="form-group">
                <label>数据推送</label>
                <p style={{ color: "#668899", fontSize: 12, marginBottom: 8 }}>
                  {db
                    ? `已加载: ${Object.keys(db.players).length} 名玩家, ${db.log.length} 条记录`
                    : "请先在配置页加载 DKP 数据"}
                </p>
              </div>
              <div className="button-row">
                <button
                  className="btn-primary"
                  disabled={!db}
                  onClick={async () => {
                    try {
                      await invoke("push_players_to_kdocs", { db, sheetIndex: 1 });
                      setStatus("已推送玩家数据到 Sheet 1");
                    } catch (e) {
                      setStatus(`推送失败: ${e}`);
                    }
                  }}
                >
                  推送 DKP 到 Sheet 1
                </button>
                <button
                  className="btn-primary"
                  disabled={!db}
                  onClick={async () => {
                    try {
                      await invoke("push_log_to_kdocs", { db, sheetIndex: 2 });
                      setStatus("已推送操作记录到 Sheet 2");
                    } catch (e) {
                      setStatus(`推送失败: ${e}`);
                    }
                  }}
                >
                  推送记录到 Sheet 2
                </button>
              </div>
            </div>
          </div>
        )}
      </main>
    </div>
  );
}

export default App;
