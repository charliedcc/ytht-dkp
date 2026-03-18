----------------------------------------------------------------------
-- YTHT DKP - Database & Initialization
----------------------------------------------------------------------

-- 全局命名空间
YTHT_DKP = YTHT_DKP or {}
local DKP = YTHT_DKP

-- 版本
DKP.version = "0.1.0"
DKP.addonName = "YTHT_DKP"

-- 插件通信前缀
DKP.ADDON_PREFIX = "YTHTDKP"
DKP.AUCTION_PREFIX = "YTHTDKPAuct"

-- 默认设置
local defaults = {
    options = {
        gatherPoints = 3,
        dismissPoints = 2,
        bossKillPoints = 5,
        -- Boss击杀加分开关 (true=启用, false=禁用)
        enableBossKillBonus = true,
        -- 按难度配置加分 (difficultyID -> 分值, 0或nil表示该难度不加分)
        -- WoW 难度ID: 1=普通, 2=英雄, 3=10人, 4=25人, 14=普通(新), 15=英雄(新), 16=史诗, 17=随机
        bossKillPointsByDifficulty = {
            -- [17] = 0,  -- 随机团: 不加分
            -- [14] = 0,  -- 普通: 不加分
            -- [15] = 5,  -- 英雄: 5分
            -- [16] = 10, -- 史诗: 10分
        },
        -- 开荒额外加分 (首杀额外加分)
        progressionBonusPoints = 0,
        -- 擦屁股分 (每次团灭额外加分, 击杀时结算)
        wipeBonus = 0,
        -- 擦屁股分上限 (最多计算N次团灭)
        wipeBonusMax = 10,
        defaultStartingBid = 1,
        -- 按副本难度的起拍价 (difficultyID -> 起拍DKP)
        defaultBidByDifficulty = {
            [14] = 1,  -- 普通: 1 DKP
            [15] = 3,  -- 英雄: 3 DKP
            [16] = 5,  -- 史诗: 5 DKP
            [17] = 1,  -- 随机团: 1 DKP
        },
        auctionDuration = 300,
        minBidIncrement = 1,
        auctionExtendTime = 10,
    },
    -- DKP 玩家数据
    players = {},
    -- DKP 审计日志
    log = {},
    -- 当前活动状态
    session = {
        active = false,
        gathered = false,
        bossKills = {},     -- encounterID -> true (本次活动已加分的boss)
        wipeCounts = {},    -- encounterID -> 团灭次数
        firstKills = {},    -- encounterID -> true (历史首杀记录，不随session重置)
    },
    -- 管理员列表
    admins = {},
    -- 拍卖历史
    auctionHistory = {},
    -- 表格数据：按副本 -> Boss -> 装备记录
    -- sheets[instanceName] = {
    --     bosses = {
    --         [1] = { name = "Boss名", encounterID = 12345, items = {
    --             [1] = { link = "itemLink", winner = "", dkp = 0, rollID = 0 },
    --         }},
    --     },
    -- }
    sheets = {},
    -- 当前查看的副本
    currentSheet = nil,
    -- UI位置
    point = {},
}

-- 初始化 SavedVariables
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGOUT")
initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == DKP.addonName then
        -- 初始化数据库
        if not YTHT_DKP_DB then
            YTHT_DKP_DB = {}
        end
        -- 填充默认值（包括嵌套table的子字段）
        for k, v in pairs(defaults) do
            if YTHT_DKP_DB[k] == nil then
                if type(v) == "table" then
                    YTHT_DKP_DB[k] = CopyTable(v)
                else
                    YTHT_DKP_DB[k] = v
                end
            elseif type(v) == "table" and type(YTHT_DKP_DB[k]) == "table" then
                -- 填充子表中缺失的字段（用于版本升级添加新选项）
                for sk, sv in pairs(v) do
                    if YTHT_DKP_DB[k][sk] == nil then
                        if type(sv) == "table" then
                            YTHT_DKP_DB[k][sk] = CopyTable(sv)
                        else
                            YTHT_DKP_DB[k][sk] = sv
                        end
                    end
                end
            end
        end
        DKP.db = YTHT_DKP_DB

        -- 注册插件通信前缀
        C_ChatInfo.RegisterAddonMessagePrefix(DKP.ADDON_PREFIX)
        C_ChatInfo.RegisterAddonMessagePrefix(DKP.AUCTION_PREFIX)

        -- 获取玩家信息
        DKP.playerName = UnitName("player")
        DKP.playerFullName = DKP.playerName .. "-" .. GetRealmName()
        DKP.playerClass = select(2, UnitClass("player"))

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
    end
end)
