----------------------------------------------------------------------
-- YTHT DKP - DKP Manager
--
-- DKP积分管理：玩家/角色管理、积分调整、导入导出
-- 数据模型：一个玩家（人）可以对应多个角色（character）
-- players["张三"] = { dkp = 150, characters = { {name="猎人角色", class="HUNTER"}, ... } }
----------------------------------------------------------------------

local DKP = YTHT_DKP

-- 职业中文名
local CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK",
    "MONK", "DRUID", "DEMONHUNTER", "EVOKER",
}
local CLASS_NAMES = {
    WARRIOR = "战士", PALADIN = "圣骑士", HUNTER = "猎人",
    ROGUE = "盗贼", PRIEST = "牧师", DEATHKNIGHT = "死亡骑士",
    SHAMAN = "萨满", MAGE = "法师", WARLOCK = "术士",
    MONK = "武僧", DRUID = "德鲁伊", DEMONHUNTER = "恶魔猎手",
    EVOKER = "唤魔师",
}

-- UI 常量
local TOOLBAR_HEIGHT = 30
local ROW_HEIGHT = 26
local COL_NAME_WIDTH = 120
local COL_CHARS_WIDTH = 320
local COL_DKP_WIDTH = 80
local COL_OPS_WIDTH = 200
local PADDING = 10
local CONTENT_WIDTH = 820 - PADDING * 2 - 24

-- 颜色
local TITLE_COLOR = { r = 0.00, g = 0.75, b = 1.00 }
local HEADER_BG = { r = 0.08, g = 0.08, b = 0.12, a = 0.95 }
local ROW_BG = { r = 0.10, g = 0.10, b = 0.15, a = 0.7 }
local ROW_ALT_BG = { r = 0.13, g = 0.13, b = 0.18, a = 0.7 }

-- 运行时状态
local charToPlayer = {}
local sortField = "dkp"
local sortAscending = false
local searchText = ""

----------------------------------------------------------------------
-- 角色→玩家 反向查找
----------------------------------------------------------------------
local function RebuildCharLookup()
    wipe(charToPlayer)
    if not DKP.db or not DKP.db.players then return end
    for playerName, data in pairs(DKP.db.players) do
        for _, char in ipairs(data.characters or {}) do
            charToPlayer[char.name] = playerName
        end
    end
end

function DKP.GetPlayerByCharacter(charName)
    if charToPlayer[charName] then
        return charToPlayer[charName]
    end
    -- 尝试不带服务器名匹配
    local shortName = charName:match("^([^%-]+)")
    if shortName and charToPlayer[shortName] then
        return charToPlayer[shortName]
    end
    return nil
end

----------------------------------------------------------------------
-- 数据操作
----------------------------------------------------------------------
function DKP.AddPlayer(playerName)
    if not DKP.db then return false end
    if DKP.db.players[playerName] then
        DKP.Print("玩家 " .. playerName .. " 已存在")
        return false
    end
    DKP.db.players[playerName] = {
        dkp = 0,
        characters = {},
        note = "",
        lastUpdated = time(),
    }
    DKP.Print("添加玩家: " .. playerName)
    return true
end

function DKP.RemovePlayer(playerName)
    if not DKP.db or not DKP.db.players[playerName] then return false end
    DKP.db.players[playerName] = nil
    RebuildCharLookup()
    DKP.Print("移除玩家: " .. playerName)
    return true
end

function DKP.AddCharacter(playerName, charName, charClass)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return false end
    for _, char in ipairs(player.characters) do
        if char.name == charName then
            DKP.Print("角色 " .. charName .. " 已存在于 " .. playerName)
            return false
        end
    end
    table.insert(player.characters, { name = charName, class = charClass or "WARRIOR" })
    charToPlayer[charName] = playerName
    player.lastUpdated = time()
    DKP.Print("添加角色: " .. charName .. " (" .. (CLASS_NAMES[charClass] or charClass or "?") .. ") -> " .. playerName)
    return true
end

function DKP.RemoveCharacter(playerName, charName)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return false end
    for i, char in ipairs(player.characters) do
        if char.name == charName then
            table.remove(player.characters, i)
            charToPlayer[charName] = nil
            player.lastUpdated = time()
            return true
        end
    end
    return false
end

function DKP.AdjustDKP(playerName, amount, reason)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return false end
    player.dkp = (player.dkp or 0) + amount
    player.lastUpdated = time()
    table.insert(DKP.db.log, {
        type = amount >= 0 and "award" or "deduct",
        player = playerName,
        amount = amount,
        reason = reason or "",
        timestamp = time(),
        officer = DKP.playerName or "Unknown",
    })
    return true
end

function DKP.SetDKP(playerName, amount, reason)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return false end
    local old = player.dkp or 0
    player.dkp = amount
    player.lastUpdated = time()
    table.insert(DKP.db.log, {
        type = "set",
        player = playerName,
        amount = amount,
        reason = reason or ("从 " .. old .. " 设置为 " .. amount),
        timestamp = time(),
        officer = DKP.playerName or "Unknown",
    })
    return true
end

function DKP.BulkAdjustDKP(amount, reason)
    if not DKP.db then return 0 end
    local count = 0
    for playerName in pairs(DKP.db.players) do
        DKP.AdjustDKP(playerName, amount, reason)
        count = count + 1
    end
    DKP.Print("批量调整: " .. count .. " 名玩家 " .. (amount >= 0 and "+" or "") .. amount .. " DKP")
    return count
end

function DKP.ImportCSV(text)
    if not DKP.db then return 0 end
    local count = 0
    for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local parts = {}
            for part in line:gmatch("[^,]+") do
                table.insert(parts, part:match("^%s*(.-)%s*$"))
            end
            if #parts >= 2 then
                local name = parts[1]
                local dkp = tonumber(parts[2])
                if name and dkp then
                    if not DKP.db.players[name] then
                        DKP.AddPlayer(name)
                    end
                    DKP.SetDKP(name, dkp, "CSV导入")
                    if parts[3] and parts[3] ~= "" then
                        local charName = parts[3]
                        local charClass = (parts[4] or "WARRIOR"):upper()
                        if not CLASS_NAMES[charClass] then charClass = "WARRIOR" end
                        DKP.AddCharacter(name, charName, charClass)
                    end
                    count = count + 1
                end
            end
        end
    end
    RebuildCharLookup()
    DKP.Print("导入完成: " .. count .. " 条记录")
    return count
end

function DKP.RenamePlayer(oldName, newName)
    if not DKP.db or not DKP.db.players[oldName] then return false end
    if DKP.db.players[newName] then
        DKP.Print("玩家名 " .. newName .. " 已存在")
        return false
    end
    DKP.db.players[newName] = DKP.db.players[oldName]
    DKP.db.players[oldName] = nil
    for _, entry in ipairs(DKP.db.log) do
        if entry.player == oldName then
            entry.player = newName
        end
    end
    RebuildCharLookup()
    DKP.Print("玩家重命名: " .. oldName .. " -> " .. newName)
    return true
end

function DKP.RenameCharacter(playerName, oldCharName, newCharName)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return false end
    for _, char in ipairs(player.characters) do
        if char.name == oldCharName then
            charToPlayer[oldCharName] = nil
            char.name = newCharName
            charToPlayer[newCharName] = playerName
            player.lastUpdated = time()
            DKP.Print("角色重命名: " .. oldCharName .. " -> " .. newCharName)
            return true
        end
    end
    return false
