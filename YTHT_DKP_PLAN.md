# YTHT DKP 插件开发计划

## Context
为工会开荒魔兽12.0团队副本制作DKP插件，参考BiaoGe拍卖表格插件的架构，但以DKP积分代替金币。12.0正式服禁用了Master Loot等API，WA不再更新，需要完全独立的插件方案。BiaoGe在正式服有报错，不能完全参考。

**工会装备分配流程**：两种模式并存
1. 全员Pass → 团长拾取 → DKP拍卖 → 交易给中标者
2. 先DKP拍卖 → 中标者Need其他人Pass → 系统直接分配

**DKP数据**：工会已有历史DKP记录，需要支持从外部（Excel/CSV）导入旧数据。衰减在插件外用表格处理，插件只需支持导入/批量修改。

## 关键技术问题（需先验证）

### 1. 插件通信API可用性
- `C_ChatInfo.SendAddonMessage` 在12.0中对RAID/GUILD/WHISPER频道理论上脱战可用
- **必须先创建一个最小测试插件在12.0正式服中验证**
- 如果脱战可用：正常实现拍卖系统
- 如果完全不可用：降级方案使用RAID_WARNING聊天频道（功能受限）

### 2. 拾取框装备信息获取
- 12.0使用Group Loot，`START_LOOT_ROLL` 事件在需求/贪婪窗口弹出时触发
- `GetLootRollItemInfo(rollID)` + `GetLootRollItemLink(rollID)` 可获取物品信息
- `ENCOUNTER_LOOT_RECEIVED` 可追踪最终谁拿到了装备
- 比BiaoGe的 `CHAT_MSG_LOOT`（拾取后才触发）更早获取装备信息

### 3. BiaoGe在正式服的报错
- 主因：Master Loot API已移除（`IsMasterLooter`, `GetMasterLootCandidate`, `GiveMasterLoot`）
- `strlen()` 等已废弃全局函数
- 新插件完全避开这些API，使用团队职位（团长/助理）代替

---

## 插件架构

**单插件模块化设计**，不拆分子插件。AuctionWA的功能内置为常规模块。

```
YTHT_DKP/
├── YTHT_DKP.toc                    # Interface: 120000
├── Libs/
│   ├── embeds.xml
│   ├── LibStub/
│   ├── AceComm-3.0/               # 大消息分包
│   ├── ChatThrottleLib/            # 限流发送
│   ├── LibDBIcon-1.0/              # 小地图按钮
│   ├── LibDataBroker-1.1/
│   ├── LibSerialize/               # 数据序列化（同步用）
│   └── LibDeflate/                 # 数据压缩（同步用）
├── Locales/
│   ├── zhCN.lua
│   └── enUS.lua
├── Templates.xml
├── Core/
│   ├── DB.lua                      # SavedVariables初始化、频道注册
│   ├── Util.lua                    # 工具函数
│   ├── Main.lua                    # 主框架、斜杠命令
│   ├── Permission.lua              # 权限系统（团长/助理）
│   └── Comm.lua                    # 通信协议层
└── Modules/
    ├── DKPManager.lua              # DKP账本：加分、扣分、查询、历史
    ├── DKPSync.lua                 # 团长/助理间数据同步
    ├── BossTracker.lua             # Boss击杀检测与自动加分
    ├── LootDetector.lua            # 12.0 Group Loot事件集成
    ├── Auction/
    │   ├── AuctionCore.lua         # 拍卖状态机
    │   ├── AuctionUI.lua           # 独立拍卖UI（替代AuctionWA.lua）
    │   ├── AuctionStart.lua        # 发起拍卖界面
    │   └── AuctionLog.lua          # 拍卖历史
    ├── WhisperQuery.lua            # 密语查分
    ├── RaidSession.lua             # 集合/解散/活动管理
    ├── Report.lua                  # DKP报告
    ├── Options.lua                 # 设置面板
    └── Minimap.lua                 # 小地图按钮
```

---

## 数据存储格式（SavedVariables）

```lua
YTHT_DKP_DB = {
    options = {
        gatherPoints = 10,         -- 集合加分
        dismissPoints = 10,        -- 解散加分
        bossKillPoints = 5,        -- 过Boss加分
        defaultStartingBid = 10,   -- 拍卖起拍DKP
        auctionDuration = 30,      -- 拍卖时长（秒）
        minBidIncrement = { ... }, -- 阶梯加价表
    },
    realms = {
        ["服务器名"] = {
            players = {
                ["玩家名-服务器"] = {
                    balance = 150,
                    class = "WARRIOR",
                    lastUpdated = timestamp,
                },
            },
            log = {  -- 审计日志（追加写入）
                {
                    type = "boss_kill",  -- award|deduct|bid_win|gather|dismiss|boss_kill|manual
                    player = "玩家名-服务器",
                    amount = 5,
                    reason = "Boss击杀: Fyrakk",
                    timestamp = timestamp,
                    officer = "团长名-服务器",
                },
            },
            version = 42,  -- 同步版本号
        },
    },
    session = { ... },  -- 当前活动状态（临时）
}
```

