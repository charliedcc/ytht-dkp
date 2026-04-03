----------------------------------------------------------------------
-- YTHT DKP - Database & Initialization
----------------------------------------------------------------------

-- 全局命名空间
YTHT_DKP = YTHT_DKP or {}
local DKP = YTHT_DKP

-- 版本
DKP.version = "1.0.5"
DKP.addonName = "YTHT_DKP"

-- 插件通信前缀
DKP.ADDON_PREFIX = "YTHTDKP"
DKP.AUCTION_PREFIX = "YTHTDKPAuct"

-- 团队数据模板（每个团队独立一套）
local teamDefaults = {
    name = "本地",
    masterAdmin = nil,
    admins = {},
    options = {
        gatherPoints = 3,
        dismissPoints = 2,
        bossKillPoints = 5,
        enableBossKillBonus = false,
        bossKillPointsByDifficulty = {},
        progressionBonusPoints = 0,
        wipeBonus = 0,
        wipeBonusMax = 10,
        defaultStartingBid = 1,
        defaultBidByDifficulty = {
            [14] = 1,
            [15] = 3,
            [16] = 5,
            [17] = 1,
        },
        auctionDuration = 300,
        minBidIncrement = 1,
        auctionExtendTime = 10,
        minItemQuality = 2,
    },
    players = {},
    log = {},
    session = {
        active = false,
        gathered = false,
        startTime = nil,
        bossKills = {},
        wipeCounts = {},
        firstKills = {},
    },
    auctionHistory = {},
    sheets = {},
    currentSheet = nil,
    activities = {},
}

-- 全局默认值（不随团队切换）
local globalDefaults = {
    teams = {},
    currentTeam = "local",
    mode = "member",  -- "member" = 团员模式(默认), "admin" = 管理模式
    point = {},
}

----------------------------------------------------------------------
-- 模式检查
----------------------------------------------------------------------
function DKP.IsAdminMode()
    return DKP.db and DKP.db.mode == "admin"
end

function DKP.SetMode(mode)
    if not DKP.db then return false end
    if mode == "admin" then
        if not DKP.IsOfficer or not DKP.IsOfficer() then
            DKP.Print("你不是当前团队的管理员，无法切换到管理模式")
            return false
        end
        DKP.db.mode = "admin"
        DKP.Print("|cff00FF00已切换到管理模式|r")
    else
        DKP.db.mode = "member"
        DKP.Print("|cff00FF00已切换到团员模式|r")
    end
    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
    return true
end

----------------------------------------------------------------------
-- 填充默认值工具
----------------------------------------------------------------------
----------------------------------------------------------------------
-- 生成唯一团队ID
----------------------------------------------------------------------
function DKP.GenerateTeamID()
    -- 格式: team_时间戳_随机数_角色名
    local t = time()
    local r = math.random(10000, 99999)
    local name = DKP.playerName or "unknown"
    return "team_" .. t .. "_" .. r .. "_" .. name
end

----------------------------------------------------------------------
-- 创建新团队
----------------------------------------------------------------------
function DKP.CreateTeam(teamName, copyFromID)
    if not DKP.db or not DKP.db.teams then return nil end

    local teamID = DKP.GenerateTeamID()

    local newTeam
    if copyFromID and DKP.db.teams[copyFromID] then
        newTeam = CopyTable(DKP.db.teams[copyFromID])
    else
        newTeam = CopyTable(teamDefaults)
    end

    newTeam.name = teamName or "新团队"
    newTeam.masterAdmin = DKP.playerName
    newTeam.admins = { [DKP.playerName] = true }

    DKP.db.teams[teamID] = newTeam
    return teamID
end

----------------------------------------------------------------------
-- 重命名团队
----------------------------------------------------------------------
function DKP.RenameTeam(teamID, newName)
    if not DKP.db or not DKP.db.teams then return false end
    local team = DKP.db.teams[teamID]
    if not team then return false end
    team.name = newName
    if DKP.MainFrame and DKP.MainFrame.teamBtn and DKP.db.currentTeam == teamID then
        DKP.MainFrame.teamBtn.text:SetText(newName)
    end
    return true
end

----------------------------------------------------------------------
-- 删除团队
----------------------------------------------------------------------
function DKP.DeleteTeam(teamID)
    if not DKP.db or not DKP.db.teams then return false end
    if teamID == "local" then
        DKP.Print("不能删除本地团队")
        return false
    end
    if DKP.db.currentTeam == teamID then
        DKP.SwitchTeam("local")
    end
    DKP.db.teams[teamID] = nil
    return true
end

