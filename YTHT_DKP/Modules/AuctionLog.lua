----------------------------------------------------------------------
-- YTHT DKP - Auction Log
--
-- 拍卖历史记录展示，嵌入主界面第三个 Tab
----------------------------------------------------------------------

local DKP = YTHT_DKP

local PADDING = 10
local ROW_HEIGHT = 22
local HEADER_BG = { r = 0.08, g = 0.08, b = 0.12, a = 0.95 }
local ROW_BG = { r = 0.10, g = 0.10, b = 0.15, a = 0.7 }
local ROW_ALT_BG = { r = 0.13, g = 0.13, b = 0.18, a = 0.7 }

local logRows = {}

----------------------------------------------------------------------
-- Tooltip
----------------------------------------------------------------------
local function ShowItemTooltip(self, itemLink)
    if not itemLink then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(itemLink)
    GameTooltip:Show()
end

----------------------------------------------------------------------
-- 初始化拍卖记录面板
----------------------------------------------------------------------
function DKP.InitAuctionLogPanel()
    local parent = DKP.MainFrame and DKP.MainFrame.auctionLogContent
    if not parent then return end

    -- 表头
    local headerBg = parent:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", PADDING, 0)
    headerBg:SetPoint("TOPRIGHT", -PADDING, 0)
    headerBg:SetHeight(20)
    headerBg:SetColorTexture(HEADER_BG.r, HEADER_BG.g, HEADER_BG.b, HEADER_BG.a)

    local headers = { { "时间", 0 }, { "装备", 100 }, { "获胜者", 310 }, { "出价", 420 }, { "竞价", 490 }, { "操作员", 550 } }
    for _, h in ipairs(headers) do
        local t = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetPoint("TOPLEFT", headerBg, "TOPLEFT", h[2] + 4, 0)
        t:SetText(h[1])
        t:SetTextColor(0.6, 0.6, 0.6)
    end

    -- 滚动区域
    local scrollFrame = CreateFrame("ScrollFrame", "YTHTDKPAuctionLogScroll", parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", PADDING, -22)
    scrollFrame:SetPoint("BOTTOMRIGHT", -PADDING - 24, PADDING)

    local scrollChild = CreateFrame("Frame", "YTHTDKPAuctionLogScrollChild", scrollFrame)
    scrollChild:SetWidth(parent:GetWidth() - PADDING * 2 - 24)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    parent.scrollChild = scrollChild

    -- 空提示
    local emptyText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", parent, "CENTER", 0, 0)
    emptyText:SetText("|cff555555暂无拍卖记录|r")
    parent.emptyText = emptyText
end

----------------------------------------------------------------------
-- 创建记录行
----------------------------------------------------------------------
local function CreateLogRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)

    local bgColor = (index % 2 == 0) and ROW_ALT_BG or ROW_BG
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)
    row.bg = bg

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)

    -- 时间
    local timeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeText:SetPoint("LEFT", 4, 0)
    timeText:SetWidth(94)
    timeText:SetJustifyH("LEFT")
    row.timeText = timeText

    -- 装备图标 + 名称
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 100, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    itemText:SetWidth(180)
    itemText:SetJustifyH("LEFT")
    itemText:SetWordWrap(false)
    row.itemText = itemText

    -- 获胜者
    local winnerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    winnerText:SetPoint("LEFT", 314, 0)
    winnerText:SetWidth(100)
    winnerText:SetJustifyH("LEFT")
    winnerText:SetWordWrap(false)
    row.winnerText = winnerText

    -- 出价
    local bidText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bidText:SetPoint("LEFT", 424, 0)
    bidText:SetWidth(60)
    bidText:SetJustifyH("RIGHT")
    row.bidText = bidText

    -- 竞价次数
    local countText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", 494, 0)
    countText:SetWidth(50)
    countText:SetJustifyH("CENTER")
    row.countText = countText

    -- 操作员
    local officerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    officerText:SetPoint("LEFT", 554, 0)
    officerText:SetWidth(80)
    officerText:SetJustifyH("LEFT")
    officerText:SetWordWrap(false)
    row.officerText = officerText

    row.itemLink = nil

    -- Tooltip
    row:SetScript("OnEnter", function(self)
        if self.itemLink then ShowItemTooltip(self, self.itemLink) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if self.itemLink and IsShiftKeyDown() then
            ChatEdit_InsertLink(self.itemLink)
        end
    end)

    return row
end

----------------------------------------------------------------------
-- 刷新拍卖记录
----------------------------------------------------------------------
function DKP.RefreshAuctionLogUI()
    local parent = DKP.MainFrame and DKP.MainFrame.auctionLogContent
    if not parent or not parent.scrollChild then return end
    if not parent:IsShown() then return end

    local scrollChild = parent.scrollChild
    local history = DKP.db.auctionHistory or {}

    -- 隐藏所有行
    for _, row in ipairs(logRows) do
        row:Hide()
    end

    if #history == 0 then
        if parent.emptyText then parent.emptyText:Show() end
        scrollChild:SetHeight(1)
        return
    end

    if parent.emptyText then parent.emptyText:Hide() end

    -- 倒序显示
    local displayIndex = 0
    for i = #history, 1, -1 do
        displayIndex = displayIndex + 1
        local entry = history[i]

        local row = logRows[displayIndex]
        if not row then
            row = CreateLogRow(scrollChild, displayIndex)
            logRows[displayIndex] = row
        end

        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(displayIndex - 1) * (ROW_HEIGHT + 2))
        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)

        local bgColor = (displayIndex % 2 == 0) and ROW_ALT_BG or ROW_BG
        row.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)

        -- 时间
        row.timeText:SetText(date("%m-%d %H:%M", entry.timestamp or 0))
        row.timeText:SetTextColor(0.7, 0.7, 0.7)

        -- 装备
        row.itemLink = entry.itemLink
        if entry.itemLink then
            local _, _, _, _, iconTex = C_Item.GetItemInfoInstant(entry.itemLink)
            row.icon:SetTexture(iconTex)
            local itemName, _, quality = C_Item.GetItemInfo(entry.itemLink)
            if itemName then
                local c = DKP.GetQualityColor(quality)
                row.itemText:SetTextColor(c.r, c.g, c.b)
                row.itemText:SetText(itemName)
            else
                row.itemText:SetText(entry.itemLink)
                row.itemText:SetTextColor(1, 1, 1)
            end
        else
            row.icon:SetTexture(nil)
            row.itemText:SetText("?")
        end

        -- 获胜者
        if entry.winner and entry.winner ~= "" then
            row.winnerText:SetText(DKP.ClassColorText(entry.winnerChar or entry.winner, entry.winnerClass or "WARRIOR"))
        else
            row.winnerText:SetText("|cff888888流拍|r")
        end

        -- 出价
        if entry.finalBid and entry.finalBid > 0 then
            row.bidText:SetText("|cffFFD700" .. entry.finalBid .. "|r")
        else
            row.bidText:SetText("-")
            row.bidText:SetTextColor(0.5, 0.5, 0.5)
        end

        -- 竞价次数
        row.countText:SetText(tostring(entry.bidCount or 0))
        row.countText:SetTextColor(0.7, 0.7, 0.7)

        -- 操作员
        row.officerText:SetText(entry.officer or "")
        row.officerText:SetTextColor(0.5, 0.5, 0.5)

        row:Show()
    end

    scrollChild:SetHeight(math.max(1, displayIndex * (ROW_HEIGHT + 2)))
end
