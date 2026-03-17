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
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(100)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

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
    f.tabs = { loot = tabLoot, dkp = tabDKP }
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
        -- 物品信息可能还没加载，设置回调
        row.itemText:SetText(itemData.link)
        row.itemText:SetTextColor(1, 1, 1)
        C_Item.RequestLoadItemDataByID(C_Item.GetItemInfoInstant(itemData.link))
    end

    -- 获得者
    if itemData.winner and itemData.winner ~= "" then
        local winnerClass = itemData.winnerClass or "WARRIOR"
        row.winnerText:SetText(DKP.ClassColorText(itemData.winner, winnerClass))
    else
        row.winnerText:SetText("|cff888888未分配|r")
    end

    -- DKP
    if itemData.dkp and itemData.dkp > 0 then
        row.dkpText:SetText("|cffFFD700" .. itemData.dkp .. "|r")
    else
        row.dkpText:SetText("")
    end

    row:Show()
end

----------------------------------------------------------------------
-- 刷新表格UI
----------------------------------------------------------------------
function DKP.RefreshTableUI()
    local f = DKP.MainFrame
    if not f or not f:IsShown() then return end

    local sheetName = DKP.db.currentSheet
    if not sheetName then
        f.instanceText:SetText("(无副本数据)")
        return
    end

    local sheet = DKP.db.sheets[sheetName]
    if not sheet then return end

    f.instanceText:SetText(sheetName)

    local scrollChild = f.scrollChild
    -- 清除旧的Boss区域
    for _, bossFrame in ipairs(f.bossFrames) do
        bossFrame:Hide()
        for _, row in ipairs(bossFrame.itemRows) do
            row:Hide()
        end
    end

    local yOffset = 0
    local bossFrameIndex = 0

    local bosses = sheet.bosses or {}
    for bossIdx = 1, #bosses do
        local bossData = bosses[bossIdx]
        bossFrameIndex = bossFrameIndex + 1

        -- 复用或创建Boss区域
        local bossSection = f.bossFrames[bossFrameIndex]
        if not bossSection then
            bossSection = CreateBossSection(scrollChild, bossIdx, bossData.name, yOffset)
            f.bossFrames[bossFrameIndex] = bossSection
        else
            bossSection:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
            bossSection.bossLabel:SetText(bossData.name)
            bossSection:Show()
        end

        -- 更新Boss序号
        bossSection:GetChildren()  -- 确保子元素存在

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
            -- 没有装备，显示空行
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
                -- 重新定位到scrollChild坐标
                itemRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
                itemRow:SetWidth(scrollChild:GetWidth())
                SetItemRowData(itemRow, itemData)
                yOffset = yOffset - ITEM_ROW_HEIGHT - ROW_SPACING
            end
            -- 隐藏多余的行
            for hideIdx = #items + 1, #bossSection.itemRows do
                bossSection.itemRows[hideIdx]:Hide()
            end
        end

        yOffset = yOffset - BOSS_SPACING
    end

    -- 更新scrollChild高度
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
        DKP.MainFrame:Hide()
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
        DKP.RefreshTableUI()
    elseif tabKey == "dkp" then
        f.lootContent:Hide()
        f.dkpContent:Show()
        if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    end
    f.activeTab = tabKey
end

----------------------------------------------------------------------
-- 初始化
----------------------------------------------------------------------
function DKP.OnInitialized()
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
        elseif cmd == "help" then
            DKP.Print("===== YTHT DKP 命令 =====")
            DKP.Print("/ytht            - 显示/隐藏主界面")
            DKP.Print("/ytht dkp        - 打开DKP管理界面")
            DKP.Print("/ytht status     - 显示当前状态")
            DKP.Print("/ytht reset <名> - 重置指定副本数据")
            DKP.Print("/ytht help       - 显示此帮助")
            DKP.Print("=========================")
        else
            DKP.Print("未知命令。输入 /ytht help 查看帮助。")
        end
    end

    DKP.Print("YTHT DKP v" .. DKP.version .. " 已加载。输入 /ytht 打开主界面。")
end
