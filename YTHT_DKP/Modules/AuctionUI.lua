----------------------------------------------------------------------
-- YTHT DKP - Auction UI
--
-- 多拍卖列表竞价界面，所有人可见
-- 列表展示所有进行中的拍卖，每项含出价/计时/竞价按钮
-- 支持提前结束、梭哈标记、平局显示
----------------------------------------------------------------------

local DKP = YTHT_DKP

-- UI 常量
local FRAME_WIDTH = 500
local FRAME_HEIGHT = 420
local PADDING = 10
local AUCTION_ROW_HEIGHT = 60
local ROW_SPACING = 4
local ICON_SIZE = 32
local BAR_HEIGHT = 14

-- 颜色
local TITLE_COLOR = { r = 0.00, g = 0.75, b = 1.00 }
local BAR_GREEN = { r = 0.2, g = 0.8, b = 0.2 }
local BAR_YELLOW = { r = 0.9, g = 0.8, b = 0.1 }
local BAR_RED = { r = 0.9, g = 0.2, b = 0.2 }

local auctionFrame = nil
local auctionRows = {}

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
-- 创建主拍卖窗口
----------------------------------------------------------------------
local function CreateAuctionFrame()
    local f = CreateFrame("Frame", "YTHTDKPAuctionFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(150)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    f:SetBackdropBorderColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.8)

    -- 标题栏
    local titleBar = f:CreateTexture(nil, "ARTWORK")
    titleBar:SetPoint("TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", -4, -4)
    titleBar:SetHeight(24)
    titleBar:SetColorTexture(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.3)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetText("进行中的拍卖")
    title:SetTextColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b)

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- DKP 余额显示
    local balanceText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    balanceText:SetPoint("TOPLEFT", PADDING, -32)
    balanceText:SetTextColor(0.8, 0.8, 0.8)
    f.balanceText = balanceText

    -- 滚动区域
    local scrollFrame = CreateFrame("ScrollFrame", "YTHTDKPAuctionScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", PADDING, -52)
    scrollFrame:SetPoint("BOTTOMRIGHT", -PADDING - 24, PADDING)

    local scrollChild = CreateFrame("Frame", "YTHTDKPAuctionScrollChild", scrollFrame)
    scrollChild:SetWidth(FRAME_WIDTH - PADDING * 2 - 24)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    f.scrollChild = scrollChild

    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    f:Hide()
    return f
end

