----------------------------------------------------------------------
-- YTHT DKP - Main Frame & Table UI
--
-- 表格界面：显示当前副本的Boss列表和掉落装备
-- 每个Boss区域包含：Boss名称 + 装备栏位（自动从START_LOOT_ROLL填充）
-- 每个装备栏位包含：物品图标 + 物品链接 + 获得者 + DKP消耗
----------------------------------------------------------------------

local DKP = YTHT_DKP

-- UI 常量
local FRAME_WIDTH = 820
local FRAME_HEADER_HEIGHT = 30
local BOSS_HEADER_HEIGHT = 24
local ITEM_ROW_HEIGHT = 22
local ITEM_ICON_SIZE = 20
local ITEM_LINK_WIDTH = 280
local WINNER_WIDTH = 120
local DKP_WIDTH = 80
local ROW_SPACING = 2
local BOSS_SPACING = 8
local PADDING = 10

-- 颜色
local TITLE_COLOR = { r = 0.00, g = 0.75, b = 1.00 }
local BOSS_BG_COLOR = { r = 0.15, g = 0.15, b = 0.20, a = 0.9 }
local ITEM_BG_COLOR = { r = 0.10, g = 0.10, b = 0.15, a = 0.7 }
local ITEM_BG_ALT_COLOR = { r = 0.13, g = 0.13, b = 0.18, a = 0.7 }
local HEADER_BG_COLOR = { r = 0.08, g = 0.08, b = 0.12, a = 0.95 }

----------------------------------------------------------------------
-- Tooltip 支持
----------------------------------------------------------------------
local function ShowItemTooltip(self, itemLink)
    if not itemLink then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(itemLink)
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

