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

local f = CreateFrame("Frame")
f:RegisterEvent("TRADE_SHOW")
f:RegisterEvent("UI_INFO_MESSAGE")
f:RegisterEvent("TRADE_REQUEST_CANCEL")
f:RegisterEvent("TRADE_CLOSED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "TRADE_SHOW" then
        -- 只有管理模式触发自动交易
        if not DKP.IsAdminMode or not DKP.IsAdminMode() then return end
        if not DKP.db or not DKP.db.sheets then return end

        wipe(pendingTradeItems)

        -- GetTradePlayerName may not exist in WoW 12.0; fallback to UI text
        local tradeName
        if GetTradePlayerName then
            local ok, name = pcall(GetTradePlayerName)
            if ok then tradeName = name end
        end
        if not tradeName and TradeFrameRecipientNameText then
            tradeName = TradeFrameRecipientNameText:GetText()
        end
        if not tradeName or tradeName == "" then return end

        -- 提取纯角色名：去掉 "-服务器" 和 "(*)" 跨服标记
        local tradeShort = tradeName
        tradeShort = tradeShort:gsub("%(%*%)", "")       -- 去掉 (*)
        tradeShort = tradeShort:gsub("%s+$", "")         -- 去掉尾部空格
        local dashPos = tradeShort:find("-", 1, true)
        if dashPos then tradeShort = tradeShort:sub(1, dashPos - 1) end

        -- 查找分配给该玩家且未交易的物品
        local itemsToTrade = {}
        for sheetName, sheet in pairs(DKP.db.sheets) do
            for _, boss in ipairs(sheet.bosses or {}) do
                for _, item in ipairs(boss.items or {}) do
                    if item.winner and item.winner ~= "" and item.link and not item.traded then
                        local winnerShort = item.winner
                        local dp = item.winner:find("-", 1, true)
                        if dp then winnerShort = item.winner:sub(1, dp - 1) end

                        if winnerShort == tradeShort or item.winner == tradeName then
                            table.insert(itemsToTrade, {
                                itemData = item,
                                link = item.link,
                                matchKey = GetItemMatchKey(item.link),
                            })
                        end
                    end
                end
            end
        end

        if #itemsToTrade == 0 then return end

        -- 在背包里查找并放入交易窗
        local placed = 0
        local usedSlots = {}  -- 防止同一格子被匹配两次

        for i, entry in ipairs(itemsToTrade) do
            local found = false
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
                            end

                            if isMatch then
                                local tradeSlot = placed + 1
                                C_Container.PickupContainerItem(bag, slot)
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
            if placed >= 6 then break end
        end

        if placed > 0 then
            DKP.Print("已放入 " .. placed .. " 件装备 (请手动确认交易)")
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
                DKP.Print("交易失败，" .. #pendingTradeItems .. " 件装备未标记")
            end
            wipe(pendingTradeItems)
        end

    elseif event == "TRADE_REQUEST_CANCEL" then
        -- 交易被取消
        if #pendingTradeItems > 0 then
            DKP.Print("交易取消，" .. #pendingTradeItems .. " 件装备未标记")
        end
        wipe(pendingTradeItems)

    elseif event == "TRADE_CLOSED" then
        -- 兜底 cleanup：交易窗口关闭
        wipe(pendingTradeItems)
        tradeCompleted = false
    end
end)
