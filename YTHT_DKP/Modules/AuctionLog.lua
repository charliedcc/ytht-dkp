----------------------------------------------------------------------
-- YTHT DKP - Auction Log (拍卖记录)
--
-- 按Boss分栏展示拍卖历史，点击查看竞价详情
-- 左右分割: 左侧(60%)拍卖列表，右侧(40%)竞价详情
----------------------------------------------------------------------

local DKP = YTHT_DKP

local PADDING = 8
local ROW_HEIGHT = 22
local BOSS_HEADER_HEIGHT = 24
local HEADER_BG = { r = 0.08, g = 0.08, b = 0.12, a = 0.95 }
local BOSS_BG = { r = 0.18, g = 0.14, b = 0.06, a = 0.9 }
local ROW_BG = { r = 0.10, g = 0.10, b = 0.15, a = 0.7 }
local ROW_ALT_BG = { r = 0.13, g = 0.13, b = 0.18, a = 0.7 }
local SELECTED_BG = { r = 0.2, g = 0.3, b = 0.5, a = 0.7 }

-- 状态颜色
local STATE_COLORS = {
    ENDED = { r = 0.3, g = 0.9, b = 0.3 },
    CANCELLED = { r = 0.5, g = 0.5, b = 0.5 },
    MANUAL = { r = 0.4, g = 0.6, b = 1.0 },
    TIE = { r = 1.0, g = 0.3, b = 0.3 },
}
local STATE_LABELS = {
    ENDED = "已结束",
    CANCELLED = "已取消",
    MANUAL = "手动",
    TIE = "平局",
}

-- 缓存
local leftRows = {}
local bossHeaders = {}
local selectedEntry = nil
local detailBidRows = {}

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
-- 初始化面板
----------------------------------------------------------------------
function DKP.InitAuctionLogPanel()
    local parent = DKP.MainFrame and DKP.MainFrame.auctionLogContent
    if not parent then return end

    local totalWidth = parent:GetWidth() - PADDING * 3

    -- 左侧: 拍卖列表 (60%)
    local leftWidth = math.floor(totalWidth * 0.58)
    local leftFrame = CreateFrame("Frame", nil, parent)
    leftFrame:SetPoint("TOPLEFT", PADDING, -PADDING)
    leftFrame:SetPoint("BOTTOMLEFT", PADDING, PADDING)
    leftFrame:SetWidth(leftWidth)
    parent.leftFrame = leftFrame

    -- 左侧标题
    local leftTitle = leftFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    leftTitle:SetPoint("TOPLEFT", 0, 0)
    leftTitle:SetText("拍卖记录")
    leftTitle:SetTextColor(0.6, 0.6, 0.6)

    -- 清空记录按钮
    local clearLogBtn = CreateFrame("Button", nil, leftFrame, "UIPanelButtonTemplate")
    clearLogBtn:SetSize(60, 16)
    clearLogBtn:SetPoint("LEFT", leftTitle, "RIGHT", 8, 0)
    clearLogBtn:SetText("清空记录")
    clearLogBtn:SetScript("OnClick", function()
        StaticPopupDialogs["YTHT_DKP_CLEAR_AUCTION_LOG"] = {
            text = "确定要清空所有拍卖记录吗？\n此操作不可撤销。",
            button1 = "确定",
            button2 = "取消",
            OnAccept = function()
                wipe(DKP.db.auctionHistory)
                DKP.hasUnsavedChanges = true
                DKP.Print("拍卖记录已清空")
                if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        local popup = StaticPopup_Show("YTHT_DKP_CLEAR_AUCTION_LOG")
        if popup then popup:SetFrameStrata("FULLSCREEN_DIALOG") end
    end)

    -- 左侧滚动区
    local leftScroll = CreateFrame("ScrollFrame", "YTHTDKPAuctionLogLeftScroll", leftFrame, "UIPanelScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 0, -18)
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 0)

    local leftChild = CreateFrame("Frame", "YTHTDKPAuctionLogLeftChild", leftScroll)
    leftChild:SetWidth(leftScroll:GetWidth())
    leftChild:SetHeight(1)
    leftScroll:SetScrollChild(leftChild)
    parent.leftChild = leftChild

    -- 右侧: 竞价详情 (40%)
    local rightFrame = CreateFrame("Frame", nil, parent)
    rightFrame:SetPoint("TOPLEFT", leftFrame, "TOPRIGHT", PADDING, 0)
    rightFrame:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)
    parent.rightFrame = rightFrame

    -- 右侧背景
    local rightBg = rightFrame:CreateTexture(nil, "BACKGROUND")
    rightBg:SetAllPoints()
    rightBg:SetColorTexture(0.06, 0.06, 0.10, 0.8)

    -- 右侧标题
    local rightTitle = rightFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rightTitle:SetPoint("TOPLEFT", 6, -4)
    rightTitle:SetText("竞价详情")
    rightTitle:SetTextColor(0.6, 0.6, 0.6)

    -- 右侧内容滚动区
    local rightScroll = CreateFrame("ScrollFrame", "YTHTDKPAuctionLogRightScroll", rightFrame, "UIPanelScrollFrameTemplate")
    rightScroll:SetPoint("TOPLEFT", 4, -20)
    rightScroll:SetPoint("BOTTOMRIGHT", -24, 4)

    local rightChild = CreateFrame("Frame", "YTHTDKPAuctionLogRightChild", rightScroll)
    rightChild:SetWidth(rightScroll:GetWidth())
    rightChild:SetHeight(1)
    rightScroll:SetScrollChild(rightChild)
    parent.rightChild = rightChild

    -- 空提示
    local emptyText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyText:SetPoint("CENTER", leftFrame, "CENTER", 0, 0)
    emptyText:SetText("|cff555555暂无拍卖记录|r")
    parent.emptyText = emptyText

    -- 详情空提示
    local detailEmpty = rightFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailEmpty:SetPoint("CENTER", rightFrame, "CENTER", 0, 0)
    detailEmpty:SetText("|cff555555点击左侧记录查看详情|r")
    parent.detailEmpty = detailEmpty