----------------------------------------------------------------------
-- 创建主框架
----------------------------------------------------------------------
local function CreateMainFrame()
    local f = CreateFrame("Frame", "YTHTDKPMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, 500)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(FRAME_WIDTH, 500, 1200, 800)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(100)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- 右下角拖拽缩放手柄
    local resizeBtn = CreateFrame("Button", nil, f)
    resizeBtn:SetSize(16, 16)
    resizeBtn:SetPoint("BOTTOMRIGHT", -4, 4)
    resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeBtn:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    resizeBtn:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        -- 刷新内容适配新尺寸
        if f.scrollChild then
            f.scrollChild:SetWidth(f:GetWidth() - PADDING * 2 - 24)
        end
        if DKP.RefreshTableUI then DKP.RefreshTableUI() end
        if f.activeTab == "dkp" and DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
        if f.activeTab == "auctionlog" and DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
    end)

    -- 背景
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
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    titleBar:SetHeight(FRAME_HEADER_HEIGHT)
    titleBar:SetColorTexture(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.3)

    -- 标题文字
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    title:SetText("YTHT DKP")
    title:SetTextColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b)
    f.title = title

    -- 副本名称
    local instanceText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instanceText:SetPoint("LEFT", title, "RIGHT", 15, 0)
    instanceText:SetText("")
    instanceText:SetTextColor(0.8, 0.8, 0.8)
    f.instanceText = instanceText

    -- 活动管理按钮（主界面顶部，所有tab可见）
    local archiveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    archiveBtn:SetSize(72, 20)
    archiveBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -6)
    archiveBtn:SetText("结束归档")
    archiveBtn:SetScript("OnClick", function()
        if not DKP.IsOfficer or not DKP.IsOfficer() then
            DKP.Print("只有管理员可以归档活动")
            return
        end
        DKP.ShowArchiveDialog()
    end)
    f.archiveBtn = archiveBtn

    local activityBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    activityBtn:SetSize(72, 20)
    activityBtn:SetPoint("RIGHT", archiveBtn, "LEFT", -4, 0)
    activityBtn:SetText("历史活动")
    activityBtn:SetScript("OnClick", function()
        DKP.ShowActivityHistory()
    end)
    f.activityBtn = activityBtn

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- ========== Tab 按钮 ==========
    local TAB_HEIGHT = 22
    local tabY = -(FRAME_HEADER_HEIGHT + 4)

    local function CreateTabButton(parent, text, xOffset, tabKey)
        local tab = CreateFrame("Button", nil, parent)
        tab:SetSize(72, TAB_HEIGHT)
        tab:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, tabY)
        tab.tabKey = tabKey
        local bg = tab:CreateTexture(nil, "ARTWORK")
        bg:SetAllPoints()
        tab.bg = bg
        local label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        label:SetText(text)
        tab.label = label
        tab:SetScript("OnClick", function() DKP.SwitchTab(tabKey) end)
        return tab
    end

    local tabLoot = CreateTabButton(f, "拍卖表", PADDING, "loot")
    local tabDKP = CreateTabButton(f, "DKP管理", PADDING + 76, "dkp")
    local tabAuctionLog = CreateTabButton(f, "拍卖记录", PADDING + 76 * 2, "auctionlog")
    f.tabs = { loot = tabLoot, dkp = tabDKP, auctionlog = tabAuctionLog }
    f.activeTab = "loot"

    local contentY = tabY - TAB_HEIGHT - 4

    -- ========== 拍卖表内容 ==========
    local lootContent = CreateFrame("Frame", nil, f)
    lootContent:SetPoint("TOPLEFT", f, "TOPLEFT", 0, contentY)
    lootContent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f.lootContent = lootContent

    -- 表头（装备 / 获得者 / DKP）
    local headerBg = lootContent:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", lootContent, "TOPLEFT", PADDING, 0)
    headerBg:SetPoint("TOPRIGHT", lootContent, "TOPRIGHT", -PADDING, 0)
    headerBg:SetHeight(20)
    headerBg:SetColorTexture(HEADER_BG_COLOR.r, HEADER_BG_COLOR.g, HEADER_BG_COLOR.b, HEADER_BG_COLOR.a)

    local hItem = lootContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hItem:SetPoint("LEFT", headerBg, "LEFT", ITEM_ICON_SIZE + 6, 0)
    hItem:SetText("装备")
    hItem:SetTextColor(0.7, 0.7, 0.7)

    local hWinner = lootContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hWinner:SetPoint("LEFT", headerBg, "LEFT", ITEM_ICON_SIZE + ITEM_LINK_WIDTH + 10, 0)
    hWinner:SetText("获得者")
    hWinner:SetTextColor(0.7, 0.7, 0.7)

    local hDKP = lootContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hDKP:SetPoint("LEFT", headerBg, "LEFT", ITEM_ICON_SIZE + ITEM_LINK_WIDTH + WINNER_WIDTH + 14, 0)
    hDKP:SetText("DKP")
    hDKP:SetTextColor(0.7, 0.7, 0.7)

    -- 清空拍卖表按钮
    local clearSheetBtn = CreateFrame("Button", nil, lootContent, "UIPanelButtonTemplate")
    clearSheetBtn:SetSize(72, 18)
    clearSheetBtn:SetPoint("RIGHT", headerBg, "RIGHT", 0, 0)
    clearSheetBtn:SetText("清空拍卖表")
    clearSheetBtn:SetScript("OnClick", function()
        if not DKP.IsOfficer or not DKP.IsOfficer() then return end
        StaticPopupDialogs["YTHT_DKP_CLEAR_SHEET"] = {
            text = "确定要清空所有拍卖表吗？\n(所有副本的Boss和装备记录将被删除)",
            button1 = "确定",
            button2 = "取消",
            OnAccept = function()
                wipe(DKP.db.sheets)
                DKP.db.currentSheet = nil
                DKP.hasUnsavedChanges = true
                DKP.Print("已清空所有拍卖表")
                DKP.RefreshTableUI()
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        local popup = StaticPopup_Show("YTHT_DKP_CLEAR_SHEET")
        if popup then popup:SetFrameStrata("FULLSCREEN_DIALOG") end
    end)
    f.clearSheetBtn = clearSheetBtn

    -- 滚动区域
    local scrollFrame = CreateFrame("ScrollFrame", "YTHTDKPScrollFrame", lootContent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", lootContent, "TOPLEFT", PADDING, -22)
    scrollFrame:SetPoint("BOTTOMRIGHT", lootContent, "BOTTOMRIGHT", -PADDING - 24, PADDING)

    local scrollChild = CreateFrame("Frame", "YTHTDKPScrollChild", scrollFrame)
    scrollChild:SetWidth(FRAME_WIDTH - PADDING * 2 - 24)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    f.scrollFrame = scrollFrame
    f.scrollChild = scrollChild
    f.bossFrames = {}

    -- ========== DKP管理内容（由DKPManager填充） ==========
    local dkpContent = CreateFrame("Frame", nil, f)
    dkpContent:SetPoint("TOPLEFT", f, "TOPLEFT", 0, contentY)
    dkpContent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    dkpContent:Hide()
    f.dkpContent = dkpContent

    -- ========== 拍卖记录内容（由AuctionLog填充） ==========
    local auctionLogContent = CreateFrame("Frame", nil, f)
    auctionLogContent:SetPoint("TOPLEFT", f, "TOPLEFT", 0, contentY)
    auctionLogContent:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    auctionLogContent:Hide()
    f.auctionLogContent = auctionLogContent

    f:Hide()
    return f
end

----------------------------------------------------------------------
-- 创建Boss区域
----------------------------------------------------------------------
local function CreateBossSection(parent, bossIndex, bossName, yOffset)
    local section = CreateFrame("Frame", nil, parent)
    section:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    section:SetWidth(parent:GetWidth())
    section:SetHeight(BOSS_HEADER_HEIGHT)  -- 初始高度，后续动态调整

    -- Boss名称背景
    local bossBg = section:CreateTexture(nil, "BACKGROUND")
    bossBg:SetPoint("TOPLEFT")
    bossBg:SetPoint("TOPRIGHT")
    bossBg:SetHeight(BOSS_HEADER_HEIGHT)
    bossBg:SetColorTexture(BOSS_BG_COLOR.r, BOSS_BG_COLOR.g, BOSS_BG_COLOR.b, BOSS_BG_COLOR.a)

    -- Boss序号
    local bossNum = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bossNum:SetPoint("LEFT", bossBg, "LEFT", 6, 0)
    bossNum:SetText(bossIndex .. ".")
    bossNum:SetTextColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b)

    -- Boss名称
    local bossLabel = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bossLabel:SetPoint("LEFT", bossNum, "RIGHT", 4, 0)
    bossLabel:SetText(bossName)
    bossLabel:SetTextColor(1, 0.82, 0)

    -- 击杀状态
    local killStatus = section:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    killStatus:SetPoint("RIGHT", bossBg, "RIGHT", -8, 0)
    killStatus:SetText("")
    killStatus:SetTextColor(0, 1, 0)

    section.bossLabel = bossLabel
    section.killStatus = killStatus
    section.itemRows = {}
    section.bossName = bossName

    return section
end

----------------------------------------------------------------------
-- 创建装备行
----------------------------------------------------------------------
local function CreateItemRow(parent, itemIndex, yOffset)
    local row = CreateFrame("Button", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetWidth(parent:GetWidth())
    row:SetHeight(ITEM_ROW_HEIGHT)

    -- 背景（交替色）
    local bgColor = (itemIndex % 2 == 0) and ITEM_BG_ALT_COLOR or ITEM_BG_COLOR
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)

    -- 高亮
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    -- 物品图标
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    icon:SetSize(ITEM_ICON_SIZE, ITEM_ICON_SIZE)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- 物品链接文字
    local itemText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    itemText:SetWidth(ITEM_LINK_WIDTH - ITEM_ICON_SIZE - 6)
    itemText:SetJustifyH("LEFT")
    itemText:SetWordWrap(false)

    -- 获得者
    local winnerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    winnerText:SetPoint("LEFT", row, "LEFT", ITEM_ICON_SIZE + ITEM_LINK_WIDTH + 8, 0)
    winnerText:SetWidth(WINNER_WIDTH)
    winnerText:SetJustifyH("LEFT")
    winnerText:SetWordWrap(false)
    winnerText:SetText("")

    -- DKP 消耗
    local dkpText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dkpText:SetPoint("LEFT", row, "LEFT", ITEM_ICON_SIZE + ITEM_LINK_WIDTH + WINNER_WIDTH + 12, 0)
    dkpText:SetWidth(DKP_WIDTH)
    dkpText:SetJustifyH("RIGHT")
    dkpText:SetWordWrap(false)
    dkpText:SetText("")

    -- 拍卖按钮（管理员可见）
    local auctionBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    auctionBtn:SetSize(46, 18)
    auctionBtn:SetPoint("LEFT", row, "LEFT", ITEM_ICON_SIZE + ITEM_LINK_WIDTH + WINNER_WIDTH + DKP_WIDTH + 16, 0)
    auctionBtn:SetText("拍卖")
    auctionBtn:Hide()
    row.auctionBtn = auctionBtn

    -- 插装备按钮（手动分配）
    local manualBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    manualBtn:SetSize(50, 18)
    manualBtn:SetPoint("LEFT", auctionBtn, "RIGHT", 4, 0)
    manualBtn:SetText("插装备")
    manualBtn:Hide()
    row.manualBtn = manualBtn

    -- 删除按钮
    local delItemBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    delItemBtn:SetSize(20, 18)
    delItemBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    delItemBtn:SetText("X")
    delItemBtn:Hide()
    row.delItemBtn = delItemBtn

    -- 状态文字
    local statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("LEFT", row, "LEFT", ITEM_ICON_SIZE + ITEM_LINK_WIDTH + WINNER_WIDTH + DKP_WIDTH + 16, 0)
    statusText:SetText("")
    statusText:Hide()
    row.statusText = statusText

    -- Tooltip
    row:SetScript("OnEnter", function(self)
        if self.itemLink then
            ShowItemTooltip(self, self.itemLink)
        end
    end)
    row:SetScript("OnLeave", HideTooltip)

    -- 点击物品行为（Shift+点击发送链接到聊天）
    row:SetScript("OnClick", function(self, button)
        if self.itemLink then
            if IsShiftKeyDown() then
                ChatEdit_InsertLink(self.itemLink)
            end
        end
    end)

    row.icon = icon
    row.itemText = itemText
    row.winnerText = winnerText
    row.dkpText = dkpText
    row.itemLink = nil

    return row
end

----------------------------------------------------------------------
-- 设置装备行数据
----------------------------------------------------------------------
local function SetItemRowData(row, itemData)
    if not itemData or not itemData.link then
        row.icon:SetTexture(nil)
        row.itemText:SetText("")
        row.winnerText:SetText("")
        row.dkpText:SetText("")
        row.itemLink = nil
        row.auctionBtn:Hide()
        row.manualBtn:Hide()
        row.statusText:Hide()
        if row.delItemBtn then row.delItemBtn:Hide() end
        row:Hide()
        return
    end

    row.itemLink = itemData.link

    -- 图标
    local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemData.link)
    row.icon:SetTexture(icon)

    -- 物品名称（带品质颜色）
    local itemName, _, quality = C_Item.GetItemInfo(itemData.link)
    if itemName then
        local c = DKP.GetQualityColor(quality)
        row.itemText:SetTextColor(c.r, c.g, c.b)
        row.itemText:SetText(itemName)
    else
        row.itemText:SetText(itemData.link)
        row.itemText:SetTextColor(1, 1, 1)
        C_Item.RequestLoadItemDataByID(C_Item.GetItemInfoInstant(itemData.link))
    end

    -- 默认隐藏所有按钮和状态
    row.auctionBtn:Hide()
    row.manualBtn:Hide()
    row.statusText:Hide()

    local isOfficer = DKP.IsOfficer and DKP.IsOfficer()

    -- 清理过期的 activeAuctionID
    if itemData.activeAuctionID and not DKP.activeAuctions[itemData.activeAuctionID] then
        itemData.activeAuctionID = nil
    end

    -- 状态判断
    if itemData.activeAuctionID then
        -- 拍卖中
        row.winnerText:SetText("|cffFFFF00拍卖中|r")
        row.dkpText:SetText("")
        row.statusText:Hide()
        row.auctionBtn:SetText("查看")
        row.auctionBtn:Show()
        row.auctionBtn:SetScript("OnClick", function()
            if DKP.ShowAuctionUI then DKP.ShowAuctionUI() end
        end)
    elseif itemData.winner == "转人工" then
        -- 平局转人工
        row.winnerText:SetText("|cffFF4444转人工|r")
        if itemData.tiedAmount and itemData.tiedAmount > 0 then
            row.dkpText:SetText("|cffFFD700" .. itemData.tiedAmount .. "|r")
        else
            row.dkpText:SetText("")
        end
        if isOfficer then
            row.auctionBtn:SetText("插装备")
            row.auctionBtn:SetSize(50, 18)
            row.auctionBtn:Show()
            row.auctionBtn:SetScript("OnClick", function()
                if DKP.ShowManualAssignDialog then
                    DKP.ShowManualAssignDialog(itemData.link, itemData, row.bossData)
                end
            end)
        end
    elseif itemData.winner and itemData.winner ~= "" then
        -- 已有获胜者
        local winnerClass = itemData.winnerClass or "WARRIOR"
        row.winnerText:SetText(DKP.ClassColorText(itemData.winner, winnerClass))
        if itemData.dkp and itemData.dkp > 0 then
            row.dkpText:SetText("|cffFFD700" .. itemData.dkp .. "|r")
        else
            row.dkpText:SetText("")
        end
    else
        -- 未分配
        row.winnerText:SetText("|cff888888未分配|r")
        row.dkpText:SetText("")
        if isOfficer then
            row.auctionBtn:SetText("拍卖")
            row.auctionBtn:SetSize(46, 18)
            row.auctionBtn:Show()
            row.auctionBtn:SetScript("OnClick", function()
                if DKP.ShowAuctionStartDialog then
                    DKP.ShowAuctionStartDialog(itemData.link, itemData, row.bossData)
                end
            end)
            row.manualBtn:Show()
            row.manualBtn:SetScript("OnClick", function()
                if DKP.ShowManualAssignDialog then
                    DKP.ShowManualAssignDialog(itemData.link, itemData, row.bossData)
                end
            end)
        end
    end

    -- 删除按钮（管理员可见）
    if row.delItemBtn then
        if isOfficer then
            row.delItemBtn:Show()
            row.delItemBtn:SetScript("OnClick", function()
                if not row.bossData or not itemData then return end
                local items = row.bossData.items
                if not items then return end
                for idx, item in ipairs(items) do
                    if item == itemData then
                        table.remove(items, idx)
                        DKP.hasUnsavedChanges = true
                        DKP.RefreshTableUI()
                        return
                    end
                end
            end)
        else
            row.delItemBtn:Hide()
        end
    end

    row:Show()