end

function DKP.ChangeCharacterClass(playerName, charName, newClass)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return false end
    for _, char in ipairs(player.characters) do
        if char.name == charName then
            char.class = newClass
            player.lastUpdated = time()
            return true
        end
    end
    return false
end

function DKP.GetSortedPlayers()
    local list = {}
    if not DKP.db then return list end
    for name, data in pairs(DKP.db.players) do
        local match = false
        if searchText == "" then
            match = true
        elseif name:lower():find(searchText:lower(), 1, true) then
            match = true
        else
            for _, char in ipairs(data.characters or {}) do
                if char.name:lower():find(searchText:lower(), 1, true) then
                    match = true
                    break
                end
            end
        end
        if match then
            table.insert(list, { name = name, data = data })
        end
    end
    table.sort(list, function(a, b)
        if sortField == "dkp" then
            if sortAscending then
                return (a.data.dkp or 0) < (b.data.dkp or 0)
            else
                return (a.data.dkp or 0) > (b.data.dkp or 0)
            end
        else
            if sortAscending then
                return a.name < b.name
            else
                return a.name > b.name
            end
        end
    end)
    return list
end

----------------------------------------------------------------------
-- 通用UI辅助
----------------------------------------------------------------------
local function CreateDialogFrame(name, width, height, title)
    local d = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    d:SetSize(width, height)
    d:SetPoint("CENTER")
    d:SetFrameStrata("DIALOG")
    d:SetFrameLevel(200)
    d:SetMovable(true)
    d:EnableMouse(true)
    d:SetClampedToScreen(true)
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
    d:SetBackdropBorderColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.8)

    local titleText = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -12)
    titleText:SetText(title)
    titleText:SetTextColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b)
    d.titleText = titleText

    d:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    d:Hide()
    return d
end

local function CreateClassDropdown(parent, name, xAnchor, yAnchor, anchorTo)
    local dropdown = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
    if anchorTo then
        dropdown:SetPoint("LEFT", anchorTo, "RIGHT", xAnchor or 0, yAnchor or -2)
    else
        dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", xAnchor or 0, yAnchor or 0)
    end
    local selectedClass = "WARRIOR"
    UIDropDownMenu_SetWidth(dropdown, 110)
    UIDropDownMenu_SetText(dropdown, CLASS_NAMES["WARRIOR"])
    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, classKey in ipairs(CLASS_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            local c = DKP.GetClassColor(classKey)
            info.text = CLASS_NAMES[classKey]
            info.value = classKey
            info.colorCode = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
            info.func = function(btn)
                selectedClass = btn.value
                UIDropDownMenu_SetText(dropdown, CLASS_NAMES[btn.value])
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    dropdown.GetSelectedClass = function() return selectedClass end
    dropdown.SetSelectedClass = function(_, cls)
        selectedClass = cls
        UIDropDownMenu_SetText(dropdown, CLASS_NAMES[cls] or cls)
    end
    return dropdown
end

----------------------------------------------------------------------
-- 职业选择弹窗（共用）
----------------------------------------------------------------------
local classPicker
local classPickerCallback

local function ShowClassPicker(anchor, callback)
    if not classPicker then
        local p = CreateFrame("Frame", "YTHTDKPClassPicker", UIParent, "BackdropTemplate")
        p:SetSize(324, 104)
        p:SetFrameStrata("TOOLTIP")
        p:SetFrameLevel(300)
        p:EnableMouse(true)
        p:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        p:SetBackdropColor(0.08, 0.08, 0.12, 0.98)
        p:SetBackdropBorderColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.8)

        for i, classKey in ipairs(CLASS_ORDER) do
            local row = math.floor((i - 1) / 4)
            local col = (i - 1) % 4
            local btn = CreateFrame("Button", nil, p)
            btn:SetSize(75, 20)
            btn:SetPoint("TOPLEFT", 6 + col * 78, -6 - row * 23)

            local c = DKP.GetClassColor(classKey)
            local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("CENTER")
            label:SetText(CLASS_NAMES[classKey])
            label:SetTextColor(c.r, c.g, c.b)

            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.1)

            btn:SetScript("OnClick", function()
                if classPickerCallback then
                    classPickerCallback(classKey)
                end
                p:Hide()
            end)
        end

        p:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:SetPropagateKeyboardInput(false)
                self:Hide()
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)

        classPicker = p
    end

    classPickerCallback = callback
    classPicker:ClearAllPoints()
    classPicker:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    classPicker:Show()
end

----------------------------------------------------------------------
-- 对话框：添加玩家
----------------------------------------------------------------------
local addPlayerDialog

local function ShowAddPlayerDialog()
    if not addPlayerDialog then
        local d = CreateDialogFrame("YTHTDKPAddPlayerDialog", 340, 230, "添加玩家")

        -- 玩家名称
        local nameLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameLabel:SetPoint("TOPLEFT", 16, -40)
        nameLabel:SetText("玩家名称:")

        local nameBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        nameBox:SetSize(180, 20)
        nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
        nameBox:SetAutoFocus(false)
        d.nameBox = nameBox

        -- 角色名称
        local charLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        charLabel:SetPoint("TOPLEFT", 16, -70)
        charLabel:SetText("角色名称:")

        local charBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        charBox:SetSize(180, 20)
        charBox:SetPoint("LEFT", charLabel, "RIGHT", 8, 0)
        charBox:SetAutoFocus(false)
        d.charBox = charBox

        -- 职业
        local classLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        classLabel:SetPoint("TOPLEFT", 16, -100)
        classLabel:SetText("职业:")

        local classDropdown = CreateClassDropdown(d, "YTHTDKPAddClassDD", -8, -2, classLabel)
        d.classDropdown = classDropdown

        -- 初始DKP
        local dkpLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dkpLabel:SetPoint("TOPLEFT", 16, -140)
        dkpLabel:SetText("初始DKP:")

        local dkpBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        dkpBox:SetSize(80, 20)
        dkpBox:SetPoint("LEFT", dkpLabel, "RIGHT", 8, 0)
        dkpBox:SetAutoFocus(false)
        dkpBox:SetText("0")
        d.dkpBox = dkpBox

        -- 确定 / 取消
        local okBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        okBtn:SetSize(80, 24)
        okBtn:SetPoint("BOTTOMLEFT", 50, 14)
        okBtn:SetText("确定")
        okBtn:SetScript("OnClick", function()
            local pName = d.nameBox:GetText():match("^%s*(.-)%s*$")
            local cName = d.charBox:GetText():match("^%s*(.-)%s*$")
            local dkpVal = tonumber(d.dkpBox:GetText()) or 0
            if pName == "" then
                DKP.Print("请输入玩家名称")
                return
            end
            if DKP.AddPlayer(pName) then
                if cName ~= "" then
                    DKP.AddCharacter(pName, cName, d.classDropdown.GetSelectedClass())
                end
                if dkpVal ~= 0 then
                    DKP.SetDKP(pName, dkpVal, "初始设置")
                end
                d:Hide()
                DKP.RefreshDKPUI()
            end
        end)

        local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 24)
        cancelBtn:SetPoint("BOTTOMRIGHT", -50, 14)
        cancelBtn:SetText("取消")
        cancelBtn:SetScript("OnClick", function() d:Hide() end)

        addPlayerDialog = d
    end

    addPlayerDialog.nameBox:SetText("")
    addPlayerDialog.charBox:SetText("")
    addPlayerDialog.dkpBox:SetText("0")
    addPlayerDialog.classDropdown:SetSelectedClass("WARRIOR")
    addPlayerDialog:Show()
    addPlayerDialog.nameBox:SetFocus()