end

----------------------------------------------------------------------
-- 分组 auctionHistory
----------------------------------------------------------------------
local function GroupHistoryByBoss(history)
    local groups = {}   -- encounterName -> { entries }
    local order = {}    -- 保持顺序

    for i = #history, 1, -1 do
        local entry = history[i]
        local bossName = entry.encounterName or "其他"
        if not groups[bossName] then
            groups[bossName] = {}
            table.insert(order, bossName)
        end
        table.insert(groups[bossName], entry)
    end

    return groups, order
end

----------------------------------------------------------------------
-- 创建Boss标题行
----------------------------------------------------------------------
local function GetOrCreateBossHeader(parent, index)
    if bossHeaders[index] then return bossHeaders[index] end

    local header = CreateFrame("Frame", nil, parent)
    header:SetHeight(BOSS_HEADER_HEIGHT)

    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(BOSS_BG.r, BOSS_BG.g, BOSS_BG.b, BOSS_BG.a)

    local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", 6, 0)
    text:SetTextColor(1, 0.8, 0.2)
    header.text = text

    bossHeaders[index] = header
    return header
end

----------------------------------------------------------------------
-- 创建拍卖记录行
----------------------------------------------------------------------
local function GetOrCreateRow(parent, index)
    if leftRows[index] then return leftRows[index] end

    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    row.bg = bg

    local selectBg = row:CreateTexture(nil, "ARTWORK")
    selectBg:SetAllPoints()
    selectBg:SetColorTexture(SELECTED_BG.r, SELECTED_BG.g, SELECTED_BG.b, SELECTED_BG.a)
    selectBg:Hide()
    row.selectBg = selectBg

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)

    -- 图标
    local icon = row:CreateTexture(nil, "OVERLAY")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    -- 物品名
    local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    itemText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    itemText:SetWidth(130)
    itemText:SetJustifyH("LEFT")
    itemText:SetWordWrap(false)
    row.itemText = itemText

    -- 获胜者
    local winnerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    winnerText:SetPoint("LEFT", 160, 0)
    winnerText:SetWidth(80)
    winnerText:SetJustifyH("LEFT")
    winnerText:SetWordWrap(false)
    row.winnerText = winnerText

    -- DKP
    local dkpText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dkpText:SetPoint("LEFT", 244, 0)
    dkpText:SetWidth(50)
    dkpText:SetJustifyH("RIGHT")
    row.dkpText = dkpText

    -- 状态
    local stateText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stateText:SetPoint("RIGHT", -4, 0)
    stateText:SetWidth(48)
    stateText:SetJustifyH("RIGHT")
    row.stateText = stateText

    row.itemLink = nil

    -- Tooltip
    row:SetScript("OnEnter", function(self)
        if self.itemLink then ShowItemTooltip(self, self.itemLink) end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    leftRows[index] = row
    return row
end

----------------------------------------------------------------------
-- 填充记录行数据
----------------------------------------------------------------------
local function SetRowData(row, entry, rowIndex)
    local bgColor = (rowIndex % 2 == 0) and ROW_ALT_BG or ROW_BG
    row.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)

    row.itemLink = entry.itemLink
    row.entry = entry

    -- 图标
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
    local state = entry.state or "ENDED"
    if state == "CANCELLED" then
        row.winnerText:SetText("|cff888888-|r")
    elseif state == "TIE" then
        row.winnerText:SetText("|cffFF4444转人工|r")
    elseif entry.winner and entry.winner ~= "" then
        row.winnerText:SetText(DKP.ClassColorText(
            entry.winnerChar or entry.winner,
            entry.winnerClass or "WARRIOR"
        ))
    else
        row.winnerText:SetText("|cff888888流拍|r")
    end

    -- DKP
    if entry.finalBid and entry.finalBid > 0 then
        row.dkpText:SetText("|cffFFD700" .. entry.finalBid .. "|r")
    else
        row.dkpText:SetText("")
    end

    -- 状态标签
    local sc = STATE_COLORS[state] or STATE_COLORS.ENDED
    local sl = STATE_LABELS[state] or "已结束"
    row.stateText:SetText(sl)
    row.stateText:SetTextColor(sc.r, sc.g, sc.b)

    -- 选中高亮
    if selectedEntry == entry then
        row.selectBg:Show()
    else
        row.selectBg:Hide()
    end

    -- 点击事件
    row:SetScript("OnClick", function(self, button)
        if IsShiftKeyDown() and self.itemLink then
            ChatEdit_InsertLink(self.itemLink)
            return
        end
        selectedEntry = entry
        -- 更新所有行选中状态
        for _, r in ipairs(leftRows) do
            if r.selectBg then
                if r.entry == entry then
                    r.selectBg:Show()
                else
                    r.selectBg:Hide()
                end
            end
        end
        RefreshDetailPanel()
    end)