end

----------------------------------------------------------------------
-- 刷新表格UI
----------------------------------------------------------------------
function DKP.RefreshTableUI()
    local f = DKP.MainFrame
    if not f or not f:IsShown() then return end

    -- 收集所有 sheets
    local hasAnySheet = false
    if DKP.db.sheets then
        for _ in pairs(DKP.db.sheets) do hasAnySheet = true; break end
    end

    if not hasAnySheet then
        f.instanceText:SetText("(无副本数据)")
        -- 清除旧区域
        for _, bossFrame in ipairs(f.bossFrames) do
            bossFrame:Hide()
            for _, row in ipairs(bossFrame.itemRows) do row:Hide() end
        end
        if f.instanceHeaders then
            for _, h in ipairs(f.instanceHeaders) do h:Hide() end
        end
        return
    end

    f.instanceText:SetText(DKP.db.currentSheet or "")

    local scrollChild = f.scrollChild
    -- 清除旧的Boss区域
    for _, bossFrame in ipairs(f.bossFrames) do
        bossFrame:Hide()
        for _, row in ipairs(bossFrame.itemRows) do
            row:Hide()
        end
    end
    if not f.instanceHeaders then f.instanceHeaders = {} end
    for _, h in ipairs(f.instanceHeaders) do h:Hide() end

    local yOffset = 0
    local bossFrameIndex = 0
    local instanceHeaderIndex = 0

    -- 遍历所有 sheets（按创建时间倒序，最新的在前）
    local sheetOrder = {}
    for name in pairs(DKP.db.sheets) do
        table.insert(sheetOrder, name)
    end
    table.sort(sheetOrder, function(a, b)
        local ta = DKP.db.sheets[a] and DKP.db.sheets[a].createdAt or 0
        local tb = DKP.db.sheets[b] and DKP.db.sheets[b].createdAt or 0
        return ta > tb
    end)

    for _, sheetName in ipairs(sheetOrder) do
        local sheet = DKP.db.sheets[sheetName]
        if not sheet then break end

        local bosses = sheet.bosses or {}
        if #bosses > 0 then
            -- 副本名称标题（含难度）
            instanceHeaderIndex = instanceHeaderIndex + 1
            local instHeader = f.instanceHeaders[instanceHeaderIndex]
            if not instHeader then
                instHeader = CreateFrame("Frame", nil, scrollChild)
                instHeader:SetHeight(20)
                local bg = instHeader:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                bg:SetColorTexture(0.15, 0.12, 0.05, 0.9)
                instHeader.bg = bg
                local text = instHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                text:SetPoint("LEFT", 8, 0)
                text:SetTextColor(0.9, 0.7, 0.2)
                instHeader.text = text
                f.instanceHeaders[instanceHeaderIndex] = instHeader
            end
            instHeader:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
            instHeader:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
            instHeader.text:SetText(sheetName)
            instHeader:Show()
            yOffset = yOffset - 22

            for bossIdx = 1, #bosses do
                local bossData = bosses[bossIdx]
                bossFrameIndex = bossFrameIndex + 1

                local bossSection = f.bossFrames[bossFrameIndex]
                if not bossSection then
                    bossSection = CreateBossSection(scrollChild, bossIdx, bossData.name, yOffset)
                    f.bossFrames[bossFrameIndex] = bossSection
                else
                    bossSection:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
                    bossSection.bossLabel:SetText(bossData.name)
                    bossSection:Show()
                end

                -- 击杀状态
                if bossData.killed then
                    bossSection.killStatus:SetText("已击杀")
                    bossSection.killStatus:SetTextColor(0, 1, 0)
                else
                    bossSection.killStatus:SetText("")
                end

                yOffset = yOffset - BOSS_HEADER_HEIGHT - ROW_SPACING

                -- 装备行
                local items = bossData.items or {}
                if #items == 0 then
                    local emptyRow = bossSection.itemRows[1]
                    if not emptyRow then
                        emptyRow = CreateItemRow(bossSection, 1, -BOSS_HEADER_HEIGHT)
                        bossSection.itemRows[1] = emptyRow
                    end
                    emptyRow.icon:SetTexture(nil)
                    emptyRow.itemText:SetText("|cff555555(暂无掉落记录)|r")
                    emptyRow.itemText:SetTextColor(0.33, 0.33, 0.33)
                    emptyRow.winnerText:SetText("")
                    emptyRow.dkpText:SetText("")
                    emptyRow.itemLink = nil
                    if emptyRow.delItemBtn then emptyRow.delItemBtn:Hide() end
                    emptyRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
                    emptyRow:SetWidth(scrollChild:GetWidth())
                    emptyRow:Show()
                    yOffset = yOffset - ITEM_ROW_HEIGHT - ROW_SPACING
                else
                    for itemIdx, itemData in ipairs(items) do
                        local itemRow = bossSection.itemRows[itemIdx]
                        if not itemRow then
                            itemRow = CreateItemRow(bossSection, itemIdx,
                                -BOSS_HEADER_HEIGHT - (itemIdx - 1) * (ITEM_ROW_HEIGHT + ROW_SPACING))
                            bossSection.itemRows[itemIdx] = itemRow
                        end
                        itemRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
                        itemRow:SetWidth(scrollChild:GetWidth())
                        itemRow.bossData = bossData
                        SetItemRowData(itemRow, itemData)
                        yOffset = yOffset - ITEM_ROW_HEIGHT - ROW_SPACING
                    end
                    for hideIdx = #items + 1, #bossSection.itemRows do
                        bossSection.itemRows[hideIdx]:Hide()
                    end
                end

                yOffset = yOffset - BOSS_SPACING
            end
        end
    end

    scrollChild:SetHeight(math.abs(yOffset) + 20)