end

----------------------------------------------------------------------
-- 对话框：编辑玩家
----------------------------------------------------------------------
local editPlayerDialog
local editingPlayerName = nil

local function RefreshEditDialog() end  -- 前置声明

local function ShowEditPlayerDialog(playerName)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return end
    editingPlayerName = playerName

    if not editPlayerDialog then
        local d = CreateDialogFrame("YTHTDKPEditPlayerDialog", 440, 430, "编辑玩家")

        -- 关闭按钮
        local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -2, -2)

        -- === 重命名玩家 ===
        local renameBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        renameBtn:SetSize(60, 20)
        renameBtn:SetPoint("TOPLEFT", 16, -36)
        renameBtn:SetText("重命名")
        renameBtn:SetScript("OnClick", function()
            StaticPopupDialogs["YTHT_DKP_RENAME_PLAYER"] = {
                text = "输入新的玩家名称:",
                button1 = "确定",
                button2 = "取消",
                hasEditBox = true,
                OnShow = function(self)
                    self.editBox:SetText(editingPlayerName or "")
                    self.editBox:HighlightText()
                end,
                OnAccept = function(self)
                    local newName = self.editBox:GetText():match("^%s*(.-)%s*$")
                    if newName ~= "" and editingPlayerName and newName ~= editingPlayerName then
                        if DKP.RenamePlayer(editingPlayerName, newName) then
                            editingPlayerName = newName
                            RefreshEditDialog()
                            DKP.RefreshDKPUI()
                        end
                    end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
            StaticPopup_Show("YTHT_DKP_RENAME_PLAYER")
        end)

        -- === 角色列表 ===
        local charHeader = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        charHeader:SetPoint("TOPLEFT", 16, -64)
        charHeader:SetText("角色列表:")
        charHeader:SetTextColor(0.8, 0.8, 0.8)

        local charList = CreateFrame("Frame", nil, d)
        charList:SetPoint("TOPLEFT", 16, -82)
        charList:SetSize(408, 100)
        d.charList = charList
        d.charRows = {}

        -- 添加角色
        local addCharLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        addCharLabel:SetPoint("TOPLEFT", 16, -192)
        addCharLabel:SetText("添加角色:")
        addCharLabel:SetTextColor(0.6, 0.6, 0.6)

        local addCharBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        addCharBox:SetSize(100, 20)
        addCharBox:SetPoint("LEFT", addCharLabel, "RIGHT", 8, 0)
        addCharBox:SetAutoFocus(false)
        d.addCharBox = addCharBox

        local addClassDD = CreateClassDropdown(d, "YTHTDKPEditClassDD", 0, -2, addCharBox)
        d.addClassDD = addClassDD

        local addCharBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        addCharBtn:SetSize(50, 22)
        addCharBtn:SetPoint("TOPLEFT", 16, -218)
        addCharBtn:SetText("添加")
        addCharBtn:SetScript("OnClick", function()
            local cName = d.addCharBox:GetText():match("^%s*(.-)%s*$")
            if cName == "" then return end
            if editingPlayerName and DKP.AddCharacter(editingPlayerName, cName, d.addClassDD.GetSelectedClass()) then
                d.addCharBox:SetText("")
                RefreshEditDialog()
                DKP.RefreshDKPUI()
            end
        end)

        -- === DKP 管理 ===
        local dkpHeader = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dkpHeader:SetPoint("TOPLEFT", 16, -252)
        dkpHeader:SetText("DKP管理:")
        dkpHeader:SetTextColor(0.8, 0.8, 0.8)

        local currentDKP = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        currentDKP:SetPoint("TOPLEFT", 16, -272)
        d.currentDKP = currentDKP

        -- 设置DKP
        local setLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        setLabel:SetPoint("TOPLEFT", 16, -300)
        setLabel:SetText("设置为:")

        local setBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        setBox:SetSize(80, 20)
        setBox:SetPoint("LEFT", setLabel, "RIGHT", 8, 0)
        setBox:SetAutoFocus(false)
        d.setBox = setBox

        local setBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        setBtn:SetSize(50, 22)
        setBtn:SetPoint("LEFT", setBox, "RIGHT", 8, 0)
        setBtn:SetText("设置")
        setBtn:SetScript("OnClick", function()
            local val = tonumber(d.setBox:GetText())
            if val and editingPlayerName then
                DKP.SetDKP(editingPlayerName, val, "手动设置")
                RefreshEditDialog()
                DKP.RefreshDKPUI()
            end
        end)

        -- 调整DKP
        local adjLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        adjLabel:SetPoint("TOPLEFT", 16, -330)
        adjLabel:SetText("调整:")

        local adjBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        adjBox:SetSize(60, 20)
        adjBox:SetPoint("LEFT", adjLabel, "RIGHT", 8, 0)
        adjBox:SetAutoFocus(false)
        d.adjBox = adjBox

        local reasonLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        reasonLabel:SetPoint("LEFT", adjBox, "RIGHT", 10, 0)
        reasonLabel:SetText("原因:")

        local reasonBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        reasonBox:SetSize(140, 20)
        reasonBox:SetPoint("LEFT", reasonLabel, "RIGHT", 4, 0)
        reasonBox:SetAutoFocus(false)
        d.reasonBox = reasonBox

        local addDKPBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        addDKPBtn:SetSize(60, 22)
        addDKPBtn:SetPoint("TOPLEFT", 16, -360)
        addDKPBtn:SetText("+加分")
        addDKPBtn:SetScript("OnClick", function()
            local val = tonumber(d.adjBox:GetText())
            if val and val > 0 and editingPlayerName then
                DKP.AdjustDKP(editingPlayerName, val, d.reasonBox:GetText())
                RefreshEditDialog()
                DKP.RefreshDKPUI()
            end
        end)

        local subDKPBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        subDKPBtn:SetSize(60, 22)
        subDKPBtn:SetPoint("LEFT", addDKPBtn, "RIGHT", 8, 0)
        subDKPBtn:SetText("-扣分")
        subDKPBtn:SetScript("OnClick", function()
            local val = tonumber(d.adjBox:GetText())
            if val and val > 0 and editingPlayerName then
                DKP.AdjustDKP(editingPlayerName, -val, d.reasonBox:GetText())
                RefreshEditDialog()
                DKP.RefreshDKPUI()
            end
        end)

        editPlayerDialog = d
    end

    -- 刷新编辑对话框
    RefreshEditDialog = function()
        local d = editPlayerDialog
        if not d or not editingPlayerName then return end
        local pData = DKP.db.players[editingPlayerName]
        if not pData then d:Hide() return end

        d.titleText:SetText("编辑玩家 - " .. editingPlayerName)
        d.currentDKP:SetText("当前DKP: |cffFFD700" .. (pData.dkp or 0) .. "|r")

        -- 清除旧角色行
        for _, row in ipairs(d.charRows) do
            row:Hide()
        end

        -- 显示角色列表
        for i, char in ipairs(pData.characters or {}) do
            local row = d.charRows[i]
            if not row then
                row = CreateFrame("Frame", nil, d.charList)
                row:SetSize(408, 22)

                local charText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                charText:SetPoint("LEFT", 4, 0)
                charText:SetWidth(180)
                charText:SetJustifyH("LEFT")
                charText:SetWordWrap(false)
                row.charText = charText

                -- 改职业按钮
                local classBtn = CreateFrame("Button", nil, row)
                classBtn:SetSize(56, 18)
                classBtn:SetPoint("RIGHT", -92, 0)
                local classBtnText = classBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                classBtnText:SetPoint("CENTER")
                classBtn.text = classBtnText
                local classBtnHL = classBtn:CreateTexture(nil, "HIGHLIGHT")
                classBtnHL:SetAllPoints()
                classBtnHL:SetColorTexture(1, 1, 1, 0.1)
                row.classBtn = classBtn

                -- 改名按钮
                local renameCharBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                renameCharBtn:SetSize(36, 18)
                renameCharBtn:SetPoint("RIGHT", -50, 0)
                renameCharBtn:SetText("改名")
                row.renameCharBtn = renameCharBtn

                -- 删除按钮
                local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                delBtn:SetSize(40, 18)
                delBtn:SetPoint("RIGHT", -4, 0)
                delBtn:SetText("删除")
                row.delBtn = delBtn

                d.charRows[i] = row
            end

            row:SetPoint("TOPLEFT", d.charList, "TOPLEFT", 0, -(i - 1) * 24)
            row.charText:SetText(DKP.ClassColorText(char.name, char.class))

            -- 职业按钮显示当前职业
            local c = DKP.GetClassColor(char.class)
            row.classBtn.text:SetText(CLASS_NAMES[char.class] or char.class)
            row.classBtn.text:SetTextColor(c.r, c.g, c.b)

            local charName = char.name
            row.classBtn:SetScript("OnClick", function(self)
                ShowClassPicker(self, function(newClass)
                    if editingPlayerName then
                        DKP.ChangeCharacterClass(editingPlayerName, charName, newClass)
                        RefreshEditDialog()
                        DKP.RefreshDKPUI()
                    end
                end)
            end)

            row.renameCharBtn:SetScript("OnClick", function()
                StaticPopupDialogs["YTHT_DKP_RENAME_CHAR"] = {
                    text = "输入新的角色名:",
                    button1 = "确定",
                    button2 = "取消",
                    hasEditBox = true,
                    OnShow = function(self)
                        self.editBox:SetText(charName)
                        self.editBox:HighlightText()
                    end,
                    OnAccept = function(self)
                        local newName = self.editBox:GetText():match("^%s*(.-)%s*$")
                        if newName ~= "" and newName ~= charName and editingPlayerName then
                            DKP.RenameCharacter(editingPlayerName, charName, newName)
                            RefreshEditDialog()
                            DKP.RefreshDKPUI()
                        end
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                }
                StaticPopup_Show("YTHT_DKP_RENAME_CHAR")
            end)

            row.delBtn:SetScript("OnClick", function()
                if editingPlayerName then
                    DKP.RemoveCharacter(editingPlayerName, charName)
                    RefreshEditDialog()
                    DKP.RefreshDKPUI()
                end
            end)
            row:Show()
        end

        -- 没有角色时显示提示
        if #(pData.characters or {}) == 0 then
            local row = d.charRows[1]
            if not row then
                row = CreateFrame("Frame", nil, d.charList)
                row:SetSize(408, 22)
                local charText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                charText:SetPoint("LEFT", 4, 0)
                row.charText = charText
                row.delBtn = nil
                d.charRows[1] = row
            end
            row:SetPoint("TOPLEFT", d.charList, "TOPLEFT", 0, 0)
            row.charText:SetText("|cff555555(尚未添加角色)|r")
            if row.delBtn then row.delBtn:Hide() end
            row:Show()
        end
    end

    RefreshEditDialog()
    editPlayerDialog:Show()
end

----------------------------------------------------------------------
-- 对话框：导入CSV
----------------------------------------------------------------------
local importDialog

local function ShowImportDialog()
    if not importDialog then
        local d = CreateDialogFrame("YTHTDKPImportDialog", 460, 360, "导入DKP数据")

        local hint = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", 16, -38)
        hint:SetWidth(428)
        hint:SetText("格式: 玩家名,DKP[,角色名,职业]  每行一条\n"
            .. "例: 张三,150,猎人角色,HUNTER\n"
            .. "例: 李四,200")
        hint:SetTextColor(0.6, 0.6, 0.6)
        hint:SetJustifyH("LEFT")

        local sf = CreateFrame("ScrollFrame", "YTHTDKPImportScroll", d, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 16, -86)
        sf:SetPoint("BOTTOMRIGHT", -36, 50)

        local editBox = CreateFrame("EditBox", "YTHTDKPImportEditBox", sf)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject("ChatFontNormal")
        editBox:SetWidth(400)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        sf:SetScrollChild(editBox)
        d.editBox = editBox

        d:SetScript("OnShow", function()
            editBox:SetWidth(sf:GetWidth())
        end)

        local importBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        importBtn:SetSize(80, 24)
        importBtn:SetPoint("BOTTOMLEFT", 80, 14)
        importBtn:SetText("导入")
        importBtn:SetScript("OnClick", function()
            local text = d.editBox:GetText()
            if text and text ~= "" then
                local count = DKP.ImportCSV(text)
                DKP.RefreshDKPUI()
                if count > 0 then
                    d:Hide()
                end
            end
        end)

        local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 24)
        cancelBtn:SetPoint("BOTTOMRIGHT", -80, 14)
        cancelBtn:SetText("取消")
        cancelBtn:SetScript("OnClick", function() d:Hide() end)

        importDialog = d
    end

    importDialog.editBox:SetText("")
    importDialog:Show()
    importDialog.editBox:SetFocus()