---

## 核心功能模块

### 1. DKP积分管理 (DKPManager.lua)
- 加分：集合(gather)、解散(dismiss)、过Boss(boss_kill)、手动(manual)
- 扣分：拍卖赢得装备(bid_win)、手动(manual)
- 所有操作写入审计日志，可追溯
- **数据导入**：支持从CSV/文本格式批量导入DKP数据
  - 格式：`玩家名,分数` 每行一条
  - 通过 `/dkp import` 打开导入窗口（EditBox粘贴）或读取SavedVariables
  - 导入时记录"import"类型日志
- **批量操作**：`/dkp set 玩家名 分数` 手动设置分数

### 2. 权限系统 (Permission.lua)
- 用团队职位替代Master Loot：团长(rank=2) + 助理(rank>=1)
- 加分/发起拍卖：团长或助理
- 取消拍卖：仅团长

### 3. 拍卖系统 (Auction/)
- **AuctionCore.lua**: 状态机（ACTIVE → ENDED_SUCCESS/ENDED_FAILED/CANCELLED）
- **AuctionUI.lua**: 独立UI框架，参考AuctionWA.lua的布局但去除WA依赖
  - 物品图标、名称、倒计时条、当前出价、最高出价者、加减按钮
  - 显示"当前DKP余额"，竞拍不可超过余额
- **通信协议**:
  - `StartAuction,auctionID,itemID,startBid,duration,mode,itemLink`
  - `SendMyBid,auctionID,bidAmount`
  - `CancelAuction,auctionID`

### 4. Boss击杀检测 (BossTracker.lua)
- 监听 `ENCOUNTER_END(encounterID, name, difficulty, size, success)`
- success=1 时自动给在线团员加分
- 用 `session.bossKills[encounterID]` 防重复加分

### 5. 装备检测 (LootDetector.lua)
- 监听 `START_LOOT_ROLL` → 获取物品信息（**弹出拾取框时**）
- 监听 `ENCOUNTER_LOOT_RECEIVED` → 追踪最终谁拿到了装备
- 团长/助理可Alt+点击物品发起DKP拍卖
- **两种分装模式支持**：
  - 模式A（团长拾取）：全员Pass → 团长拾取 → 发起DKP拍卖 → 交易给中标者
  - 模式B（直接Need）：先发起DKP拍卖 → 中标者Need其他人Pass

### 6. 密语查分 (WhisperQuery.lua)
- 玩家密语"dkp"或"查分"→ 自动回复当前DKP余额
- 安装插件的玩家也可通过addon message查询（更快、无聊天刷屏）

### 7. 活动管理 (RaidSession.lua)
- `/dkp gather` - 集合加分（防重复）
- `/dkp dismiss` - 解散加分
- Boss击杀自动加分
- 发送RAID_WARNING通知

### 8. 数据同步 (DKPSync.lua)
- 基于日志版本号的乐观同步
- AceComm分包 + LibSerialize序列化 + LibDeflate压缩
- 团长/助理进团时自动同步

---

## 通信频道

```lua
C_ChatInfo.RegisterAddonMessagePrefix("YTHTDKP")      -- DKP通用消息
C_ChatInfo.RegisterAddonMessagePrefix("YTHTDKPAuct")   -- 拍卖专用消息
```

---

## 实施顺序

### 第0阶段：API验证
1. 创建最小测试插件验证 `C_ChatInfo.SendAddonMessage` 在12.0脱战状态可用性
2. 验证 `START_LOOT_ROLL` + `GetLootRollItemInfo/Link` 在12.0中的行为

### 第1阶段：基础框架
- TOC文件、目录结构、库文件引入
- DB.lua、Util.lua、Permission.lua、Comm.lua
- Main.lua（斜杠命令框架）

### 第2阶段：DKP核心
- DKPManager.lua（加分、扣分、余额、日志）
- BossTracker.lua（Boss击杀自动加分）
- RaidSession.lua（集合/解散加分）
- WhisperQuery.lua（密语查分）

### 第3阶段：拍卖系统
- AuctionCore.lua（拍卖状态机）
- AuctionUI.lua（独立拍卖UI，参考AuctionWA.lua）
- AuctionStart.lua（发起拍卖）
- LootDetector.lua（12.0 Group Loot集成）
- AuctionLog.lua（拍卖历史）