end

----------------------------------------------------------------------
-- 获取或创建当前副本的表格
----------------------------------------------------------------------
function DKP.GetOrCreateSheet(instanceName)
    if not DKP.db.sheets[instanceName] then
        DKP.db.sheets[instanceName] = {
            bosses = {},
            createdAt = time(),
        }
    end
    DKP.db.currentSheet = instanceName
    return DKP.db.sheets[instanceName]
end

----------------------------------------------------------------------
-- 添加Boss到表格
----------------------------------------------------------------------
function DKP.AddBossToSheet(instanceName, bossName, encounterID)
    local sheet = DKP.GetOrCreateSheet(instanceName)

    -- 检查是否已存在
    for _, boss in ipairs(sheet.bosses) do
        if boss.encounterID == encounterID then
            return boss  -- 已存在，返回
        end
    end

    local bossData = {
        name = bossName,
        encounterID = encounterID,
        killed = false,
        items = {},
    }
    table.insert(sheet.bosses, bossData)
    DKP.Print("添加Boss: " .. bossName)
    return bossData
end

----------------------------------------------------------------------
-- 标记Boss击杀
----------------------------------------------------------------------
function DKP.MarkBossKilled(instanceName, encounterID)
    local sheet = DKP.db.sheets[instanceName]
    if not sheet then return end

    for _, boss in ipairs(sheet.bosses) do
        if boss.encounterID == encounterID then
            boss.killed = true
            boss.killedAt = time()
            DKP.Print(boss.name .. " 已击杀!")
            DKP.RefreshTableUI()
            return
        end
    end
end

----------------------------------------------------------------------
-- 添加物品到Boss
----------------------------------------------------------------------
function DKP.AddItemToBoss(instanceName, encounterID, itemLink, rollID)
    local sheet = DKP.db.sheets[instanceName]
    if not sheet then return end

    for _, boss in ipairs(sheet.bosses) do
        if boss.encounterID == encounterID then
            -- 检查是否已添加（通过rollID去重）
            for _, item in ipairs(boss.items) do
                if item.rollID == rollID then
                    return  -- 已存在
                end
            end

            local itemData = {
                link = itemLink,
                winner = "",
                winnerClass = "",
                dkp = 0,
                rollID = rollID,
                addedAt = time(),
            }
            table.insert(boss.items, itemData)
            DKP.RefreshTableUI()
            return itemData
        end
    end
end

