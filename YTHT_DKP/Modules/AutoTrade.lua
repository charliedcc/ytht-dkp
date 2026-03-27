----------------------------------------------------------------------
-- YTHT DKP - Auto Trade (自动交易)
--
-- 管理员（拾取者）与获得者交易时，自动将分配的装备放入交易窗口
-- 交易成功后标记物品已交易，避免重复
-- 使用完整 itemLink 匹配（区分同 ID 不同属性的装备）
----------------------------------------------------------------------

local DKP = YTHT_DKP

local pendingTradeItems = {}  -- 本次交易放入的 itemData 引用

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
f:RegisterEvent("TRADE_ACCEPT_UPDATE")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "TRADE_SHOW" then
        DKP.Print("[交易DEBUG] TRADE_SHOW 触发")

        -- 只有管理模式触发自动交易
        if not DKP.IsAdminMode or not DKP.IsAdminMode() then
            DKP.Print("[交易DEBUG] 非管理模式，跳过")
            return
        end
        if not DKP.db or not DKP.db.sheets then
            DKP.Print("[交易DEBUG] 无 sheets 数据，跳过")
            return
        end

        wipe(pendingTradeItems)

        local tradeName = GetTradePlayerName()
        if not tradeName then
            DKP.Print("[交易DEBUG] GetTradePlayerName 返回 nil")
            return
        end

        local tradeShort = tradeName
        local dashPos = tradeName:find("-", 1, true)
        if dashPos then tradeShort = tradeName:sub(1, dashPos - 1) end
        DKP.Print("[交易DEBUG] 交易对象: " .. tradeName .. " (短名: " .. tradeShort .. ")")

        -- 查找分配给该玩家且未交易的物品
        local itemsToTrade = {}
        local totalItems = 0
        for sheetName, sheet in pairs(DKP.db.sheets) do
            for _, boss in ipairs(sheet.bosses or {}) do
                for _, item in ipairs(boss.items or {}) do
                    if item.winner and item.winner ~= "" and item.link then
                        totalItems = totalItems + 1
                        if not item.traded then
                            local winnerShort = item.winner
                            local dp = item.winner:find("-", 1, true)
                            if dp then winnerShort = item.winner:sub(1, dp - 1) end

                            DKP.Print("[交易DEBUG] 检查: winner=" .. item.winner .. " vs trade=" .. tradeShort .. " traded=" .. tostring(item.traded))

                            if winnerShort == tradeShort or item.winner == tradeName then
                                table.insert(itemsToTrade, {
                                    itemData = item,
                                    link = item.link,
                                    matchKey = GetItemMatchKey(item.link),
                                })
                                DKP.Print("[交易DEBUG] 匹配! " .. (item.link:match("%[(.-)%]") or item.link))
                            end
                        end
                    end
                end
            end
        end
        DKP.Print("[交易DEBUG] 总已分配物品: " .. totalItems .. ", 匹配待交易: " .. #itemsToTrade)

        if #itemsToTrade == 0 then return end

        -- 在背包里查找并放入交易窗
        local placed = 0
        local usedSlots = {}  -- 防止同一格子被匹配两次

        for idx, entry in ipairs(itemsToTrade) do
            DKP.Print("[交易DEBUG] 搜索背包: " .. (entry.link:match("%[(.-)%]") or "?") .. " matchKey=" .. tostring(entry.matchKey))
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
                                C_Container.PickupContainerItem(bag, slot)
                                ClickTradeButton(placed + 1)
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

    elseif event == "TRADE_ACCEPT_UPDATE" then
        local playerAccepted, targetAccepted = ...
        if playerAccepted == 1 and targetAccepted == 1 then
            for _, itemData in ipairs(pendingTradeItems) do
                itemData.traded = true
            end
            if #pendingTradeItems > 0 then
                DKP.Print("交易完成，" .. #pendingTradeItems .. " 件装备已标记为已交易")
                DKP.hasUnsavedChanges = true
            end
            wipe(pendingTradeItems)
        end
    end
end)