end

----------------------------------------------------------------------
-- 对话框：批量调整
----------------------------------------------------------------------
local bulkDialog

local function ShowBulkAdjustDialog()
    if not bulkDialog then
        local d = CreateDialogFrame("YTHTDKPBulkDialog", 300, 180, "全员DKP调整")

        local amtLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        amtLabel:SetPoint("TOPLEFT", 20, -45)
        amtLabel:SetText("分值:")

        local amtBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        amtBox:SetSize(80, 20)
        amtBox:SetPoint("LEFT", amtLabel, "RIGHT", 8, 0)
        amtBox:SetAutoFocus(false)
        d.amtBox = amtBox

        local reasonLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        reasonLabel:SetPoint("TOPLEFT", 20, -75)
        reasonLabel:SetText("原因:")

        local reasonBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        reasonBox:SetSize(180, 20)
        reasonBox:SetPoint("LEFT", reasonLabel, "RIGHT", 8, 0)
        reasonBox:SetAutoFocus(false)
        d.reasonBox = reasonBox

        local addBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        addBtn:SetSize(80, 24)
        addBtn:SetPoint("BOTTOMLEFT", 16, 14)
        addBtn:SetText("全员加分")
        addBtn:SetScript("OnClick", function()
            local val = tonumber(d.amtBox:GetText())
            if val and val > 0 then
                DKP.BulkAdjustDKP(val, d.reasonBox:GetText())
                DKP.RefreshDKPUI()
                d:Hide()
            end
        end)

        local subBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        subBtn:SetSize(80, 24)
        subBtn:SetPoint("BOTTOM", 0, 14)
        subBtn:SetText("全员扣分")
        subBtn:SetScript("OnClick", function()
            local val = tonumber(d.amtBox:GetText())
            if val and val > 0 then
                DKP.BulkAdjustDKP(-val, d.reasonBox:GetText())
                DKP.RefreshDKPUI()
                d:Hide()
            end
        end)

        local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 24)
        cancelBtn:SetPoint("BOTTOMRIGHT", -16, 14)
        cancelBtn:SetText("取消")
        cancelBtn:SetScript("OnClick", function() d:Hide() end)

        bulkDialog = d
    end

    bulkDialog.amtBox:SetText("")
    bulkDialog.reasonBox:SetText("")
    bulkDialog:Show()
    bulkDialog.amtBox:SetFocus()