end

----------------------------------------------------------------------
-- 刷新详情面板
----------------------------------------------------------------------
function RefreshDetailPanel()
    local parent = DKP.MainFrame and DKP.MainFrame.auctionLogContent
    if not parent or not parent.rightChild then return end

    local rightChild = parent.rightChild

    -- 隐藏旧行
    for _, row in ipairs(detailBidRows) do
        row:Hide()
    end

    -- 清除旧的动态文本
    if rightChild.dynamicFonts then
        for _, fs in ipairs(rightChild.dynamicFonts) do
            fs:SetText("")
            fs:Hide()
        end
    end
    rightChild.dynamicFonts = rightChild.dynamicFonts or {}

    if not selectedEntry then
        if parent.detailEmpty then parent.detailEmpty:Show() end
        rightChild:SetHeight(1)
        return
    end
    if parent.detailEmpty then parent.detailEmpty:Hide() end

    local entry = selectedEntry
    local yOffset = 0

    -- 辅助: 创建或复用字体串
    local fontIndex = 0
    local function GetFontString(template, width)
        fontIndex = fontIndex + 1
        local fs = rightChild.dynamicFonts[fontIndex]
        if not fs then
            fs = rightChild:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
            rightChild.dynamicFonts[fontIndex] = fs
        else
            fs:SetFontObject(template or "GameFontNormalSmall")
        end
        fs:ClearAllPoints()
        if width then fs:SetWidth(width) end
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:Show()
        return fs
    end

    local contentWidth = rightChild:GetWidth() - 8

    -- 物品图标+名称
    if entry.itemLink then
        local fs = GetFontString("GameFontNormal", contentWidth)
        fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
        local itemName, _, quality = C_Item.GetItemInfo(entry.itemLink)
        if itemName then
            local c = DKP.GetQualityColor(quality)
            fs:SetTextColor(c.r, c.g, c.b)
            fs:SetText(itemName)
        else
            fs:SetText(entry.itemLink)
            fs:SetTextColor(1, 1, 1)
        end
        yOffset = yOffset - 18
    end

    -- 状态
    local state = entry.state or "ENDED"
    local sc = STATE_COLORS[state] or STATE_COLORS.ENDED
    local fs = GetFontString("GameFontNormalSmall", contentWidth)
    fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
    fs:SetText("状态: " .. (STATE_LABELS[state] or "已结束"))
    fs:SetTextColor(sc.r, sc.g, sc.b)
    yOffset = yOffset - 16

    -- 起拍/最终
    fs = GetFontString("GameFontNormalSmall", contentWidth)
    fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
    local bidInfo = "起拍: " .. (entry.startBid or 0)
    if entry.finalBid and entry.finalBid > 0 then
        bidInfo = bidInfo .. "  最终: |cffFFD700" .. entry.finalBid .. "|r DKP"
    end
    fs:SetText(bidInfo)
    fs:SetTextColor(0.8, 0.8, 0.8)
    yOffset = yOffset - 16

    -- 竞价次数
    fs = GetFontString("GameFontNormalSmall", contentWidth)
    fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
    fs:SetText("竞价: " .. (entry.bidCount or 0) .. " 次")
    fs:SetTextColor(0.7, 0.7, 0.7)
    yOffset = yOffset - 16

    -- 操作员 + 时间
    fs = GetFontString("GameFontNormalSmall", contentWidth)
    fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
    fs:SetText("操作员: " .. (entry.officer or "?") .. "  " ..
        date("%m-%d %H:%M", entry.timestamp or 0))
    fs:SetTextColor(0.5, 0.5, 0.5)
    yOffset = yOffset - 16

    -- 平局信息
    if state == "TIE" and entry.tiedBidders and #entry.tiedBidders >= 2 then
        local names = {}
        for _, tb in ipairs(entry.tiedBidders) do
            table.insert(names, tb.name or tb.playerName or "?")
        end
        fs = GetFontString("GameFontNormalSmall", contentWidth)
        fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
        fs:SetText("|cffFF4444平局玩家: " .. table.concat(names, " vs ") .. "|r")
        fs:SetTextColor(1, 0.3, 0.3)
        yOffset = yOffset - 16
    end

    -- 获胜者
    if entry.winner and entry.winner ~= "" then
        fs = GetFontString("GameFontNormalSmall", contentWidth)
        fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
        fs:SetText("获胜者: " .. DKP.ClassColorText(
            entry.winnerChar or entry.winner,
            entry.winnerClass or "WARRIOR"
        ))
        fs:SetTextColor(0.8, 0.8, 0.8)
        yOffset = yOffset - 16
    end

    -- 分割线
    yOffset = yOffset - 4
    fs = GetFontString("GameFontNormalSmall", contentWidth)
    fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
    fs:SetText("─────────────────────")
    fs:SetTextColor(0.3, 0.3, 0.3)
    yOffset = yOffset - 14

    -- 竞价记录
    local bids = entry.bids
    if bids and #bids > 0 then
        fs = GetFontString("GameFontNormalSmall", contentWidth)
        fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
        fs:SetText("竞价记录:")
        fs:SetTextColor(0.6, 0.6, 0.6)
        yOffset = yOffset - 16

        for i, bid in ipairs(bids) do
            fs = GetFontString("GameFontNormalSmall", contentWidth)
            fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)

            local allInTag = ""
            if bid.isAllIn then
                allInTag = " |cffFF8800[梭哈]|r"
            end

            local timeStr = ""
            if bid.timestamp then
                timeStr = "  " .. date("%H:%M:%S", bid.timestamp)
            end

            local bidderName = bid.bidder or bid.bidderPlayer or "?"
            fs:SetText(i .. ". " .. bidderName .. "  " ..
                "|cffFFD700" .. (bid.amount or 0) .. "|r DKP" ..
                allInTag .. "  |cff666666" .. timeStr .. "|r")
            fs:SetTextColor(0.8, 0.8, 0.8)
            yOffset = yOffset - 15
        end
    else
        fs = GetFontString("GameFontNormalSmall", contentWidth)
        fs:SetPoint("TOPLEFT", rightChild, "TOPLEFT", 4, yOffset)
        fs:SetText("|cff555555无详细竞价记录|r")
        fs:SetTextColor(0.33, 0.33, 0.33)
        yOffset = yOffset - 16
    end

    rightChild:SetHeight(math.abs(yOffset) + 10)