### 第4阶段：同步与完善
- DKPSync.lua（多团长数据同步）
- Options.lua（设置面板）
- Report.lua、Minimap.lua
- 本地化、测试

---

## 验证方式
1. 创建测试插件验证12.0 API可用性
2. 使用 `/dkp` 系列命令验证DKP加扣分
3. 组队环境测试拍卖流程
4. 密语查分测试
5. 多账号测试数据同步

---

## 关键参考文件
- `BiaoGe/Core/Module/AuctionWA.lua` - 拍卖UI参考（去除WA依赖）
- `BiaoGe/Core/Module/Auction.lua` - 拍卖发起逻辑参考
- `BiaoGe/Core/Module/Loot.lua` - 装备检测参考
- `BiaoGe/Core/BiaoGe.lua` - 主框架、权限检测参考
- `BiaoGe/Core/DB/DB.lua` - 初始化模式参考
- `BiaoGe/Core/Module/Receive.lua` - 数据同步参考

---

## 第5阶段：外部同步工具（Rust 桌面应用）

### 背景

WoW 插件**无法直接读写文件**，唯一持久化机制是 SavedVariables（WTF 目录下的 .lua 文件）。
工会用**金山文档**（KDocs）维护 DKP 总表：https://www.kdocs.cn/l/cqTvo6VQxE7q

需要一个独立桌面应用来桥接「WoW 插件数据」和「金山文档在线表格」。

### WoW SavedVariables 技术要点

**文件位置：**
- macOS: `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/YTHT_DKP.lua`
- Windows: `C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\YTHT_DKP.lua`

**文件格式：** 标准 Lua 全局变量赋值
```lua
YTHT_DKP_DB = {
    ["players"] = {
        ["张三"] = {
            ["dkp"] = 150,
            ["characters"] = {
                { ["name"] = "猎人号", ["class"] = "HUNTER" },
            },
        },
    },
    ["log"] = { ... },
}
```

**写入时机：** 仅在登出/reload/断线时写入磁盘。插件无法主动触发写入。

**Rust 解析方案：**
- `mlua` crate — 嵌入完整 Lua 运行时，直接 `lua.load(file).exec()` 然后读取全局变量。最可靠。
- 自定义解析器 — SavedVariables 格式很规则（只有 string/number/boolean/table），可以写一个轻量 parser。
- `full_moon` crate — Lua AST 解析器，可以解析后提取 table literal。

### 金山文档（KDocs）集成方案

金山文档没有公开的、易用的 REST API（开放平台文档在登录墙后面，且处于迁移状态）。
以下是几种可行方案，按推荐优先级排序：

#### 方案A：Tauri + 内嵌 WebView（推荐）

**原理：** 用 Tauri 构建桌面应用，内嵌一个 WebView 打开金山文档页面。用户在 WebView 内登录一次后，session/cookies 持久化。应用通过注入 JavaScript 与表格 DOM 交互，实现读写。

**优点：**
- 用户体验最好，登录一次后自动化
- 不依赖金山的 API（API 文档差、不稳定）
- Tauri 本身就是 Rust 生态，天然契合
- WebView 保存 cookies，后续免登录

**缺点：**
- 依赖金山文档的前端 DOM 结构，版本更新可能导致 JS 注入失效
- 需要研究金山文档的前端结构来编写注入脚本
- Tauri WebView 在不同平台行为可能略有差异

**技术栈：** Tauri 2.x + Rust 后端 + WebView

**大致流程：**
1. 用户首次打开 → WebView 加载金山文档 URL → 用户登录
2. 登录成功后 cookies 保存在 WebView 存储中
3. 导出：Rust 读取 SavedVariables → 解析 → 注入 JS 写入表格单元格
4. 导入：注入 JS 读取表格数据 → 传回 Rust → 写入 SavedVariables .lua 文件
5. 用户在游戏中 `/reload` 加载更新后的数据

#### 方案B：Playwright/Headless 浏览器自动化

**原理：** 启动一个 headless Chrome/Chromium，用户登录一次后保存 session，后续自动操作表格。

**优点：**
- 与方案A类似，不依赖 API
- Playwright 生态成熟，DOM 操作稳定
- 可以无头运行，适合自动化场景

**缺点：**
- Playwright 是 Node.js/Python 生态，需要 Rust 调用外部进程
- 需要捆绑 Chromium（应用体积大 ~150MB+）
- 或者用 `chromiumoxide` Rust crate（较底层）

**技术栈：** Rust 主进程 + 子进程调用 Playwright（Node.js）或 `chromiumoxide` crate

#### 方案C：剪贴板中转（最简单的降级方案）