end

----------------------------------------------------------------------
-- 获取团队/小队成员
----------------------------------------------------------------------
local function GetRaidMembers()
    local members = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, rank, subgroup, level, class, fileName, zone, online = GetRaidRosterInfo(i)
            if name then
                -- 去掉服务器名用于匹配
                local shortName = name:match("^([^%-]+)")
                table.insert(members, {
                    name = name,
                    shortName = shortName or name,
                    class = fileName,
                    online = online,
                    playerName = DKP.GetPlayerByCharacter(name) or DKP.GetPlayerByCharacter(shortName or name),
                })
            end
        end
    elseif IsInGroup() then
        -- 自己
        local myName = UnitName("player")
        local myClass = select(2, UnitClass("player"))
        table.insert(members, {
            name = myName,
            shortName = myName,
            class = myClass,
            online = true,
            playerName = DKP.GetPlayerByCharacter(myName),
        })
        for i = 1, GetNumGroupMembers() - 1 do
            local name = UnitName("party" .. i)
            local class = select(2, UnitClass("party" .. i))
            if name then
                table.insert(members, {
                    name = name,
                    shortName = name,
                    class = class,
                    online = UnitIsConnected("party" .. i),
                    playerName = DKP.GetPlayerByCharacter(name),
                })
            end
        end
    end
    return members
end

----------------------------------------------------------------------
-- 冲红（反转日志条目）
----------------------------------------------------------------------
function DKP.ReverseLogEntry(logIndex)
    local entry = DKP.db.log[logIndex]
    if not entry then return false end
    if entry.reversed then
        DKP.Print("该记录已被冲红")
        return false
    end

    local reverseAmount = -entry.amount
    local player = DKP.db.players[entry.player]
    if player then
        player.dkp = (player.dkp or 0) + reverseAmount
        player.lastUpdated = time()
    end

    table.insert(DKP.db.log, {
        type = "reverse",
        player = entry.player,
        amount = reverseAmount,
        reason = "冲红: " .. (entry.reason or ""),
        timestamp = time(),
        officer = DKP.playerName or "Unknown",
        reversedIndex = logIndex,
    })
    entry.reversed = true

    DKP.Print("已冲红: " .. entry.player .. " " ..
        (entry.amount >= 0 and "+" or "") .. entry.amount ..
        " DKP (" .. (entry.reason or "") .. ")")
    return true
end

----------------------------------------------------------------------
-- 对话框：团队DKP操作
----------------------------------------------------------------------
local raidAwardDialog

