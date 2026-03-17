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
