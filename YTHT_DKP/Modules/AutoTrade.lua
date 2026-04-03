----------------------------------------------------------------------
-- YTHT DKP - Auto Trade (自动交易)
--
-- 管理员（拾取者）与获得者交易时，自动将分配的装备放入交易窗口
-- 交易成功后标记物品已交易，避免重复
-- 使用完整 itemLink 匹配（区分同 ID 不同属性的装备）
----------------------------------------------------------------------

local DKP = YTHT_DKP

local pendingTradeItems = {}  -- 本次交易放入的 itemData 引用
local tradeCompleted = false   -- UI_INFO_MESSAGE 确认交易完成

-- 从 itemLink 提取匹配 key（item:ID:enchant:gem1:...）
-- 比纯 itemID 更精确，能区分不同属性的同一装备
local function GetItemMatchKey(itemLink)
    if not itemLink then return nil end
    -- 提取 |Hitem:xxxxx:...:| 部分
    local itemString = itemLink:match("|H(item:[^|]+)|h")
    return itemString
end

-- 安全获取交易对象名（兼容不同 WoW 版本）
local function SafeGetTradePlayerName()
    -- 方法1: GetTradePlayerName API
    if GetTradePlayerName then
        local ok, name = pcall(GetTradePlayerName)
        if ok and name then return name end
    end
    -- 方法2: 从交易窗口 UI 元素读取
    if TradeFrameRecipientNameText then
        local ok, text = pcall(function() return TradeFrameRecipientNameText:GetText() end)
        if ok and text and text ~= "" then return text end
    end
    -- 方法3: UnitName("NPC") — 交易时对方有时注册为 NPC target
    if UnitName then
        local ok, name = pcall(UnitName, "NPC")
        if ok and name then return name end
    end
    return nil
end