local function ShowRaidAwardDialog()
    if not IsInGroup() and not IsInRaid() then
        DKP.Print("你不在任何队伍或团队中")
        return
    end

    if not raidAwardDialog then
        local d = CreateDialogFrame("YTHTDKPRaidAwardDialog", 480, 520, "团队DKP操作")

        -- 关闭按钮
        local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -2, -2)

        -- 分值
        local amtLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        amtLabel:SetPoint("TOPLEFT", 16, -40)
        amtLabel:SetText("分值:")

        local amtBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        amtBox:SetSize(60, 20)
        amtBox:SetPoint("LEFT", amtLabel, "RIGHT", 8, 0)
        amtBox:SetAutoFocus(false)
        d.amtBox = amtBox

        local reasonLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        reasonLabel:SetPoint("LEFT", amtBox, "RIGHT", 12, 0)
        reasonLabel:SetText("原因:")

        local reasonBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        reasonBox:SetSize(180, 20)
        reasonBox:SetPoint("LEFT", reasonLabel, "RIGHT", 4, 0)
        reasonBox:SetAutoFocus(false)
        d.reasonBox = reasonBox

        -- 预设按钮
        local presetY = -68
        local gatherBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        gatherBtn:SetSize(72, 22)
        gatherBtn:SetPoint("TOPLEFT", 16, presetY)
        gatherBtn:SetText("集合加分")
        gatherBtn:SetScript("OnClick", function()
            d.amtBox:SetText(tostring(DKP.db.options.gatherPoints or 10))
            d.reasonBox:SetText("集合")
        end)

        local dismissBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        dismissBtn:SetSize(72, 22)
        dismissBtn:SetPoint("LEFT", gatherBtn, "RIGHT", 4, 0)
        dismissBtn:SetText("解散加分")
        dismissBtn:SetScript("OnClick", function()
            d.amtBox:SetText(tostring(DKP.db.options.dismissPoints or 10))
            d.reasonBox:SetText("解散")
        end)

        local bossBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        bossBtn:SetSize(80, 22)
        bossBtn:SetPoint("LEFT", dismissBtn, "RIGHT", 4, 0)
        bossBtn:SetText("Boss击杀")
        bossBtn:SetScript("OnClick", function()
            d.amtBox:SetText(tostring(DKP.db.options.bossKillPoints or 5))
            d.reasonBox:SetText("Boss击杀")
        end)

        -- 选择按钮
        local selY = -96
        local selAllMatchedBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        selAllMatchedBtn:SetSize(80, 22)
        selAllMatchedBtn:SetPoint("TOPLEFT", 16, selY)
        selAllMatchedBtn:SetText("全选在册")
        selAllMatchedBtn:SetScript("OnClick", function()
            for _, row in ipairs(d.memberRows or {}) do
                if row:IsShown() and row.matched then
                    row.cb:SetChecked(true)
                end
            end
        end)

        local selNoneBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        selNoneBtn:SetSize(72, 22)
        selNoneBtn:SetPoint("LEFT", selAllMatchedBtn, "RIGHT", 4, 0)
        selNoneBtn:SetText("取消全选")
        selNoneBtn:SetScript("OnClick", function()
            for _, row in ipairs(d.memberRows or {}) do
                if row:IsShown() then
                    row.cb:SetChecked(false)
                end
            end
        end)

        local refreshBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        refreshBtn:SetSize(72, 22)
        refreshBtn:SetPoint("LEFT", selNoneBtn, "RIGHT", 4, 0)
        refreshBtn:SetText("刷新团队")
        refreshBtn:SetScript("OnClick", function()
            d.refreshMembers()
        end)

        -- 匹配统计
        local matchText = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        matchText:SetPoint("LEFT", refreshBtn, "RIGHT", 12, 0)
        matchText:SetTextColor(0.6, 0.6, 0.6)
        d.matchText = matchText

        -- 成员列表滚动区域
        local sf = CreateFrame("ScrollFrame", "YTHTDKPRaidScroll", d, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 16, -122)
        sf:SetPoint("BOTTOMRIGHT", -36, 50)

        local sc = CreateFrame("Frame", "YTHTDKPRaidScrollChild", sf)
        sc:SetWidth(420)
        sc:SetHeight(1)
        sf:SetScrollChild(sc)
        d.scrollChild = sc
        d.memberRows = {}

        -- 底部操作按钮
        local awardBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        awardBtn:SetSize(80, 24)
        awardBtn:SetPoint("BOTTOMLEFT", 60, 14)
        awardBtn:SetText("加分")
        awardBtn:SetScript("OnClick", function()
            local val = tonumber(d.amtBox:GetText())
            local reason = d.reasonBox:GetText()
            if not val or val <= 0 then
                DKP.Print("请输入有效的正数分值")
                return
            end
            local count = 0
            for _, row in ipairs(d.memberRows) do
                if row:IsShown() and row.cb:GetChecked() and row.playerName then
                    DKP.AdjustDKP(row.playerName, val, reason)
                    count = count + 1
                end
            end
            DKP.Print("已为 " .. count .. " 名玩家加 " .. val .. " DKP (" .. reason .. ")")
            DKP.RefreshDKPUI()
            d:Hide()
        end)

        local deductBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        deductBtn:SetSize(80, 24)
        deductBtn:SetPoint("BOTTOM", 0, 14)
        deductBtn:SetText("扣分")
        deductBtn:SetScript("OnClick", function()
            local val = tonumber(d.amtBox:GetText())
            local reason = d.reasonBox:GetText()
            if not val or val <= 0 then
                DKP.Print("请输入有效的正数分值")
                return
            end
            local count = 0
            for _, row in ipairs(d.memberRows) do
                if row:IsShown() and row.cb:GetChecked() and row.playerName then
                    DKP.AdjustDKP(row.playerName, -val, reason)
                    count = count + 1
                end
            end
            DKP.Print("已为 " .. count .. " 名玩家扣 " .. val .. " DKP (" .. reason .. ")")
            DKP.RefreshDKPUI()
            d:Hide()
        end)

        local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        cancelBtn:SetSize(80, 24)
        cancelBtn:SetPoint("BOTTOMRIGHT", -60, 14)
        cancelBtn:SetText("取消")
        cancelBtn:SetScript("OnClick", function() d:Hide() end)

        -- 刷新成员列表
        d.refreshMembers = function()
            local members = GetRaidMembers()
            local matchCount = 0
            local totalCount = #members

            for _, row in ipairs(d.memberRows) do
                row:Hide()
            end

            for i, m in ipairs(members) do
                local row = d.memberRows[i]
                if not row then
                    row = CreateFrame("Frame", nil, d.scrollChild)
                    row:SetSize(420, 22)

                    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                    cb:SetSize(22, 22)
                    cb:SetPoint("LEFT", 0, 0)
                    row.cb = cb

                    local charText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    charText:SetPoint("LEFT", cb, "RIGHT", 4, 0)
                    charText:SetWidth(160)
                    charText:SetJustifyH("LEFT")
                    charText:SetWordWrap(false)
                    row.charText = charText

                    local arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    arrow:SetPoint("LEFT", charText, "RIGHT", 4, 0)
                    arrow:SetText("->")
                    arrow:SetTextColor(0.5, 0.5, 0.5)

                    local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    playerText:SetPoint("LEFT", arrow, "RIGHT", 4, 0)
                    playerText:SetWidth(140)
                    playerText:SetJustifyH("LEFT")
                    playerText:SetWordWrap(false)
                    row.playerText = playerText

                    d.memberRows[i] = row
                end

                row:SetPoint("TOPLEFT", d.scrollChild, "TOPLEFT", 0, -(i - 1) * 24)

                -- 角色名（职业色）
                if m.class then
                    row.charText:SetText(DKP.ClassColorText(m.shortName, m.class))
                else
                    row.charText:SetText(m.shortName)
                    row.charText:SetTextColor(1, 1, 1)
                end

                -- 匹配的DKP玩家
                row.playerName = m.playerName
                row.matched = (m.playerName ~= nil)

                if m.playerName then
                    row.playerText:SetText("|cffFFD700" .. m.playerName .. "|r")
                    row.cb:SetChecked(true)
                    row.cb:Enable()
                    matchCount = matchCount + 1
                else
                    row.playerText:SetText("|cff555555(未匹配)|r")
                    row.cb:SetChecked(false)
                    row.cb:Disable()
                end

                -- 离线标记
                if not m.online then
                    row.charText:SetText(row.charText:GetText() .. " |cff888888[离线]|r")
                end

                row:Show()
            end

            d.scrollChild:SetHeight(math.max(1, totalCount * 24))
            d.matchText:SetText("匹配: " .. matchCount .. "/" .. totalCount)
        end

        raidAwardDialog = d
    end

    raidAwardDialog.amtBox:SetText("")
    raidAwardDialog.reasonBox:SetText("")
    raidAwardDialog.refreshMembers()
    raidAwardDialog:Show()
end

----------------------------------------------------------------------
-- 对话框：DKP操作记录
----------------------------------------------------------------------
local logDialog

local function FormatTimestamp(ts)
    if not ts then return "?" end
    return date("%m-%d %H:%M", ts)
end

local LOG_TYPE_NAMES = {
    award = "|cff00FF00+加分|r",
    deduct = "|cffFF4444-扣分|r",
    set = "|cffFFD700设置|r",
    reverse = "|cffFF8800冲红|r",
    bid_win = "|cffFF4444拍卖|r",
}