----------------------------------------------------------------------
-- 切换显示/隐藏
----------------------------------------------------------------------
function DKP.ToggleMainFrame()
    if not DKP.MainFrame then return end
    if DKP.MainFrame:IsShown() then
        if DKP.hasUnsavedChanges then
            StaticPopupDialogs["YTHT_DKP_RELOAD_PROMPT"] = {
                text = "DKP数据已修改，是否重载UI以保存？\n（不重载则关闭游戏时自动保存，但崩溃会丢失）",
                button1 = "重载保存",
                button2 = "稍后关闭",
                button3 = "不保存关闭",
                OnAccept = function() ReloadUI() end,
                OnCancel = function()
                    -- button2: 稍后关闭 - 什么都不做
                end,
                OnAlt = function()
                    -- button3: 不保存关闭
                    DKP.MainFrame:Hide()
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
            local popup = StaticPopup_Show("YTHT_DKP_RELOAD_PROMPT")
            if popup then popup:SetFrameStrata("FULLSCREEN_DIALOG") end
        else
            DKP.MainFrame:Hide()
        end
    else
        DKP.MainFrame:Show()
        if DKP.MainFrame.activeTab == "loot" then
            DKP.RefreshTableUI()
        elseif DKP.RefreshDKPUI then
            DKP.RefreshDKPUI()
        end
    end
end

----------------------------------------------------------------------
-- Tab 切换
----------------------------------------------------------------------
function DKP.SwitchTab(tabKey)
    local f = DKP.MainFrame
    if not f then return end
    for key, tab in pairs(f.tabs) do
        if key == tabKey then
            tab.bg:SetColorTexture(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.3)
            tab.label:SetTextColor(1, 1, 1)
        else
            tab.bg:SetColorTexture(0.1, 0.1, 0.15, 0.5)
            tab.label:SetTextColor(0.5, 0.5, 0.5)
        end
    end
    if tabKey == "loot" then
        f.lootContent:Show()
        f.dkpContent:Hide()
        if f.auctionLogContent then f.auctionLogContent:Hide() end
        DKP.RefreshTableUI()
    elseif tabKey == "dkp" then
        f.lootContent:Hide()
        f.dkpContent:Show()
        if f.auctionLogContent then f.auctionLogContent:Hide() end
        if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    elseif tabKey == "auctionlog" then
        f.lootContent:Hide()
        f.dkpContent:Hide()
        if f.auctionLogContent then f.auctionLogContent:Show() end
        if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
    end
    f.activeTab = tabKey
end

----------------------------------------------------------------------
-- 活动归档
----------------------------------------------------------------------
function DKP.ArchiveActivity(activityName)
    if not DKP.db then return end
    if not DKP.db.activities then DKP.db.activities = {} end

    local activity = {
        name = activityName or date("%m-%d %H:%M"),
        startTime = DKP.db.session.startTime or time(),
        endTime = time(),
        log = DKP.db.log or {},
        auctionHistory = DKP.db.auctionHistory or {},
        sheets = DKP.db.sheets or {},
        currentSheet = DKP.db.currentSheet,
    }
    table.insert(DKP.db.activities, activity)

    -- 清空当前工作数据（DKP值保留）
    DKP.db.log = {}
    DKP.db.auctionHistory = {}
    DKP.db.sheets = {}
    DKP.db.currentSheet = nil

    -- 重置 session
    DKP.db.session.active = false
    DKP.db.session.gathered = false
    wipe(DKP.db.session.bossKills)
    if DKP.db.session.wipeCounts then wipe(DKP.db.session.wipeCounts) end

    DKP.hasUnsavedChanges = true
    DKP.Print("活动已归档: " .. activity.name)
    DKP.Print("操作记录: " .. #activity.log .. " 条, 拍卖记录: " .. #activity.auctionHistory .. " 条")

    -- 刷新所有UI
    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
end

local archiveDialog
function DKP.ShowArchiveDialog()
    if not archiveDialog then
        archiveDialog = CreateFrame("Frame", "YTHTDKPArchiveDialog", UIParent, "BackdropTemplate")
        local d = archiveDialog
        d:SetSize(320, 140)
        d:SetPoint("CENTER")
        d:SetFrameStrata("DIALOG")
        d:SetFrameLevel(210)
        d:SetMovable(true)
        d:EnableMouse(true)
        d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving)
        d:SetScript("OnDragStop", d.StopMovingOrSizing)
        d:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        d:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
        d:Hide()

        local title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -12)
        title:SetText("归档当前活动")

        local hint = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", 16, -35)
        hint:SetText("归档后当前记录和拍卖表将被清空，DKP保留")
        hint:SetTextColor(0.7, 0.7, 0.7)
        d.hint = hint

        local label = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", 16, -58)
        label:SetText("活动名称:")

        local nameBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        nameBox:SetSize(180, 20)
        nameBox:SetPoint("LEFT", label, "RIGHT", 8, 0)
        nameBox:SetAutoFocus(true)
        d.nameBox = nameBox

        local confirmBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        confirmBtn:SetSize(80, 24)
        confirmBtn:SetPoint("BOTTOMLEFT", 16, 10)
        confirmBtn:SetText("确定归档")
        confirmBtn:SetScript("OnClick", function()
            local name = d.nameBox:GetText():match("^%s*(.-)%s*$")
            if not name or name == "" then name = date("%m-%d %H:%M") end
            DKP.ArchiveActivity(name)
            d:Hide()
        end)

        local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 24)
        cancelBtn:SetPoint("BOTTOMRIGHT", -16, 10)
        cancelBtn:SetText("取消")
        cancelBtn:SetScript("OnClick", function() d:Hide() end)

        nameBox:SetScript("OnEnterPressed", function()
            confirmBtn:Click()
        end)
        nameBox:SetScript("OnEscapePressed", function() d:Hide() end)
    end

    -- 默认名称: 日期时间
    archiveDialog.nameBox:SetText(date("%m-%d %H:%M") .. " 开荒")

    -- 显示当前数据量
    local logCount = DKP.db.log and #DKP.db.log or 0
    local histCount = DKP.db.auctionHistory and #DKP.db.auctionHistory or 0
    local sheetCount = 0
    if DKP.db.sheets then
        for _ in pairs(DKP.db.sheets) do sheetCount = sheetCount + 1 end
    end
    archiveDialog.hint:SetText("当前: " .. logCount .. " 条记录, " .. histCount .. " 条拍卖, " .. sheetCount .. " 个副本")

    archiveDialog:Show()
    archiveDialog.nameBox:SetFocus()
end

----------------------------------------------------------------------
-- 历史活动查看
----------------------------------------------------------------------
local activityHistoryDialog