**原理：** 应用读取 SavedVariables 后，将 DKP 数据格式化为 TSV（Tab分隔），复制到系统剪贴板。用户手动粘贴到金山文档。反向同理：用户从金山文档复制数据，应用从剪贴板读取并写回 SavedVariables。

**优点：**
- 实现最简单，不依赖任何外部服务的 API 或 DOM
- 绝对不会因金山文档更新而失效
- 可以作为其他方案的 fallback

**缺点：**
- 需要用户手动操作（复制/粘贴），体验一般
- 容易出错（粘贴位置不对等）

**技术栈：** Rust + `arboard` crate（跨平台剪贴板）

#### 方案D：金山文档 AirScript（待验证）

**原理：** 金山文档支持 AirScript（轻服务），可以在文档内创建脚本，暴露 HTTP 接口。外部应用通过 HTTP 请求读写表格数据。

**优点：**
- 如果可行，是最干净的 API 方案
- 不依赖 DOM 结构

**缺点：**
- AirScript 文档不全，能力边界不清楚
- 不确定是否支持 HTTP trigger（需要实际测试）
- 可能有请求频率限制

**状态：** 需要在金山文档中实际测试 AirScript 的 HTTP 触发器能力。

### Rust 桌面应用架构

```
ytht-dkp-sync/
├── Cargo.toml
├── src/
│   ├── main.rs                  # 入口
│   ├── config.rs                # 配置管理（WoW目录、文档URL、账号等）
│   ├── savedvariables/
│   │   ├── mod.rs
│   │   ├── parser.rs            # Lua SavedVariables 解析器
│   │   ├── writer.rs            # 写回 .lua 文件
│   │   └── watcher.rs           # 文件变更监听
│   ├── kdocs/
│   │   ├── mod.rs
│   │   ├── webview.rs           # Tauri WebView 集成（方案A）
│   │   ├── clipboard.rs         # 剪贴板方案（方案C）
│   │   └── js_inject.rs         # 注入脚本定义
│   ├── sync/
│   │   ├── mod.rs
│   │   ├── export.rs            # SavedVariables → 金山文档
│   │   ├── import.rs            # 金山文档 → SavedVariables
│   │   └── diff.rs              # 数据差异对比
│   └── ui/
│       ├── mod.rs
│       └── app.rs               # Tauri 前端交互
├── src-tauri/                   # Tauri 配置（如果用 Tauri）
│   └── tauri.conf.json
└── frontend/                    # Web 前端（Tauri 用）
    ├── index.html
    └── main.js
```

### 应用配置项

```json
{
    "wow_path": "/Applications/World of Warcraft",
    "account_name": "ACCOUNTNAME",
    "character": "角色名",
    "realm": "服务器名",
    "kdocs_url": "https://www.kdocs.cn/l/cqTvo6VQxE7q",
    "sync_mode": "manual",
    "last_sync": "2026-03-17T20:00:00Z"
}
```

用户首次启动时需要配置：
1. **WoW 安装目录** — 用于定位 WTF/SavedVariables 路径（可以提供文件浏览器选择）
2. **账号名** — WTF/Account/ 下的文件夹名
3. **金山文档链接** — 在线表格的 URL

### 同步流程

**导出（游戏 → 金山文档）：**
1. 用户在游戏中 `/reload` 或登出 → SavedVariables 写入磁盘
2. 应用检测到文件变更（或用户点击"同步"按钮）
3. 解析 `YTHT_DKP.lua` → 提取 players 表
4. 与上次同步状态对比，找出变更
5. 通过 WebView/剪贴板 将变更写入金山文档

**导入（金山文档 → 游戏）：**
1. 用户在应用中点击"从金山文档导入"
2. 通过 WebView/剪贴板 读取表格数据
3. 转换为 Lua table 格式
4. 写入 `YTHT_DKP.lua` 文件（需要 WoW 未运行或即将 /reload）
5. 用户在游戏中 `/reload` → 插件加载更新后的数据

**关键约束：**
- SavedVariables 仅在登出/reload时读写，因此同步不是实时的
- 写入 SavedVariables 文件时需确保 WoW 不会在之后覆盖（最好在 WoW 未运行时写入，或写入后立即 /reload）

### 实施顺序

1. **5.1** — Rust 项目搭建 + SavedVariables 解析器（读取 .lua 文件，输出 JSON）
2. **5.2** — SavedVariables 写入器（从 JSON 生成 .lua 文件）
3. **5.3** — 配置管理 + 文件监听
4. **5.4** — 剪贴板方案（方案C，作为最小可用版本）
5. **5.5** — Tauri 应用框架 + 基础 UI
6. **5.6** — WebView 金山文档集成（方案A，登录 + JS 注入读写）
7. **5.7** — 完整同步逻辑（diff + 双向同步）