----------------------------------------------------------------------
-- 提前结束确认弹窗
----------------------------------------------------------------------
StaticPopupDialogs["YTHT_DKP_EARLY_END_CONFIRM"] = {
    text = "确定要提前结束该拍卖吗？\n当前最高出价者将获得物品。",
    button1 = "确定",
    button2 = "取消",
    OnAccept = function(self, data)
        if data and data.auctionID then
            DKP.EndAuction(data.auctionID)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

----------------------------------------------------------------------
-- 创建单个拍卖行
----------------------------------------------------------------------
local function CreateAuctionRow(parent, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(AUCTION_ROW_HEIGHT)

    -- 背景
    local bgColor = (index % 2 == 0) and { r = 0.13, g = 0.13, b = 0.18 } or { r = 0.10, g = 0.10, b = 0.15 }
    row:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    row:SetBackdropColor(bgColor.r, bgColor.g, bgColor.b, 0.8)
    row:SetBackdropBorderColor(0.3, 0.3, 0.4, 0.5)

    -- === 第1行：物品信息 + 出价 + 计时 ===
    -- 物品图标
    local icon = CreateFrame("Button", nil, row)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("TOPLEFT", 6, -4)
    local iconTex = icon:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.iconTex = iconTex
    row.iconBtn = icon
    icon:SetScript("OnEnter", function(self)
        if row.auctionData and row.auctionData.itemLink then
            ShowItemTooltip(self, row.auctionData.itemLink)
        end
    end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- 物品名
    local itemName = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemName:SetPoint("LEFT", icon, "RIGHT", 6, 6)
    itemName:SetWidth(200)
    itemName:SetJustifyH("LEFT")
    itemName:SetWordWrap(false)
    row.itemName = itemName

    -- 当前出价
    local bidInfo = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bidInfo:SetPoint("LEFT", icon, "RIGHT", 6, -8)
    bidInfo:SetWidth(280)
    bidInfo:SetJustifyH("LEFT")
    bidInfo:SetWordWrap(false)
    row.bidInfo = bidInfo

    -- 计时条
    local barFrame = CreateFrame("StatusBar", nil, row)
    barFrame:SetSize(120, BAR_HEIGHT)
    barFrame:SetPoint("TOPRIGHT", -6, -6)
    barFrame:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    barFrame:SetMinMaxValues(0, 1)
    barFrame:SetValue(1)
    barFrame:SetStatusBarColor(BAR_GREEN.r, BAR_GREEN.g, BAR_GREEN.b)

    local barBg = barFrame:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    local timeText = barFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeText:SetPoint("CENTER")
    timeText:SetTextColor(1, 1, 1)
    row.barFrame = barFrame
    row.timeText = timeText

    -- === 第2行：出价输入 + 按钮 ===
    local bidBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    bidBox:SetSize(60, 20)
    bidBox:SetPoint("BOTTOMLEFT", 6 + ICON_SIZE + 6, 4)
    bidBox:SetAutoFocus(false)
    bidBox:SetNumeric(true)
    row.bidBox = bidBox

    local bidBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    bidBtn:SetSize(42, 20)
    bidBtn:SetPoint("LEFT", bidBox, "RIGHT", 4, 0)
    bidBtn:SetText("竞价")
    row.bidBtn = bidBtn

    local plus1 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    plus1:SetSize(28, 20)
    plus1:SetPoint("LEFT", bidBtn, "RIGHT", 2, 0)
    plus1:SetText("+1")
    row.plus1 = plus1

    local plus5 = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    plus5:SetSize(28, 20)
    plus5:SetPoint("LEFT", plus1, "RIGHT", 2, 0)
    plus5:SetText("+5")
    row.plus5 = plus5

    local allIn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    allIn:SetSize(42, 20)
    allIn:SetPoint("LEFT", plus5, "RIGHT", 2, 0)
    allIn:SetText("SH")
    row.allIn = allIn

    -- 提前结束按钮（officer only）
    local earlyEndBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    earlyEndBtn:SetSize(60, 20)
    earlyEndBtn:SetPoint("RIGHT", row, "BOTTOMRIGHT", -52, 14)
    earlyEndBtn:SetText("提前结束")
    earlyEndBtn:Hide()
    row.earlyEndBtn = earlyEndBtn

    local cancelBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    cancelBtn:SetSize(42, 20)
    cancelBtn:SetPoint("BOTTOMRIGHT", -6, 4)
    cancelBtn:SetText("取消")
    row.cancelBtn = cancelBtn

    row.auctionData = nil
    return row
end

----------------------------------------------------------------------
-- 设置拍卖行数据
----------------------------------------------------------------------
local function SetAuctionRowData(row, auction)
    row.auctionData = auction

    -- 物品图标
    local _, _, _, _, iconTexture = C_Item.GetItemInfoInstant(auction.itemLink)
    row.iconTex:SetTexture(iconTexture)

    -- 物品名（品质色）
    local name, _, quality = C_Item.GetItemInfo(auction.itemLink)
    if name then
        local c = DKP.GetQualityColor(quality)
        row.itemName:SetTextColor(c.r, c.g, c.b)
        row.itemName:SetText(name)
    else
        row.itemName:SetText(auction.itemLink)
        row.itemName:SetTextColor(1, 1, 1)
    end

    -- 出价信息（含平局显示）
    local bidText
    if auction.tiedBidders and #auction.tiedBidders >= 2 then
        -- 平局显示
        local names = {}
        for _, tb in ipairs(auction.tiedBidders) do
            table.insert(names, tb.name)
        end
        bidText = "|cffFF4444sh平局!|r " .. table.concat(names, " vs ") ..
            " @ |cffFFD700" .. auction.currentBid .. "|r DKP"
    elseif auction.currentBid > 0 and auction.currentBidder then
        local bidderClass = "WARRIOR"
        if auction.currentBidderPlayer then
            local pData = DKP.db.players[auction.currentBidderPlayer]
            if pData then
                for _, c in ipairs(pData.characters or {}) do
                    if c.name == auction.currentBidder then
                        bidderClass = c.class
                        break
                    end
                end
            end
        end
        local allInTag = auction.currentBidIsAllIn and " |cffFF8800[sh]|r" or ""
        bidText = "当前: |cffFFD700" .. auction.currentBid .. "|r DKP  by " ..
            DKP.ClassColorText(auction.currentBidder, bidderClass) .. allInTag
    else
        bidText = "起拍: |cffFFD700" .. auction.startBid .. "|r DKP  |cff888888(暂无出价)|r"
    end
    row.bidInfo:SetText(bidText)

    -- 出价框默认值
    local minIncrement = DKP.db.options.minBidIncrement or 1
    local nextBid = auction.currentBid > 0 and (auction.currentBid + minIncrement) or auction.startBid
    row.bidBox:SetText(tostring(nextBid))

    -- 按钮回调
    local auctionID = auction.id
    row.bidBtn:SetScript("OnClick", function()
        local amt = tonumber(row.bidBox:GetText())
        if amt then DKP.PlaceBid(auctionID, amt, false) end
    end)
    row.bidBox:SetScript("OnEnterPressed", function(self)
        local amt = tonumber(self:GetText())
        if amt then DKP.PlaceBid(auctionID, amt, false) end
        self:ClearFocus()
    end)

    row.plus1:SetScript("OnClick", function()
        local base = auction.currentBid > 0 and auction.currentBid or (auction.startBid - 1)
        DKP.PlaceBid(auctionID, base + 1, false)
    end)
    row.plus5:SetScript("OnClick", function()
        local base = auction.currentBid > 0 and auction.currentBid or (auction.startBid - 1)
        DKP.PlaceBid(auctionID, base + 5, false)
    end)
    row.allIn:SetScript("OnClick", function()
        local myPlayer = DKP.GetPlayerByCharacter(DKP.playerName) or DKP.playerName
        local available = DKP.GetAvailableDKP(myPlayer)
        if auction.currentBidderPlayer == myPlayer then
            available = available + auction.currentBid
        end
        if available > 0 then
            DKP.PlaceBid(auctionID, available, true)
        end
    end)

    -- 提前结束按钮（仅officer, 有出价时启用）
    if DKP.IsOfficer() then
        row.earlyEndBtn:Show()
        if auction.currentBid > 0 then
            row.earlyEndBtn:Enable()
            row.earlyEndBtn:SetScript("OnClick", function()
                local popup = StaticPopup_Show("YTHT_DKP_EARLY_END_CONFIRM")
                if popup then
                    popup.data = { auctionID = auctionID }
                    popup:SetFrameStrata("FULLSCREEN_DIALOG")
                end
            end)
        else
            row.earlyEndBtn:Disable()
        end
    else
        row.earlyEndBtn:Hide()
    end

    -- 取消按钮（仅管理员）
    if DKP.IsOfficer() then
        row.cancelBtn:Show()
        row.cancelBtn:SetScript("OnClick", function()
            DKP.CancelAuction(auctionID)
        end)
    else
        row.cancelBtn:Hide()
    end
end

----------------------------------------------------------------------
-- 更新计时条
----------------------------------------------------------------------
local function UpdateRowTimer(row)
    local auction = row.auctionData
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then
        row.barFrame:SetValue(0)
        row.timeText:SetText("已结束")
        return
    end

    local remaining = auction.endTime - GetTime()
    if remaining < 0 then remaining = 0 end
    local ratio = remaining / auction.duration

    row.barFrame:SetValue(math.max(0, math.min(1, ratio)))
    row.timeText:SetText(math.ceil(remaining) .. "秒")

    -- 颜色
    if ratio > 0.5 then
        row.barFrame:SetStatusBarColor(BAR_GREEN.r, BAR_GREEN.g, BAR_GREEN.b)
    elseif ratio > 0.2 then
        row.barFrame:SetStatusBarColor(BAR_YELLOW.r, BAR_YELLOW.g, BAR_YELLOW.b)
    else
        row.barFrame:SetStatusBarColor(BAR_RED.r, BAR_RED.g, BAR_RED.b)
    end
end

----------------------------------------------------------------------
-- 刷新拍卖UI
----------------------------------------------------------------------
function DKP.RefreshAuctionUI()
    if not auctionFrame then return end
    if not auctionFrame:IsShown() then return end

    -- 更新余额显示
    local myPlayer = DKP.GetPlayerByCharacter(DKP.playerName) or DKP.playerName
    local totalDKP = 0
    local availDKP = 0
    if DKP.db.players[myPlayer] then
        totalDKP = DKP.db.players[myPlayer].dkp or 0
        availDKP = DKP.GetAvailableDKP(myPlayer)
    end
    local committed = totalDKP - availDKP
    if committed > 0 then
        auctionFrame.balanceText:SetText(
            "DKP余额: |cffFFD700" .. totalDKP .. "|r    可用: |cff00FF00" .. availDKP ..
            "|r  (已出价 |cffFF8800" .. committed .. "|r)")
    else
        auctionFrame.balanceText:SetText(
            "DKP余额: |cffFFD700" .. totalDKP .. "|r    可用: |cff00FF00" .. availDKP .. "|r")
    end

    -- 收集活跃拍卖并按开始时间排序
    local sorted = {}
    for _, auction in pairs(DKP.activeAuctions) do
        if auction.state == DKP.AUCTION_STATE.ACTIVE then
            table.insert(sorted, auction)
        end
    end
    table.sort(sorted, function(a, b) return a.startTime < b.startTime end)

    local scrollChild = auctionFrame.scrollChild
    local contentWidth = scrollChild:GetWidth()

    -- 隐藏所有行
    for _, row in ipairs(auctionRows) do
        row:Hide()
    end

    if #sorted == 0 then
        auctionFrame:Hide()
        return
    end

    local yOffset = 0
    for i, auction in ipairs(sorted) do
        local row = auctionRows[i]
        if not row then
            row = CreateAuctionRow(scrollChild, i)
            auctionRows[i] = row
        end

        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
        SetAuctionRowData(row, auction)
        UpdateRowTimer(row)
        row:Show()

        yOffset = yOffset - AUCTION_ROW_HEIGHT - ROW_SPACING
    end

    scrollChild:SetHeight(math.abs(yOffset) + 10)
end

----------------------------------------------------------------------
-- 计时器驱动（由 AuctionCore 的 ticker 调用）
----------------------------------------------------------------------
function DKP.UpdateAuctionTimers()
    if not auctionFrame or not auctionFrame:IsShown() then return end
    for _, row in ipairs(auctionRows) do
        if row:IsShown() and row.auctionData then
            UpdateRowTimer(row)
            -- 实时更新出价信息
            local auction = row.auctionData
            if auction.tiedBidders and #auction.tiedBidders >= 2 then
                local names = {}
                for _, tb in ipairs(auction.tiedBidders) do
                    table.insert(names, tb.name)
                end
                row.bidInfo:SetText("|cffFF4444sh平局!|r " .. table.concat(names, " vs ") ..
                    " @ |cffFFD700" .. auction.currentBid .. "|r DKP")
            elseif auction.currentBid > 0 and auction.currentBidder then
                local bidderClass = "WARRIOR"
                if auction.currentBidderPlayer then
                    local pData = DKP.db.players[auction.currentBidderPlayer]
                    if pData then
                        for _, c in ipairs(pData.characters or {}) do
                            if c.name == auction.currentBidder then
                                bidderClass = c.class
                                break
                            end
                        end
                    end
                end
                local allInTag = auction.currentBidIsAllIn and " |cffFF8800[sh]|r" or ""
                row.bidInfo:SetText("当前: |cffFFD700" .. auction.currentBid .. "|r DKP  by " ..
                    DKP.ClassColorText(auction.currentBidder, bidderClass) .. allInTag)
            end
        end
    end

    -- 更新余额
    local myPlayer = DKP.GetPlayerByCharacter(DKP.playerName) or DKP.playerName
    local totalDKP = DKP.db.players[myPlayer] and DKP.db.players[myPlayer].dkp or 0
    local availDKP = DKP.GetAvailableDKP(myPlayer)
    local committed = totalDKP - availDKP
    if committed > 0 then
        auctionFrame.balanceText:SetText(
            "DKP余额: |cffFFD700" .. totalDKP .. "|r    可用: |cff00FF00" .. availDKP ..
            "|r  (已出价 |cffFF8800" .. committed .. "|r)")
    else
        auctionFrame.balanceText:SetText(
            "DKP余额: |cffFFD700" .. totalDKP .. "|r    可用: |cff00FF00" .. availDKP .. "|r")
    end
end

-- 拍卖记录页定时刷新（每秒一次，ticker 驱动）
local lastAuctionLogRefresh = 0
function DKP.UpdateAuctionLogTimer()
    local now = GetTime()
    if now - lastAuctionLogRefresh >= 1 then
        lastAuctionLogRefresh = now
        if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
    end
end

----------------------------------------------------------------------
-- 显示/隐藏
----------------------------------------------------------------------
function DKP.ShowAuctionUI()
    if not auctionFrame then
        auctionFrame = CreateAuctionFrame()
    end
    auctionFrame:Show()
    auctionFrame:Raise()  -- 确保在最前面
    DKP.RefreshAuctionUI()
end

function DKP.HideAuctionUI()
    if auctionFrame then
        auctionFrame:Hide()
    end
end