end

----------------------------------------------------------------------
-- 刷新拍卖记录
----------------------------------------------------------------------
function DKP.RefreshAuctionLogUI()
    local parent = DKP.MainFrame and DKP.MainFrame.auctionLogContent
    if not parent or not parent.leftChild then return end
    if not parent:IsShown() then return end

    local leftChild = parent.leftChild
    local history = DKP.db.auctionHistory or {}

    -- 隐藏所有旧行
    for _, row in ipairs(leftRows) do row:Hide() end
    for _, h in ipairs(bossHeaders) do h:Hide() end

    if #history == 0 then
        if parent.emptyText then parent.emptyText:Show() end
        leftChild:SetHeight(1)
        -- 清详情
        selectedEntry = nil
        RefreshDetailPanel()
        return
    end
    if parent.emptyText then parent.emptyText:Hide() end

    -- 分组
    local groups, order = GroupHistoryByBoss(history)

    local yOffset = 0
    local rowIndex = 0
    local headerIndex = 0
    local globalRowIdx = 0

    for _, bossName in ipairs(order) do
        local entries = groups[bossName]

        -- Boss 标题
        headerIndex = headerIndex + 1
        local header = GetOrCreateBossHeader(leftChild, headerIndex)
        header:SetPoint("TOPLEFT", leftChild, "TOPLEFT", 0, yOffset)
        header:SetPoint("RIGHT", leftChild, "RIGHT", 0, 0)
        header.text:SetText(bossName .. " (" .. #entries .. ")")
        header:Show()
        yOffset = yOffset - BOSS_HEADER_HEIGHT - 2

        -- 该Boss下的拍卖记录
        for _, entry in ipairs(entries) do
            rowIndex = rowIndex + 1
            globalRowIdx = globalRowIdx + 1
            local row = GetOrCreateRow(leftChild, rowIndex)
            row:SetPoint("TOPLEFT", leftChild, "TOPLEFT", 0, yOffset)
            row:SetPoint("RIGHT", leftChild, "RIGHT", 0, 0)
            SetRowData(row, entry, globalRowIdx)
            row:Show()
            yOffset = yOffset - ROW_HEIGHT - 1
        end

        yOffset = yOffset - 4  -- boss间距
    end

    leftChild:SetHeight(math.abs(yOffset) + 10)

    -- 刷新详情面板
    RefreshDetailPanel()
end