local f = CreateFrame("Frame")
f:RegisterEvent("TRADE_SHOW")
f:RegisterEvent("UI_INFO_MESSAGE")
f:RegisterEvent("TRADE_REQUEST_CANCEL")
f:RegisterEvent("TRADE_CLOSED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "TRADE_SHOW" then
        DKP.Print("[AutoTrade] TRADE_SHOW triggered, mode=" .. tostring(DKP.db and DKP.db.mode or "nil"))

        local ok, err = pcall(function()
        -- 只有管理模式触发自动交易
        if not DKP.IsAdminMode or not DKP.IsAdminMode() then
            DKP.Print("[AutoTrade] skip: not admin mode (mode=" .. tostring(DKP.db and DKP.db.mode or "nil") .. ")")
            return
        end
        DKP.Print("[AutoTrade] admin check passed")

        if not DKP.db or not DKP.db.sheets then
            DKP.Print("[AutoTrade] skip: no sheets data")
            return
        end
        local sheetCount = 0
        for _ in pairs(DKP.db.sheets) do sheetCount = sheetCount + 1 end
        DKP.Print("[AutoTrade] sheets check passed, " .. sheetCount .. " sheets")

        wipe(pendingTradeItems)

        DKP.Print("[AutoTrade] calling SafeGetTradePlayerName...")
        local tradeName = SafeGetTradePlayerName()
        if not tradeName then
            DKP.Print("[AutoTrade] skip: trade player name is nil (GetTradePlayerName=" .. tostring(GetTradePlayerName ~= nil) .. ", TradeFrameRecipientNameText=" .. tostring(TradeFrameRecipientNameText ~= nil) .. ")")
            return
        end

        local tradeShort = tradeName
        local dashPos = tradeName:find("-", 1, true)
        if dashPos then tradeShort = tradeName:sub(1, dashPos - 1) end
        DKP.Print("[AutoTrade] trade partner: " .. tradeName .. " (short: " .. tradeShort .. ")")

        -- 查找分配给该玩家且未交易的物品
        local itemsToTrade = {}
        local scannedItems = 0
        for sheetName, sheet in pairs(DKP.db.sheets) do
            for _, boss in ipairs(sheet.bosses or {}) do
                for _, item in ipairs(boss.items or {}) do
                    scannedItems = scannedItems + 1
                    if item.winner and item.winner ~= "" and item.link and not item.traded then
                        local winnerShort = item.winner
                        local dp = item.winner:find("-", 1, true)
                        if dp then winnerShort = item.winner:sub(1, dp - 1) end

                        local itemName = item.link:match("%[(.-)%]") or item.link
                        if winnerShort == tradeShort or item.winner == tradeName then
                            DKP.Print("[AutoTrade] match: " .. itemName .. " winner=" .. item.winner .. " (sheet: " .. sheetName .. ")")
                            table.insert(itemsToTrade, {
                                itemData = item,
                                link = item.link,
                                matchKey = GetItemMatchKey(item.link),
                            })
                        else
                            DKP.Print("[AutoTrade] no match: " .. itemName .. " winner=" .. item.winner .. " vs trade=" .. tradeShort .. " (traded=" .. tostring(item.traded) .. ")")
                        end
                    end
                end
            end
        end

        DKP.Print("[AutoTrade] scanned " .. scannedItems .. " items, found " .. #itemsToTrade .. " to trade")
        if #itemsToTrade == 0 then return end

        -- 在背包里查找并放入交易窗
        local placed = 0
        local usedSlots = {}  -- 防止同一格子被匹配两次

        for i, entry in ipairs(itemsToTrade) do
            local found = false
            local entryName = entry.link:match("%[(.-)%]") or entry.link
            DKP.Print("[AutoTrade] searching bags for: " .. entryName .. " matchKey=" .. tostring(entry.matchKey))
            for bag = 0, 4 do
                local numSlots = C_Container.GetContainerNumSlots(bag)
                for slot = 1, numSlots do
                    local slotKey = bag .. ":" .. slot
                    if not usedSlots[slotKey] then
                        local bagLink = C_Container.GetContainerItemLink(bag, slot)
                        if bagLink then
                            -- 优先用完整 itemString 匹配（区分属性）
                            local bagMatchKey = GetItemMatchKey(bagLink)
                            local isMatch = false
                            if entry.matchKey and bagMatchKey then
                                isMatch = (entry.matchKey == bagMatchKey)
                            else
                                -- fallback: itemID 匹配
                                local targetID = C_Item.GetItemInfoInstant(entry.link)
                                local bagID = C_Item.GetItemInfoInstant(bagLink)
                                isMatch = (targetID and bagID and targetID == bagID)
                                if not isMatch then
                                    DKP.Print("[AutoTrade] fallback miss: targetID=" .. tostring(targetID) .. " bagID=" .. tostring(bagID))
                                end
                            end

                            if isMatch then
                                DKP.Print("[AutoTrade] bag match found at bag=" .. bag .. " slot=" .. slot .. " placing to trade slot " .. (placed + 1))
                                local tradeSlot = placed + 1
                                C_Container.PickupContainerItem(bag, slot)
                                -- Defer ClickTradeButton by one frame to ensure
                                -- the cursor has picked up the item before placing
                                C_Timer.After(0, function()
                                    ClickTradeButton(tradeSlot)
                                end)
                                placed = placed + 1
                                found = true
                                usedSlots[slotKey] = true
                                table.insert(pendingTradeItems, entry.itemData)

                                local itemName = bagLink:match("%[(.-)%]") or bagLink
                                DKP.Print("自动交易: " .. itemName .. " → " .. tradeShort)
                                break
                            end
                        end
                    end
                end
                if found then break end
            end
            if not found then
                DKP.Print("[AutoTrade] WARNING: " .. entryName .. " not found in bags!")
            end
            if placed >= 6 then break end
        end

        DKP.Print("[AutoTrade] summary: " .. #itemsToTrade .. " candidates, " .. placed .. " placed")
        if placed > 0 then
            DKP.Print("已放入 " .. placed .. " 件装备 (请手动确认交易)")
        end

        end) -- pcall end
        if not ok then
            DKP.Print("[AutoTrade] ERROR: " .. tostring(err))
        end

    elseif event == "UI_INFO_MESSAGE" then
        local _, message = ...
        if message == ERR_TRADE_COMPLETE then
            -- 交易成功完成，标记所有 pending 物品为已交易
            tradeCompleted = true
            for _, itemData in ipairs(pendingTradeItems) do
                itemData.traded = true
            end
            if #pendingTradeItems > 0 then
                DKP.Print("交易完成，" .. #pendingTradeItems .. " 件装备已标记为已交易")
                DKP.hasUnsavedChanges = true
            end
            wipe(pendingTradeItems)
        elseif message == ERR_TRADE_CANCELLED
            or message == ERR_TRADE_BAG_FULL
            or message == ERR_TRADE_TARGET_BAG_FULL then
            -- 交易失败，清空 pending 但不标记 traded
            if #pendingTradeItems > 0 then
                DKP.Print("[AutoTrade] 交易失败 (" .. message .. ")，" .. #pendingTradeItems .. " 件装备未标记")
            end
            wipe(pendingTradeItems)
        end

    elseif event == "TRADE_REQUEST_CANCEL" then
        -- 交易被取消
        if #pendingTradeItems > 0 then
            DKP.Print("[AutoTrade] 交易取消，" .. #pendingTradeItems .. " 件装备未标记")
        end
        wipe(pendingTradeItems)

    elseif event == "TRADE_CLOSED" then
        -- 兜底 cleanup：交易窗口关闭
        if #pendingTradeItems > 0 and not tradeCompleted then
            DKP.Print("[AutoTrade] 交易窗口关闭（未检测到完成信号），" .. #pendingTradeItems .. " 件装备未标记")
        end
        wipe(pendingTradeItems)
        tradeCompleted = false
    end
end)
