----------------------------------------------------------------------
-- YTHT DKP - Manual Loot Assignment (插装备)
--
-- 管理员手动分配装备给指定玩家，扣除 DKP
-- 用于：直接分配、平局(转人工)解决
----------------------------------------------------------------------

local DKP = YTHT_DKP

local assignDialog = nil

----------------------------------------------------------------------
-- 创建手动分配对话框
----------------------------------------------------------------------
local function CreateAssignDialog()
    local d = CreateFrame("Frame", "YTHTDKPManualAssignDialog", UIParent, "BackdropTemplate")
    d:SetSize(600, 460)
    d:SetPoint("CENTER")
    d:SetFrameStrata("DIALOG")
    d:SetFrameLevel(210)
    d:SetMovable(true)
    d:EnableMouse(true)
    d:SetClampedToScreen(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    d:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
    d:Hide()

    -- 标题
    local titleBar = d:CreateTexture(nil, "ARTWORK")
    titleBar:SetPoint("TOPLEFT", 8, -8)
    titleBar:SetPoint("TOPRIGHT", -8, -8)
    titleBar:SetHeight(24)
    titleBar:SetColorTexture(0.15, 0.15, 0.25, 0.9)

    local titleText = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("CENTER", titleBar, "CENTER")
    titleText:SetText("手动分配装备")

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() d:Hide() end)

    -- 物品信息区
    local itemIcon = d:CreateTexture(nil, "ARTWORK")
    itemIcon:SetSize(28, 28)
    itemIcon:SetPoint("TOPLEFT", 16, -40)
    itemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    d.itemIcon = itemIcon

    local itemNameText = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemNameText:SetPoint("LEFT", itemIcon, "RIGHT", 8, 0)
    itemNameText:SetWidth(360)
    itemNameText:SetJustifyH("LEFT")
    itemNameText:SetWordWrap(false)
    d.itemNameText = itemNameText

    -- 平局信息
    local tieInfoText = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tieInfoText:SetPoint("TOPLEFT", 16, -72)
    tieInfoText:SetWidth(408)
    tieInfoText:SetJustifyH("LEFT")
    tieInfoText:SetTextColor(1, 0.5, 0)
    d.tieInfoText = tieInfoText

    -- 搜索框
    local searchLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 16, -92)
    searchLabel:SetText("搜索:")
    searchLabel:SetTextColor(0.7, 0.7, 0.7)

    local searchBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    searchBox:SetSize(120, 20)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 6, 0)
    searchBox:SetAutoFocus(false)
    d.searchBox = searchBox

    -- 玩家列表滚动区域
    local listFrame = CreateFrame("ScrollFrame", "YTHTDKPAssignPlayerScroll", d, "UIPanelScrollFrameTemplate")
    listFrame:SetPoint("TOPLEFT", 16, -116)
    listFrame:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -40, 80)

    local listChild = CreateFrame("Frame", "YTHTDKPAssignPlayerScrollChild", listFrame)
    listChild:SetWidth(listFrame:GetWidth())
    listChild:SetHeight(1)
    listFrame:SetScrollChild(listChild)
    d.listChild = listChild
    d.playerRows = {}
    d.selectedPlayer = nil

    -- DKP 消耗输入
    local dkpLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dkpLabel:SetPoint("BOTTOMLEFT", 16, 48)
    dkpLabel:SetText("DKP消耗:")

    local dkpBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    dkpBox:SetSize(80, 20)
    dkpBox:SetPoint("LEFT", dkpLabel, "RIGHT", 8, 0)
    dkpBox:SetAutoFocus(false)
    dkpBox:SetNumeric(true)
    d.dkpBox = dkpBox

    local dkpSuffix = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dkpSuffix:SetPoint("LEFT", dkpBox, "RIGHT", 4, 0)
    dkpSuffix:SetText("DKP")

    -- 确定按钮
    local confirmBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    confirmBtn:SetSize(80, 24)
    confirmBtn:SetPoint("BOTTOMRIGHT", -90, 14)
    confirmBtn:SetText("确定分配")
    d.confirmBtn = confirmBtn

    -- 取消按钮
    local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    cancelBtn:SetSize(60, 24)
    cancelBtn:SetPoint("BOTTOMRIGHT", -16, 14)
    cancelBtn:SetText("取消")
    cancelBtn:SetScript("OnClick", function() d:Hide() end)

    -- ESC 关闭
    d:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    return d
end

----------------------------------------------------------------------
-- 刷新玩家列表
----------------------------------------------------------------------
-- 职业排序权重
local CLASS_SORT_ORDER = {
    WARRIOR = 1, PALADIN = 2, DEATHKNIGHT = 3,
    HUNTER = 4, ROGUE = 5, MONK = 6,
    PRIEST = 7, SHAMAN = 8, MAGE = 9,
    WARLOCK = 10, DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}