local function ShowLogDialog()
    if not logDialog then
        local d = CreateDialogFrame("YTHTDKPLogDialog", 640, 480, "DKP操作记录")

        local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -2, -2)

        -- 表头
        local headerY = -38
        local hBg = d:CreateTexture(nil, "ARTWORK")
        hBg:SetPoint("TOPLEFT", 12, headerY)
        hBg:SetPoint("TOPRIGHT", -12, headerY)
        hBg:SetHeight(18)
        hBg:SetColorTexture(0.08, 0.08, 0.12, 0.95)

        local headers = { { "时间", 0, 80 }, { "玩家", 82, 90 }, { "类型", 174, 60 },
            { "数额", 236, 60 }, { "原因", 298, 160 }, { "操作员", 460, 80 } }
        for _, h in ipairs(headers) do
            local t = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            t:SetPoint("TOPLEFT", hBg, "TOPLEFT", h[2] + 4, 0)
            t:SetText(h[1])
            t:SetTextColor(0.6, 0.6, 0.6)
        end

        -- 滚动区域
        local sf = CreateFrame("ScrollFrame", "YTHTDKPLogScroll", d, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, headerY - 20)
        sf:SetPoint("BOTTOMRIGHT", -32, 50)

        local sc = CreateFrame("Frame", "YTHTDKPLogScrollChild", sf)
        sc:SetWidth(590)
        sc:SetHeight(1)
        sf:SetScrollChild(sc)
        d.scrollChild = sc
        d.logRows = {}

        -- 底部统计
        local countText = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countText:SetPoint("BOTTOMLEFT", 16, 18)
        countText:SetTextColor(0.5, 0.5, 0.5)
        d.countText = countText

        local closeFooterBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        closeFooterBtn:SetSize(80, 24)
        closeFooterBtn:SetPoint("BOTTOMRIGHT", -16, 14)
        closeFooterBtn:SetText("关闭")
        closeFooterBtn:SetScript("OnClick", function() d:Hide() end)

        logDialog = d
    end

    -- 刷新记录
    local d = logDialog
    local sc = d.scrollChild
    local log = DKP.db.log or {}

    for _, row in ipairs(d.logRows) do
        row:Hide()
    end

    -- 倒序显示（最新在最上面）
    local displayIndex = 0
    for i = #log, 1, -1 do
        local entry = log[i]
        displayIndex = displayIndex + 1

        local row = d.logRows[displayIndex]
        if not row then
            row = CreateFrame("Frame", nil, sc)
            row:SetSize(590, 20)

            local bgColor = (displayIndex % 2 == 0) and ROW_ALT_BG or ROW_BG
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)
            row.bg = bg

            local timeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            timeText:SetPoint("LEFT", 4, 0)
            timeText:SetWidth(78)
            timeText:SetJustifyH("LEFT")
            row.timeText = timeText

            local playerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            playerText:SetPoint("LEFT", 86, 0)
            playerText:SetWidth(88)
            playerText:SetJustifyH("LEFT")
            playerText:SetWordWrap(false)
            row.playerText = playerText

            local typeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            typeText:SetPoint("LEFT", 178, 0)
            typeText:SetWidth(58)
            typeText:SetJustifyH("LEFT")
            row.typeText = typeText

            local amountText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            amountText:SetPoint("LEFT", 240, 0)
            amountText:SetWidth(58)
            amountText:SetJustifyH("RIGHT")
            row.amountText = amountText

            local reasonText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            reasonText:SetPoint("LEFT", 302, 0)
            reasonText:SetWidth(156)
            reasonText:SetJustifyH("LEFT")
            reasonText:SetWordWrap(false)
            row.reasonText = reasonText

            local officerText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            officerText:SetPoint("LEFT", 464, 0)
            officerText:SetWidth(60)
            officerText:SetJustifyH("LEFT")
            officerText:SetWordWrap(false)
            row.officerText = officerText

            local reverseBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            reverseBtn:SetSize(36, 18)
            reverseBtn:SetPoint("RIGHT", -2, 0)
            reverseBtn:SetText("冲红")
            row.reverseBtn = reverseBtn

            d.logRows[displayIndex] = row
        end

        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(displayIndex - 1) * 22)

        -- 交替背景色
        local bgColor = (displayIndex % 2 == 0) and ROW_ALT_BG or ROW_BG
        row.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)

        row.timeText:SetText(FormatTimestamp(entry.timestamp))
        row.timeText:SetTextColor(0.7, 0.7, 0.7)
        row.playerText:SetText(entry.player or "?")
        row.playerText:SetTextColor(1, 0.82, 0)
        row.typeText:SetText(LOG_TYPE_NAMES[entry.type] or entry.type)

        -- 数额颜色
        local amt = entry.amount or 0
        if amt >= 0 then
            row.amountText:SetText("|cff00FF00+" .. amt .. "|r")
        else
            row.amountText:SetText("|cffFF4444" .. amt .. "|r")
        end

        row.reasonText:SetText(entry.reason or "")
        row.reasonText:SetTextColor(0.8, 0.8, 0.8)
        row.officerText:SetText(entry.officer or "")
        row.officerText:SetTextColor(0.5, 0.5, 0.5)

        -- 冲红按钮
        local logIndex = i
        if entry.reversed then
            row.reverseBtn:SetText("已冲")
            row.reverseBtn:Disable()
        elseif entry.type == "reverse" then
            row.reverseBtn:SetText("冲红")
            row.reverseBtn:Disable()
        else
            row.reverseBtn:SetText("冲红")
            row.reverseBtn:Enable()
            row.reverseBtn:SetScript("OnClick", function()
                StaticPopupDialogs["YTHT_DKP_REVERSE_LOG"] = {
                    text = "确定要冲红这条记录吗？\n" ..
                        (entry.player or "") .. " " ..
                        (amt >= 0 and "+" or "") .. amt .. " DKP\n" ..
                        (entry.reason or ""),
                    button1 = "确定冲红",
                    button2 = "取消",
                    OnAccept = function()
                        DKP.ReverseLogEntry(logIndex)
                        DKP.RefreshDKPUI()
                        ShowLogDialog()  -- 刷新记录列表
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                }
                StaticPopup_Show("YTHT_DKP_REVERSE_LOG")
            end)
        end

        row:Show()
    end

    sc:SetHeight(math.max(1, displayIndex * 22))
    d.countText:SetText("共 " .. #log .. " 条记录")
    logDialog:Show()
end

----------------------------------------------------------------------
-- 创建玩家行
----------------------------------------------------------------------
local function CreatePlayerRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)

    local bgColor = (index % 2 == 0) and ROW_ALT_BG or ROW_BG
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)
    row.bg = bg

    -- 高亮
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)

    -- 玩家名
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
    nameText:SetWidth(COL_NAME_WIDTH - 8)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.nameText = nameText

    -- 角色列表
    local charsText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    charsText:SetPoint("LEFT", row, "LEFT", COL_NAME_WIDTH + 4, 0)
    charsText:SetWidth(COL_CHARS_WIDTH - 8)
    charsText:SetJustifyH("LEFT")
    charsText:SetWordWrap(false)
    row.charsText = charsText

    -- DKP
    local dkpText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dkpText:SetPoint("LEFT", row, "LEFT", COL_NAME_WIDTH + COL_CHARS_WIDTH + 4, 0)
    dkpText:SetWidth(COL_DKP_WIDTH - 8)
    dkpText:SetJustifyH("RIGHT")
    row.dkpText = dkpText

    -- 操作按钮
    local opsX = COL_NAME_WIDTH + COL_CHARS_WIDTH + COL_DKP_WIDTH + 8

    local quickAddBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    quickAddBtn:SetSize(26, 20)
    quickAddBtn:SetPoint("LEFT", row, "LEFT", opsX, 0)
    quickAddBtn:SetText("+")
    row.quickAddBtn = quickAddBtn

    local quickSubBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    quickSubBtn:SetSize(26, 20)
    quickSubBtn:SetPoint("LEFT", quickAddBtn, "RIGHT", 2, 0)
    quickSubBtn:SetText("-")
    row.quickSubBtn = quickSubBtn

    local editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    editBtn:SetSize(44, 20)
    editBtn:SetPoint("LEFT", quickSubBtn, "RIGHT", 4, 0)
    editBtn:SetText("编辑")
    row.editBtn = editBtn

    local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    delBtn:SetSize(44, 20)
    delBtn:SetPoint("LEFT", editBtn, "RIGHT", 2, 0)
    delBtn:SetText("删除")
    row.delBtn = delBtn

    return row
end