function DKP.ShowActivityHistory()
    if not activityHistoryDialog then
        local d = CreateFrame("Frame", "YTHTDKPActivityHistoryDialog", UIParent, "BackdropTemplate")
        d:SetSize(620, 440)
        d:SetPoint("CENTER")
        d:SetFrameStrata("DIALOG")
        d:SetFrameLevel(200)
        d:SetMovable(true)
        d:EnableMouse(true)
        d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving)
        d:SetScript("OnDragStop", d.StopMovingOrSizing)
        d:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        d:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
        d:Hide()

        local title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -12)
        title:SetText("历史活动")

        local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -2, -2)

        -- 滚动列表
        local sf = CreateFrame("ScrollFrame", "YTHTDKPActivityScroll", d, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -38)
        sf:SetPoint("BOTTOMRIGHT", -32, 12)

        local sc = CreateFrame("Frame", "YTHTDKPActivityScrollChild", sf)
        sc:SetWidth(560)
        sc:SetHeight(1)
        sf:SetScrollChild(sc)
        d.scrollChild = sc
        d.rows = {}

        activityHistoryDialog = d
    end

    local d = activityHistoryDialog
    local sc = d.scrollChild
    local activities = DKP.db.activities or {}

    for _, row in ipairs(d.rows) do row:Hide() end

    if #activities == 0 then
        if not d.emptyText then
            d.emptyText = sc:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            d.emptyText:SetPoint("CENTER", sc, "TOP", 0, -40)
            d.emptyText:SetText("|cff555555暂无归档活动|r")
        end
        d.emptyText:Show()
        sc:SetHeight(80)
        d:Show()
        return
    end
    if d.emptyText then d.emptyText:Hide() end

    -- 倒序显示
    local yOff = 0
    local idx = 0
    for i = #activities, 1, -1 do
        local act = activities[i]
        idx = idx + 1

        local row = d.rows[idx]
        if not row then
            row = CreateFrame("Frame", nil, sc)
            row:SetSize(560, 50)

            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            row.bg = bg

            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameText:SetPoint("TOPLEFT", 8, -6)
            nameText:SetWidth(360)
            nameText:SetJustifyH("LEFT")
            row.nameText = nameText

            local infoText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            infoText:SetPoint("TOPLEFT", 8, -24)
            infoText:SetWidth(360)
            infoText:SetJustifyH("LEFT")
            infoText:SetTextColor(0.6, 0.6, 0.6)
            row.infoText = infoText

            local viewBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            viewBtn:SetSize(40, 20)
            viewBtn:SetPoint("TOPRIGHT", -136, -14)
            viewBtn:SetText("查看")
            row.viewBtn = viewBtn

            local exportBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            exportBtn:SetSize(40, 20)
            exportBtn:SetPoint("TOPRIGHT", -92, -14)
            exportBtn:SetText("导出")
            row.exportBtn = exportBtn

            local restoreBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            restoreBtn:SetSize(40, 20)
            restoreBtn:SetPoint("TOPRIGHT", -48, -14)
            restoreBtn:SetText("恢复")
            row.restoreBtn = restoreBtn

            local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            delBtn:SetSize(40, 20)
            delBtn:SetPoint("TOPRIGHT", -4, -14)
            delBtn:SetText("删除")
            row.delBtn = delBtn

            d.rows[idx] = row
        end

        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, yOff)
        row.bg:SetColorTexture((idx % 2 == 0) and 0.13 or 0.10, (idx % 2 == 0) and 0.13 or 0.10, (idx % 2 == 0) and 0.18 or 0.15, 0.7)

        row.nameText:SetText(act.name or "未命名活动")
        local logCount = act.log and #act.log or 0
        local histCount = act.auctionHistory and #act.auctionHistory or 0
        local sheetCount = 0
        if act.sheets then for _ in pairs(act.sheets) do sheetCount = sheetCount + 1 end end
        local timeStr = date("%Y-%m-%d %H:%M", act.endTime or 0)
        row.infoText:SetText(timeStr .. "  |  记录:" .. logCount .. "  拍卖:" .. histCount .. "  副本:" .. sheetCount)

        -- 查看：临时加载归档数据到主界面查看
        row.viewBtn:SetScript("OnClick", function()
            -- 临时替换当前数据用于查看
            DKP._viewingActivity = act
            DKP._savedLog = DKP.db.log
            DKP._savedHistory = DKP.db.auctionHistory
            DKP._savedSheets = DKP.db.sheets
            DKP._savedCurrentSheet = DKP.db.currentSheet

            DKP.db.log = act.log or {}
            DKP.db.auctionHistory = act.auctionHistory or {}
            DKP.db.sheets = act.sheets or {}
            DKP.db.currentSheet = act.currentSheet

            d:Hide()
            DKP.MainFrame.instanceText:SetText("|cffFF8800[查看归档] " .. (act.name or "") .. "|r")

            -- 显示返回按钮
            if not DKP.MainFrame.returnBtn then
                local btn = CreateFrame("Button", nil, DKP.MainFrame, "UIPanelButtonTemplate")
                btn:SetSize(80, 20)
                btn:SetPoint("RIGHT", DKP.MainFrame.activityBtn, "LEFT", -4, 0)
                btn:SetText("返回当前")
                btn:SetScript("OnClick", function()
                    -- 恢复原始数据
                    if DKP._savedLog then
                        DKP.db.log = DKP._savedLog
                        DKP.db.auctionHistory = DKP._savedHistory
                        DKP.db.sheets = DKP._savedSheets
                        DKP.db.currentSheet = DKP._savedCurrentSheet
                        DKP._savedLog = nil
                        DKP._savedHistory = nil
                        DKP._savedSheets = nil
                        DKP._savedCurrentSheet = nil
                        DKP._viewingActivity = nil
                    end
                    btn:Hide()
                    DKP.RefreshTableUI()
                    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
                end)
                DKP.MainFrame.returnBtn = btn
            end
            DKP.MainFrame.returnBtn:Show()

            DKP.RefreshTableUI()
            if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
            DKP.SwitchTab("loot")
        end)

        -- 导出：使用 SerializeActivity 统一格式
        row.exportBtn:SetScript("OnClick", function()
            if DKP.SerializeActivity and DKP.ShowExportDialog then
                local text = DKP.SerializeActivity(act)
                DKP.ShowExportDialog(text)
            end
        end)

        -- 恢复：将归档数据恢复为当前工作数据
        row.restoreBtn:SetScript("OnClick", function()
            StaticPopupDialogs["YTHT_DKP_RESTORE_ACTIVITY"] = {
                text = "恢复此活动将覆盖当前的记录和拍卖表，确定吗？",
                button1 = "确定",
                button2 = "取消",
                OnAccept = function()
                    DKP.db.log = act.log or {}
                    DKP.db.auctionHistory = act.auctionHistory or {}
                    DKP.db.sheets = act.sheets or {}
                    DKP.db.currentSheet = act.currentSheet
                    DKP.hasUnsavedChanges = true
                    DKP.Print("已恢复活动: " .. (act.name or ""))
                    d:Hide()
                    DKP.RefreshTableUI()
                    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
                    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
                end,
                timeout = 0, whileDead = true, hideOnEscape = true,
            }
            local popup = StaticPopup_Show("YTHT_DKP_RESTORE_ACTIVITY")
            if popup then popup:SetFrameStrata("FULLSCREEN_DIALOG") end
        end)

        row.delBtn:SetScript("OnClick", function()
            table.remove(DKP.db.activities, i)
            DKP.hasUnsavedChanges = true
            DKP.ShowActivityHistory()
        end)

        row:Show()
        yOff = yOff - 52
    end

    sc:SetHeight(math.abs(yOff) + 10)
    d:Show()
end

