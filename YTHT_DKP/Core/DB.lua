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
        gatherPoints = 10,
        dismissPoints = 10,
        bossKillPoints = 5,
        defaultStartingBid = 10,
        auctionDuration = 30,
    },
    -- DKP 玩家数据
    players = {},
    -- DKP 审计日志
    log = {},
    -- 当前活动状态
    session = {
        active = false,
        gathered = false,
        bossKills = {},
    },
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
        -- 填充默认值
        for k, v in pairs(defaults) do
            if YTHT_DKP_DB[k] == nil then
                if type(v) == "table" then
                    YTHT_DKP_DB[k] = CopyTable(v)
                else
                    YTHT_DKP_DB[k] = v
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