----------------------------------------------------------------------
-- 填充默认值工具
----------------------------------------------------------------------
local function FillDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = CopyTable(v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            for sk, sv in pairs(v) do
                if target[k][sk] == nil then
                    if type(sv) == "table" then
                        target[k][sk] = CopyTable(sv)
                    else
                        target[k][sk] = sv
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- 团队切换（兼容层：让现有代码的 DKP.db.players 等继续工作）
----------------------------------------------------------------------
function DKP.SwitchTeam(teamID)
    if not DKP.db or not DKP.db.teams then return end
    local team = DKP.db.teams[teamID]
    if not team then
        DKP.Print("团队不存在: " .. tostring(teamID))
        return
    end

    DKP.db.currentTeam = teamID

    -- 设置快捷引用（现有代码无需修改）
    DKP.db.players = team.players
    DKP.db.log = team.log
    DKP.db.auctionHistory = team.auctionHistory
    DKP.db.sheets = team.sheets
    DKP.db.options = team.options
    DKP.db.session = team.session
    DKP.db.admins = team.admins
    DKP.db.masterAdmin = team.masterAdmin
    DKP.db.activities = team.activities
    DKP.db.currentSheet = team.currentSheet

    -- 刷新所有UI
    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end

    if DKP.MainFrame then
        if DKP.MainFrame.instanceText then
            DKP.MainFrame.instanceText:SetText(DKP.db.currentSheet or "")
        end
        if DKP.MainFrame.teamBtn and DKP.MainFrame.teamBtn.text then
            DKP.MainFrame.teamBtn.text:SetText(team.name or teamID)
        end
    end
end

-- 获取当前团队数据
function DKP.GetCurrentTeam()
    if DKP.db and DKP.db.teams and DKP.db.currentTeam then
        return DKP.db.teams[DKP.db.currentTeam]
    end
    return nil
end

-- 获取当前团队名
function DKP.GetCurrentTeamName()
    local team = DKP.GetCurrentTeam()
    return team and team.name or "本地"
end

-- 获取当前团队ID
function DKP.GetCurrentTeamID()
    return DKP.db and DKP.db.currentTeam or "local"
end

----------------------------------------------------------------------
-- 数据迁移：从旧格式迁移到团队格式
----------------------------------------------------------------------
local function MigrateToTeams(db)
    -- 如果已经有 teams 结构，跳过迁移
    if db.teams and next(db.teams) then return end

    db.teams = {}

    -- 把现有数据迁移到 "local" 团队
    local localTeam = CopyTable(teamDefaults)
    localTeam.name = "本地"

    -- 迁移各字段
    if db.players and next(db.players) then localTeam.players = db.players end
    if db.log and #db.log > 0 then localTeam.log = db.log end
    if db.auctionHistory and #db.auctionHistory > 0 then localTeam.auctionHistory = db.auctionHistory end
    if db.sheets and next(db.sheets) then localTeam.sheets = db.sheets end
    if db.options then localTeam.options = db.options end
    if db.session then localTeam.session = db.session end
    if db.admins and next(db.admins) then localTeam.admins = db.admins end
    if db.masterAdmin then localTeam.masterAdmin = db.masterAdmin end
    if db.activities and #db.activities > 0 then localTeam.activities = db.activities end
    if db.currentSheet then localTeam.currentSheet = db.currentSheet end

    db.teams["local"] = localTeam
    db.currentTeam = "local"

    -- 清理旧字段（快捷引用会在 SwitchTeam 时重建）
    -- 不删除，让 SwitchTeam 覆盖它们
end

----------------------------------------------------------------------
-- 初始化 SavedVariables
----------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGOUT")
initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == DKP.addonName then
        -- 初始化数据库
        if not YTHT_DKP_DB then
            YTHT_DKP_DB = {}
        end

        -- 填充全局默认值
        FillDefaults(YTHT_DKP_DB, globalDefaults)

        DKP.db = YTHT_DKP_DB

        -- 数据迁移（旧版本 → 团队版本）
        MigrateToTeams(DKP.db)

        -- 确保 local 团队存在
        if not DKP.db.teams["local"] then
            DKP.db.teams["local"] = CopyTable(teamDefaults)
            DKP.db.teams["local"].name = "本地"
        end

        -- 填充团队默认值
        for _, team in pairs(DKP.db.teams) do
            FillDefaults(team, teamDefaults)
            FillDefaults(team.options, teamDefaults.options)
            FillDefaults(team.session, teamDefaults.session)
        end

        -- 注册插件通信前缀
        C_ChatInfo.RegisterAddonMessagePrefix(DKP.ADDON_PREFIX)
        C_ChatInfo.RegisterAddonMessagePrefix(DKP.AUCTION_PREFIX)

        -- 获取玩家信息
        DKP.playerName = UnitName("player")
        DKP.playerFullName = DKP.playerName .. "-" .. GetRealmName()
        DKP.playerClass = select(2, UnitClass("player"))

        -- 切换到当前团队（建立快捷引用）
        DKP.SwitchTeam(DKP.db.currentTeam or "local")

        -- 触发初始化回调
        if DKP.OnInitialized then
            DKP.OnInitialized()
        end

        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGOUT" then
        -- 保存UI位置
        if DKP.MainFrame then
            local point, _, relPoint, x, y = DKP.MainFrame:GetPoint()
            DKP.db.point = { point, "UIParent", relPoint, x, y }
        end
        -- 同步快捷引用回团队（防止归档等操作断开引用后数据丢失）
        local team = DKP.GetCurrentTeam()
        if team then
            team.players = DKP.db.players
            team.log = DKP.db.log
            team.auctionHistory = DKP.db.auctionHistory
            team.sheets = DKP.db.sheets
            team.currentSheet = DKP.db.currentSheet
        end
    end
end)