local function RefreshPlayerList(dialog, filter)
    local listChild = dialog.listChild
    local tiedPlayerNames = {}
    if dialog.currentItemData and dialog.currentItemData.tiedBidders then
        for _, tb in ipairs(dialog.currentItemData.tiedBidders) do
            tiedPlayerNames[tb.playerName] = true
        end
    end

    -- 收集玩家列表（按角色展开，一个角色一行）
    local entries = {}
    for name, data in pairs(DKP.db.players or {}) do
        local chars = data.characters or {}
        if #chars > 0 then
            for _, char in ipairs(chars) do
                local matchFilter = not filter or filter == "" or
                    char.name:lower():find(filter:lower(), 1, true) or
                    name:lower():find(filter:lower(), 1, true)
                if matchFilter then
                    table.insert(entries, {
                        playerName = name,
                        charName = char.name,
                        class = char.class or "WARRIOR",
                        dkp = data.dkp or 0,
                        isTied = tiedPlayerNames[name] or false,
                    })
                end
            end
        else
            local matchFilter = not filter or filter == "" or name:lower():find(filter:lower(), 1, true)
            if matchFilter then
                table.insert(entries, {
                    playerName = name,
                    charName = name,
                    class = "WARRIOR",
                    dkp = data.dkp or 0,
                    isTied = tiedPlayerNames[name] or false,
                })
            end
        end
    end

    -- 排序：平局置顶，然后按职业分组，同职业按DKP降序
    table.sort(entries, function(a, b)
        if a.isTied ~= b.isTied then return a.isTied end
        local ca = CLASS_SORT_ORDER[a.class] or 99
        local cb = CLASS_SORT_ORDER[b.class] or 99
        if ca ~= cb then return ca < cb end
        return a.dkp > b.dkp
    end)

    -- 隐藏旧行
    for _, row in ipairs(dialog.playerRows) do
        row:Hide()
    end

    -- 多列布局
    local ROW_HEIGHT = 20
    local COL_WIDTH = 180
    local NUM_COLS = 3
    local COL_SPACING = 4

    for i, e in ipairs(entries) do
        local row = dialog.playerRows[i]
        if not row then
            row = CreateFrame("Button", nil, listChild)
            row:SetSize(COL_WIDTH, ROW_HEIGHT)

            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            row.bg = bg

            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.1)

            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            nameText:SetPoint("LEFT", 4, 0)
            nameText:SetWidth(COL_WIDTH - 50)
            nameText:SetJustifyH("LEFT")
            nameText:SetWordWrap(false)
            row.nameText = nameText

            local dkpText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            dkpText:SetPoint("RIGHT", -4, 0)
            dkpText:SetWidth(44)
            dkpText:SetJustifyH("RIGHT")
            row.dkpText = dkpText

            local selectBg = row:CreateTexture(nil, "ARTWORK")
            selectBg:SetAllPoints()
            selectBg:SetColorTexture(0.2, 0.4, 0.8, 0.5)
            selectBg:Hide()
            row.selectBg = selectBg

            dialog.playerRows[i] = row
        end

        -- 多列定位
        local col = (i - 1) % NUM_COLS
        local rowNum = math.floor((i - 1) / NUM_COLS)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", listChild, "TOPLEFT", col * (COL_WIDTH + COL_SPACING), -rowNum * (ROW_HEIGHT + 1))

        -- 背景
        if e.isTied then
            row.bg:SetColorTexture(0.3, 0.2, 0.05, 0.6)
        elseif rowNum % 2 == 0 then
            row.bg:SetColorTexture(0.10, 0.10, 0.15, 0.5)
        else
            row.bg:SetColorTexture(0.13, 0.13, 0.18, 0.5)
        end

        -- 角色名 + 职业颜色
        local prefix = e.isTied and "★" or ""
        row.nameText:SetText(prefix .. DKP.ClassColorText(e.charName, e.class))
        row.dkpText:SetText("|cffFFD700" .. e.dkp .. "|r")

        -- 选中状态
        if dialog.selectedPlayer == e.playerName then
            row.selectBg:Show()
        else
            row.selectBg:Hide()
        end

        row:SetScript("OnClick", function()
            dialog.selectedPlayer = e.playerName
            for _, r in ipairs(dialog.playerRows) do
                if r.selectBg then r.selectBg:Hide() end
            end
            row.selectBg:Show()
        end)

        row:Show()
    end

    local totalRows = math.ceil(#entries / NUM_COLS)
    listChild:SetHeight(math.max(1, totalRows * (ROW_HEIGHT + 1)))
end

----------------------------------------------------------------------
-- 显示手动分配对话框
----------------------------------------------------------------------
function DKP.ShowManualAssignDialog(itemLink, itemData, bossData)
    if not DKP.IsOfficer() then
        DKP.Print("只有管理员可以手动分配装备")
        return
    end

    if not assignDialog then
        assignDialog = CreateAssignDialog()
    end
    local d = assignDialog

    d.currentItemLink = itemLink
    d.currentItemData = itemData
    d.currentBossData = bossData
    d.selectedPlayer = nil

    -- 物品信息
    if itemLink then
        local _, _, _, _, iconTex = C_Item.GetItemInfoInstant(itemLink)
        d.itemIcon:SetTexture(iconTex)
        local itemName, _, quality = C_Item.GetItemInfo(itemLink)
        if itemName then
            local c = DKP.GetQualityColor(quality)
            d.itemNameText:SetTextColor(c.r, c.g, c.b)
            d.itemNameText:SetText(itemName)
        else
            d.itemNameText:SetText(itemLink)
            d.itemNameText:SetTextColor(1, 1, 1)
        end
    end

    -- 平局信息
    if itemData and itemData.tiedBidders and #itemData.tiedBidders >= 2 then
        local names = {}
        for _, tb in ipairs(itemData.tiedBidders) do
            table.insert(names, tb.name)
        end
        d.tieInfoText:SetText("平局: " .. table.concat(names, " vs ") ..
            " @ " .. (itemData.tiedAmount or 0) .. " DKP")
        d.tieInfoText:Show()
        d.dkpBox:SetText(tostring(itemData.tiedAmount or 0))
    else
        d.tieInfoText:SetText("")
        d.tieInfoText:Hide()
        d.dkpBox:SetText("")
    end

    d.searchBox:SetText("")

    -- 搜索过滤
    d.searchBox:SetScript("OnTextChanged", function(self)
        RefreshPlayerList(d, self:GetText())
    end)

    -- 刷新列表
    RefreshPlayerList(d, "")

    -- 确定按钮回调
    d.confirmBtn:SetScript("OnClick", function()
        -- 防止两个管理员同时分配同一物品
        if itemData and itemData.winner and itemData.winner ~= "" and itemData.winner ~= "转人工" then
            DKP.Print("该物品已被分配给 " .. itemData.winner)
            d:Hide()
            return
        end

        local selectedPlayer = d.selectedPlayer
        if not selectedPlayer then
            DKP.Print("请先选择一个玩家")
            return
        end

        local dkpCost = tonumber(d.dkpBox:GetText()) or 0
        local playerData = DKP.db.players[selectedPlayer]
        if not playerData then
            DKP.Print("玩家不存在: " .. selectedPlayer)
            return
        end

        -- 扣除 DKP
        if dkpCost > 0 then
            DKP.AdjustDKP(selectedPlayer, -dkpCost, "手动分配: " .. (itemLink or "物品"))
        end

        -- 查找获胜者角色和职业
        local winnerChar = selectedPlayer
        local winnerClass = "WARRIOR"
        if playerData.characters then
            for _, char in ipairs(playerData.characters) do
                winnerChar = char.name
                winnerClass = char.class or "WARRIOR"
                break
            end
        end

        -- 更新 loot table itemData（用角色名显示）
        if itemData then
            itemData.winner = winnerChar
            itemData.winnerClass = winnerClass
            itemData.dkp = dkpCost
            itemData.tiedBidders = nil
            itemData.tiedAmount = nil
            itemData.activeAuctionID = nil
        end

        -- 记录拍卖历史
        local historyEntry = {
            id = "manual_" .. time() .. "_" .. math.random(1000),
            itemLink = itemLink,
            state = "MANUAL",
            winner = selectedPlayer,
            winnerChar = winnerChar,
            winnerClass = winnerClass,
            finalBid = dkpCost,
            startBid = 0,
            bidCount = 0,
            bids = {},
            timestamp = time(),
            officer = DKP.playerName,
            encounterID = bossData and bossData.encounterID or nil,
            encounterName = bossData and bossData.name or nil,
            instanceName = DKP.db.currentSheet or nil,
        }
        table.insert(DKP.db.auctionHistory, historyEntry)

        DKP.hasUnsavedChanges = true

        -- 广播历史记录
        if DKP.BroadcastHistoryEntry then
            DKP.BroadcastHistoryEntry(historyEntry)
        end

        -- RAID 通知
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if channel then
            SendChatMessage(
                "[YTHT-DKP] 手动分配: " .. (itemLink or "物品") ..
                " -> " .. selectedPlayer ..
                (dkpCost > 0 and (" (" .. dkpCost .. " DKP)") or " (免费)"),
                channel
            )
        end

        DKP.Print("已将 " .. (itemLink or "物品") .. " 分配给 " .. selectedPlayer ..
            (dkpCost > 0 and (" (扣除 " .. dkpCost .. " DKP)") or ""))

        -- 刷新UI + 广播拍卖表变化
        if DKP.RefreshTableUI then DKP.RefreshTableUI() end
        if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
        if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
        if DKP.BroadcastSheets then DKP.BroadcastSheets() end

        d:Hide()
    end)

    d:Show()
end