----------------------------------------------------------------------
-- 初始化DKP面板（在主框架的dkpContent中）
----------------------------------------------------------------------
function DKP.InitDKPPanel()
    local parent = DKP.MainFrame and DKP.MainFrame.dkpContent
    if not parent then return end

    -- 工具栏
    local toolbar = CreateFrame("Frame", nil, parent)
    toolbar:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, 0)
    toolbar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PADDING, 0)
    toolbar:SetHeight(TOOLBAR_HEIGHT)

    local addBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    addBtn:SetSize(72, 22)
    addBtn:SetPoint("LEFT", 0, 0)
    addBtn:SetText("添加玩家")
    addBtn:SetScript("OnClick", function() ShowAddPlayerDialog() end)

    local importBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    importBtn:SetSize(72, 22)
    importBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
    importBtn:SetText("导入CSV")
    importBtn:SetScript("OnClick", function() ShowImportDialog() end)

    local bulkBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    bulkBtn:SetSize(72, 22)
    bulkBtn:SetPoint("LEFT", importBtn, "RIGHT", 4, 0)
    bulkBtn:SetText("批量调整")
    bulkBtn:SetScript("OnClick", function() ShowBulkAdjustDialog() end)

    local raidBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    raidBtn:SetSize(72, 22)
    raidBtn:SetPoint("LEFT", bulkBtn, "RIGHT", 4, 0)
    raidBtn:SetText("团队加分")
    raidBtn:SetScript("OnClick", function() ShowRaidAwardDialog() end)

    local logBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    logBtn:SetSize(72, 22)
    logBtn:SetPoint("LEFT", raidBtn, "RIGHT", 4, 0)
    logBtn:SetText("操作记录")
    logBtn:SetScript("OnClick", function() ShowLogDialog() end)

    -- 玩家总数
    local countText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("LEFT", logBtn, "RIGHT", 12, 0)
    countText:SetTextColor(0.5, 0.5, 0.5)
    parent.countText = countText

    -- 搜索框
    local searchBox = CreateFrame("EditBox", nil, toolbar, "InputBoxTemplate")
    searchBox:SetSize(120, 20)
    searchBox:SetPoint("RIGHT", -2, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        DKP.RefreshDKPUI()
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    local searchLabel = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("RIGHT", searchBox, "LEFT", -4, 0)
    searchLabel:SetText("搜索:")
    searchLabel:SetTextColor(0.6, 0.6, 0.6)

    -- 表头
    local headerY = -TOOLBAR_HEIGHT - 2
    local headerBg = parent:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, headerY)
    headerBg:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PADDING, headerY)
    headerBg:SetHeight(20)
    headerBg:SetColorTexture(HEADER_BG.r, HEADER_BG.g, HEADER_BG.b, HEADER_BG.a)

    local function CreateSortableHeader(text, xOffset, width, key)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(width, 20)
        btn:SetPoint("TOPLEFT", headerBg, "TOPLEFT", xOffset, 0)
        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", 4, 0)
        label:SetText(text)
        label:SetTextColor(0.7, 0.7, 0.7)
        btn.label = label
        if key then
            btn:SetScript("OnClick", function()
                if sortField == key then
                    sortAscending = not sortAscending
                else
                    sortField = key
                    sortAscending = (key == "name")
                end
                DKP.RefreshDKPUI()
            end)
            btn:SetScript("OnEnter", function()
                label:SetTextColor(1, 1, 1)
            end)
            btn:SetScript("OnLeave", function()
                label:SetTextColor(0.7, 0.7, 0.7)
            end)
        end
        return btn
    end

    CreateSortableHeader("玩家名", 0, COL_NAME_WIDTH, "name")
    CreateSortableHeader("角色", COL_NAME_WIDTH, COL_CHARS_WIDTH, nil)
    CreateSortableHeader("DKP", COL_NAME_WIDTH + COL_CHARS_WIDTH, COL_DKP_WIDTH, "dkp")
    CreateSortableHeader("操作", COL_NAME_WIDTH + COL_CHARS_WIDTH + COL_DKP_WIDTH, COL_OPS_WIDTH, nil)

    -- 玩家列表滚动区域
    local scrollFrame = CreateFrame("ScrollFrame", "YTHTDKPPlayerScroll", parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, headerY - 22)
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PADDING - 24, PADDING)

    local scrollChild = CreateFrame("Frame", "YTHTDKPPlayerScrollChild", scrollFrame)
    scrollChild:SetWidth(CONTENT_WIDTH)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    parent.scrollChild = scrollChild
    parent.playerRows = {}

    RebuildCharLookup()
end

----------------------------------------------------------------------
-- 刷新DKP管理界面
----------------------------------------------------------------------
function DKP.RefreshDKPUI()
    local parent = DKP.MainFrame and DKP.MainFrame.dkpContent
    if not parent or not parent.scrollChild then return end
    if not parent:IsShown() then return end

    local scrollChild = parent.scrollChild
    local players = DKP.GetSortedPlayers()

    -- 更新玩家总数
    if parent.countText then
        local total = 0
        if DKP.db and DKP.db.players then
            for _ in pairs(DKP.db.players) do total = total + 1 end
        end
        parent.countText:SetText("共 " .. total .. " 名玩家")
    end

    for i, entry in ipairs(players) do
        local row = parent.playerRows[i]
        if not row then
            row = CreatePlayerRow(scrollChild, i)
            parent.playerRows[i] = row
        end

        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(i - 1) * (ROW_HEIGHT + 2))
        row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)

        -- 更新交替背景色
        local bgColor = (i % 2 == 0) and ROW_ALT_BG or ROW_BG
        row.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a)

        -- 玩家名
        row.nameText:SetText(entry.name)
        row.nameText:SetTextColor(1, 0.82, 0)

        -- 角色列表
        local charParts = {}
        for _, char in ipairs(entry.data.characters or {}) do
            table.insert(charParts, DKP.ClassColorText(char.name, char.class))
        end
        if #charParts > 0 then
            row.charsText:SetText(table.concat(charParts, ", "))
        else
            row.charsText:SetText("|cff555555(无角色)|r")
        end

        -- DKP
        local dkp = entry.data.dkp or 0
        if dkp >= 0 then
            row.dkpText:SetText("|cffFFD700" .. dkp .. "|r")
        else
            row.dkpText:SetText("|cffFF4444" .. dkp .. "|r")
        end

        -- 按钮回调
        local playerName = entry.name
        row.quickAddBtn:SetScript("OnClick", function()
            DKP.AdjustDKP(playerName, (DKP.db.options.bossKillPoints or 5), "快速加分")
            DKP.RefreshDKPUI()
        end)
        row.quickSubBtn:SetScript("OnClick", function()
            DKP.AdjustDKP(playerName, -(DKP.db.options.bossKillPoints or 5), "快速扣分")
            DKP.RefreshDKPUI()
        end)
        row.editBtn:SetScript("OnClick", function()
            ShowEditPlayerDialog(playerName)
        end)
        row.delBtn:SetScript("OnClick", function()
            StaticPopupDialogs["YTHT_DKP_DELETE_PLAYER"] = {
                text = "确定要删除玩家 " .. playerName .. " 吗？\n此操作不可撤销。",
                button1 = "确定",
                button2 = "取消",
                OnAccept = function()
                    DKP.RemovePlayer(playerName)
                    DKP.RefreshDKPUI()
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
            }
            StaticPopup_Show("YTHT_DKP_DELETE_PLAYER")
        end)

        row:Show()
    end

    -- 隐藏多余行
    for i = #players + 1, #parent.playerRows do
        parent.playerRows[i]:Hide()
    end

    -- 更新滚动区域高度
    scrollChild:SetHeight(math.max(1, #players * (ROW_HEIGHT + 2)))
end