----------------------------------------------------------------------
-- 初始化
----------------------------------------------------------------------
function DKP.OnInitialized()
    -- 初始化管理员列表
    if not DKP.db.admins then DKP.db.admins = {} end
    if not next(DKP.db.admins) then
        DKP.db.admins[DKP.playerName] = true
    end
    -- 首位管理员自动成为主管理员（不可被远程移除）
    if not DKP.db.masterAdmin and next(DKP.db.admins) then
        DKP.db.masterAdmin = DKP.playerName
    end

    -- 创建主框架
    DKP.MainFrame = CreateMainFrame()

    -- 恢复UI位置
    if DKP.db.point and #DKP.db.point == 5 then
        DKP.MainFrame:ClearAllPoints()
        DKP.MainFrame:SetPoint(unpack(DKP.db.point))
    end

    -- 初始化Tab
    DKP.SwitchTab("loot")

    -- 初始化DKP管理面板
    if DKP.InitDKPPanel then
        DKP.InitDKPPanel()
    end

    -- 初始化拍卖记录面板
    if DKP.InitAuctionLogPanel then
        DKP.InitAuctionLogPanel()
    end

    -- 设置当前副本表格
    if DKP.db.currentSheet and DKP.db.sheets[DKP.db.currentSheet] then
        DKP.RefreshTableUI()
    end

    -- 注册斜杠命令
    SLASH_YTHTDKP1 = "/ytht"
    SlashCmdList["YTHTDKP"] = function(msg)
        local cmd, arg1, arg2 = strsplit(" ", msg, 3)
        cmd = (cmd or ""):lower()

        if cmd == "" or cmd == "show" then
            DKP.ToggleMainFrame()
        elseif cmd == "status" then
            DKP.Print("版本: " .. DKP.version)
            DKP.Print("当前副本: " .. (DKP.db.currentSheet or "无"))
            if DKP.db.currentSheet and DKP.db.sheets[DKP.db.currentSheet] then
                local sheet = DKP.db.sheets[DKP.db.currentSheet]
                DKP.Print("Boss数量: " .. #sheet.bosses)
                local totalItems = 0
                for _, boss in ipairs(sheet.bosses) do
                    totalItems = totalItems + #boss.items
                end
                DKP.Print("装备记录: " .. totalItems)
            end
        elseif cmd == "reset" then
            if arg1 and arg1 ~= "" then
                DKP.db.sheets[arg1] = nil
                DKP.Print("已重置副本: " .. arg1)
            else
                DKP.Print("用法: /ytht reset <副本名>")
            end
        elseif cmd == "dkp" then
            DKP.MainFrame:Show()
            DKP.SwitchTab("dkp")
        elseif cmd == "gather" then
            if not DKP.IsOfficer() then
                DKP.Print("只有团长或助理可以执行集合加分")
                return
            end
            if DKP.db.session.gathered then
                DKP.Print("本次活动已经执行过集合加分")
                return
            end
            DKP.db.session.active = true
            DKP.db.session.gathered = true
            local points = DKP.db.options.gatherPoints or 3
            local members = DKP.GetRaidMembers and DKP.GetRaidMembers() or {}
            local names = {}
            for _, m in ipairs(members) do
                if m.playerName and m.online then
                    table.insert(names, m.playerName)
                end
            end
            local count = DKP.BulkAdjustDKPBatch(names, points, "集合")
            DKP.Print("集合加分: " .. count .. " 名玩家 +" .. points .. " DKP")
            local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
            if channel then
                SendChatMessage("[YTHT-DKP] 集合加分! 全团 +" .. points .. " DKP", channel)
            end
            if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end

        elseif cmd == "dismiss" then
            if not DKP.IsOfficer() then
                DKP.Print("只有团长或助理可以执行解散加分")
                return
            end
            local points = DKP.db.options.dismissPoints or 2
            local members = DKP.GetRaidMembers and DKP.GetRaidMembers() or {}
            local names = {}
            for _, m in ipairs(members) do
                if m.playerName and m.online then
                    table.insert(names, m.playerName)
                end
            end
            local count = DKP.BulkAdjustDKPBatch(names, points, "解散")
            DKP.Print("解散加分: " .. count .. " 名玩家 +" .. points .. " DKP")
            DKP.db.session.active = false
            DKP.db.session.gathered = false
            wipe(DKP.db.session.bossKills)
            if DKP.db.session.wipeCounts then wipe(DKP.db.session.wipeCounts) end
            local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
            if channel then
                SendChatMessage("[YTHT-DKP] 解散加分! 全团 +" .. points .. " DKP", channel)
            end
            if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end

        elseif cmd == "session" then
            if arg1 == "start" then
                DKP.db.session.active = true
                DKP.Print("活动开始")
            elseif arg1 == "end" or arg1 == "stop" then
                DKP.db.session.active = false
                DKP.db.session.gathered = false
                wipe(DKP.db.session.bossKills)
                if DKP.db.session.wipeCounts then wipe(DKP.db.session.wipeCounts) end
                DKP.Print("活动结束，session已重置")
            else
                DKP.Print("活动状态: " .. (DKP.db.session.active and "|cff00FF00进行中|r" or "|cffFF4444未开始|r"))
            end

        elseif cmd == "auction" then
            DKP.MainFrame:Show()
            DKP.SwitchTab("auctionlog")

        elseif cmd == "export" then
            if DKP.ShowExportDialog then
                DKP.ShowExportDialog()
            end

        elseif cmd == "bossbonus" then
            local opts = DKP.db.options
            if arg1 == "on" then
                opts.enableBossKillBonus = true
                DKP.Print("Boss击杀自动加分: |cff00FF00已启用|r")
            elseif arg1 == "off" then
                opts.enableBossKillBonus = false
                DKP.Print("Boss击杀自动加分: |cffFF4444已禁用|r")
            elseif arg1 == "points" then
                local val = tonumber(arg2)
                if val then
                    opts.bossKillPoints = val
                    DKP.Print("Boss击杀默认加分设为: " .. val)
                else
                    DKP.Print("当前Boss击杀默认加分: " .. (opts.bossKillPoints or 5))
                end
            elseif arg1 == "diff" then
                -- /ytht bossbonus diff 16 10  → 史诗难度加10分
                -- /ytht bossbonus diff 14 0   → 普通难度不加分
                local diffIDStr, diffPtsStr = strsplit(" ", arg2 or "", 2)
                local diffID = tonumber(diffIDStr)
                local diffPts = tonumber(diffPtsStr)
                if diffID and diffPts then
                    if not opts.bossKillPointsByDifficulty then
                        opts.bossKillPointsByDifficulty = {}
                    end
                    opts.bossKillPointsByDifficulty[diffID] = diffPts
                    local label = (diffPts == 0) and "|cffFF4444不加分|r" or (diffPts .. " DKP")
                    DKP.Print("难度ID " .. diffID .. " 击杀加分设为: " .. label)
                else
                    DKP.Print("用法: /ytht bossbonus diff <难度ID> <分值>")
                    DKP.Print("  难度ID: 14=普通 15=英雄 16=史诗 17=随机团")
                    DKP.Print("  分值为0表示该难度不加分")
                    if opts.bossKillPointsByDifficulty then
                        for did, dpts in pairs(opts.bossKillPointsByDifficulty) do
                            DKP.Print("  当前: 难度" .. did .. " = " .. dpts .. " DKP")
                        end
                    end
                end
            elseif arg1 == "progression" then
                local val = tonumber(arg2)
                if val then
                    opts.progressionBonusPoints = val
                    DKP.Print("开荒首杀额外加分设为: " .. val)
                else
                    DKP.Print("当前开荒首杀额外加分: " .. (opts.progressionBonusPoints or 0))
                end
            elseif arg1 == "wipe" then
                local val = tonumber(arg2)
                if val then
                    opts.wipeBonus = val
                    DKP.Print("每次团灭额外加分设为: " .. val)
                else
                    DKP.Print("当前每次团灭额外加分: " .. (opts.wipeBonus or 0))
                    DKP.Print("团灭加分上限次数: " .. (opts.wipeBonusMax or 10))
                end
            elseif arg1 == "wipemax" then
                local val = tonumber(arg2)
                if val then
                    opts.wipeBonusMax = val
                    DKP.Print("团灭加分上限次数设为: " .. val)
                else
                    DKP.Print("当前团灭加分上限次数: " .. (opts.wipeBonusMax or 10))
                end
            elseif arg1 == "firstkill" and arg2 == "reset" then
                if DKP.db.session.firstKills then
                    wipe(DKP.db.session.firstKills)
                end
                DKP.Print("首杀记录已重置")
            else
                local status = opts.enableBossKillBonus and "|cff00FF00启用|r" or "|cffFF4444禁用|r"
                DKP.Print("===== Boss击杀加分配置 =====")
                DKP.Print("状态: " .. status)
                DKP.Print("默认加分: " .. (opts.bossKillPoints or 5) .. " DKP")
                DKP.Print("首杀额外: " .. (opts.progressionBonusPoints or 0) .. " DKP")
                DKP.Print("团灭加分: " .. (opts.wipeBonus or 0) .. " DKP/次 (上限" .. (opts.wipeBonusMax or 10) .. "次)")
                if opts.bossKillPointsByDifficulty and next(opts.bossKillPointsByDifficulty) then
                    DKP.Print("难度配置:")
                    local diffNames = {[1]="普通(旧)", [2]="英雄(旧)", [14]="普通", [15]="英雄", [16]="史诗", [17]="随机团"}
                    for did, dpts in pairs(opts.bossKillPointsByDifficulty) do
                        local dname = diffNames[did] or ("ID" .. did)
                        local label = (dpts == 0) and "不加分" or (dpts .. " DKP")
                        DKP.Print("  " .. dname .. "(" .. did .. "): " .. label)
                    end
                end
                DKP.Print("命令:")
                DKP.Print("  /ytht bossbonus on|off")
                DKP.Print("  /ytht bossbonus points <分值>")
                DKP.Print("  /ytht bossbonus diff <难度ID> <分值>")
                DKP.Print("  /ytht bossbonus progression <分值>")
                DKP.Print("  /ytht bossbonus wipe <每次分值>")
                DKP.Print("  /ytht bossbonus wipemax <次数>")
                DKP.Print("  /ytht bossbonus firstkill reset")
            end

        elseif cmd == "admin" then
            if not DKP.IsOfficer() then
                DKP.Print("只有管理员可以管理管理员列表")
                return
            end
            if arg1 == "add" then
                if arg2 and arg2 ~= "" then
                    if not DKP.db.admins then DKP.db.admins = {} end
                    DKP.db.admins[arg2] = true
                    DKP.Print("已添加管理员: " .. arg2)
                    if DKP.BroadcastAdminSync then DKP.BroadcastAdminSync() end
                else
                    DKP.Print("用法: /ytht admin add <名字>")
                end
            elseif arg1 == "remove" then
                if arg2 and arg2 ~= "" then
                    if arg2 == DKP.playerName then
                        DKP.Print("不能移除自己")
                        return
                    end
                    if DKP.db.admins then
                        DKP.db.admins[arg2] = nil
                    end
                    DKP.Print("已移除管理员: " .. arg2)
                    if DKP.BroadcastAdminSync then DKP.BroadcastAdminSync() end
                else
                    DKP.Print("用法: /ytht admin remove <名字>")
                end
            elseif arg1 == "list" or not arg1 or arg1 == "" then
                DKP.Print("===== 管理员列表 =====")
                if DKP.db.admins and next(DKP.db.admins) then
                    for name in pairs(DKP.db.admins) do
                        DKP.Print("  " .. name)
                    end
                else
                    DKP.Print("  (未配置，使用团队角色判断)")
                end
            else
                DKP.Print("用法: /ytht admin add|remove|list <名字>")
            end

        elseif cmd == "debug" then
            if arg1 == "additem" then
                -- 扫描背包添加装备到拍卖表
                local instanceName = DKP.db.currentSheet or "测试副本"
                if not DKP.db.sheets[instanceName] then
                    DKP.GetOrCreateSheet(instanceName)
                end
                local bossName = "测试Boss"
                local encounterID = -1
                DKP.AddBossToSheet(instanceName, bossName, encounterID)
                local added = 0
                for bag = 0, 4 do
                    local numSlots = C_Container.GetContainerNumSlots(bag)
                    for slot = 1, numSlots do
                        local info = C_Container.GetContainerItemInfo(bag, slot)
                        if info and info.quality and info.quality >= 3 then
                            local itemLink = C_Container.GetContainerItemLink(bag, slot)
                            if itemLink then
                                local rollID = -(time() * 100 + added)
                                DKP.AddItemToBoss(instanceName, encounterID, itemLink, rollID)
                                added = added + 1
                            end
                        end
                    end
                end
                DKP.Print("已添加 " .. added .. " 件背包装备到拍卖表")
                DKP.MainFrame:Show()
                DKP.SwitchTab("loot")
                DKP.RefreshTableUI()

            elseif arg1 == "auction" then
                -- 直接发起测试拍卖
                if arg2 and arg2 ~= "" then
                    DKP.StartAuction(arg2, DKP.db.options.defaultStartingBid, DKP.db.options.auctionDuration, nil)
                else
                    DKP.Print("用法: /ytht debug auction [物品链接]")
                end

            elseif arg1 == "fakeraid" then
                -- 确保自己在DKP名单中
                local myName = DKP.playerName
                local myClass = DKP.playerClass or "WARRIOR"
                if not DKP.GetPlayerByCharacter(myName) then
                    DKP.AddPlayer(myName)
                    DKP.AddCharacter(myName, myName, myClass)
                    DKP.SetDKP(myName, 100, "调试初始化")
                    DKP.Print("已添加自己到DKP名单 (100 DKP)")
                else
                    DKP.Print("你已在DKP名单中")
                end
                if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end

            elseif arg1 == "reset" then
                wipe(DKP.activeAuctions)
                DKP.db.session.active = false
                DKP.db.session.gathered = false
                wipe(DKP.db.session.bossKills)
                if DKP.db.session.wipeCounts then wipe(DKP.db.session.wipeCounts) end
                DKP.Print("已重置所有拍卖和session状态")
                if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end

            else
                DKP.Print("调试命令:")
                DKP.Print("  /ytht debug additem    - 背包装备添加到拍卖表")
                DKP.Print("  /ytht debug auction [链接] - 直接发起测试拍卖")
                DKP.Print("  /ytht debug fakeraid   - 添加自己到DKP名单")
                DKP.Print("  /ytht debug reset      - 重置拍卖/session状态")
            end

        elseif cmd == "help" then
            DKP.Print("===== YTHT DKP 命令 =====")
            DKP.Print("/ytht            - 显示/隐藏主界面")
            DKP.Print("/ytht dkp        - 打开DKP管理界面")
            DKP.Print("/ytht auction    - 打开拍卖记录")
            DKP.Print("/ytht gather     - 集合加分")
            DKP.Print("/ytht dismiss    - 解散加分")
            DKP.Print("/ytht session    - 查看/开始/结束活动")
            DKP.Print("/ytht export     - 导出DKP数据")
            DKP.Print("/ytht admin      - 管理员列表管理")
            DKP.Print("/ytht bossbonus  - Boss击杀加分配置")
            DKP.Print("/ytht status     - 显示当前状态")
            DKP.Print("/ytht reset <名> - 重置指定副本数据")
            DKP.Print("/ytht debug      - 调试命令")
            DKP.Print("/ytht help       - 显示此帮助")
            DKP.Print("=========================")
        else
            DKP.Print("未知命令。输入 /ytht help 查看帮助。")
        end
    end

    DKP.Print("YTHT DKP v" .. DKP.version .. " 已加载。输入 /ytht 打开主界面。")
end
