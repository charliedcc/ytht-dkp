----------------------------------------------------------------------
-- YTHT DKP - Auction Start Dialog
--
-- 管理员发起拍卖的对话框
----------------------------------------------------------------------

local DKP = YTHT_DKP

local TITLE_COLOR = { r = 0.00, g = 0.75, b = 1.00 }
local startDialog = nil

----------------------------------------------------------------------
-- 创建发起拍卖对话框
----------------------------------------------------------------------
local function CreateStartDialog()
    local d = CreateFrame("Frame", "YTHTDKPAuctionStartDialog", UIParent, "BackdropTemplate")
    d:SetSize(320, 200)
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
    titleText:SetText("发起拍卖")
    titleText:SetTextColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b)

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- 物品图标
    local icon = d:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", 16, -38)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    d.icon = icon

    -- 物品名
    local itemText = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    itemText:SetWidth(240)
    itemText:SetJustifyH("LEFT")
    itemText:SetWordWrap(false)
    d.itemText = itemText

    -- 起拍价
    local bidLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bidLabel:SetPoint("TOPLEFT", 16, -82)
    bidLabel:SetText("起拍价:")

    local bidBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    bidBox:SetSize(80, 20)
    bidBox:SetPoint("LEFT", bidLabel, "RIGHT", 8, 0)
    bidBox:SetAutoFocus(false)
    bidBox:SetNumeric(true)
    d.bidBox = bidBox

    local bidUnit = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bidUnit:SetPoint("LEFT", bidBox, "RIGHT", 4, 0)
    bidUnit:SetText("DKP")
    bidUnit:SetTextColor(0.6, 0.6, 0.6)

    -- 时长
    local durLabel = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    durLabel:SetPoint("TOPLEFT", 16, -112)
    durLabel:SetText("时长:")

    local durBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    durBox:SetSize(80, 20)
    durBox:SetPoint("LEFT", durLabel, "RIGHT", 8 + 20, 0)
    durBox:SetAutoFocus(false)
    durBox:SetNumeric(true)
    d.durBox = durBox

    local durUnit = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    durUnit:SetPoint("LEFT", durBox, "RIGHT", 4, 0)
    durUnit:SetText("秒")
    durUnit:SetTextColor(0.6, 0.6, 0.6)

    -- 开始按钮
    local startBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    startBtn:SetSize(80, 24)
    startBtn:SetPoint("BOTTOMLEFT", 60, 14)
    startBtn:SetText("开始拍卖")
    d.startBtn = startBtn

    -- 取消按钮
    local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 24)
    cancelBtn:SetPoint("BOTTOMRIGHT", -60, 14)
    cancelBtn:SetText("取消")
    cancelBtn:SetScript("OnClick", function() d:Hide() end)

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

----------------------------------------------------------------------
-- 显示发起拍卖对话框
----------------------------------------------------------------------
function DKP.ShowAuctionStartDialog(itemLink, itemData, bossData)
    if not DKP.IsOfficer() then
        DKP.Print("只有管理员可以发起拍卖")
        return
    end

    if not itemLink then
        DKP.Print("请指定要拍卖的物品")
        return
    end

    if not startDialog then
        startDialog = CreateStartDialog()
    end

    -- 设置物品信息
    local _, _, _, _, iconTexture = C_Item.GetItemInfoInstant(itemLink)
    startDialog.icon:SetTexture(iconTexture)

    local itemName, _, quality = C_Item.GetItemInfo(itemLink)
    if itemName then
        local c = DKP.GetQualityColor(quality)
        startDialog.itemText:SetTextColor(c.r, c.g, c.b)
        startDialog.itemText:SetText(itemName)
    else
        startDialog.itemText:SetText(itemLink)
        startDialog.itemText:SetTextColor(1, 1, 1)
    end

    -- 默认值（按副本难度确定起拍价）
    local _, _, difficultyID = GetInstanceInfo()
    local bidByDiff = DKP.db.options.defaultBidByDifficulty
    local startBid = bidByDiff and bidByDiff[difficultyID] or DKP.db.options.defaultStartingBid or 1
    startDialog.bidBox:SetText(tostring(startBid))
    startDialog.durBox:SetText(tostring(DKP.db.options.auctionDuration or 300))

    -- 存储引用
    startDialog.currentItemLink = itemLink
    startDialog.currentItemData = itemData
    startDialog.currentBossData = bossData

    -- 开始按钮回调
    startDialog.startBtn:SetScript("OnClick", function()
        local bid = tonumber(startDialog.bidBox:GetText()) or 10
        local dur = tonumber(startDialog.durBox:GetText()) or 30
        if bid < 1 then bid = 1 end
        if dur < 5 then dur = 5 end

        local encounterInfo = nil
        if startDialog.currentBossData then
            encounterInfo = {
                encounterID = startDialog.currentBossData.encounterID,
                encounterName = startDialog.currentBossData.name,
                instanceName = DKP.db.currentSheet,
                itemData = startDialog.currentItemData,
            }
        elseif startDialog.currentItemData then
            encounterInfo = {
                itemData = startDialog.currentItemData,
            }
        end

        DKP.StartAuction(startDialog.currentItemLink, bid, dur, encounterInfo)
        startDialog:Hide()
    end)

    startDialog:Show()
end
