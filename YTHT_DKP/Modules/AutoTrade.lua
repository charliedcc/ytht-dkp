----------------------------------------------------------------------
-- YTHT DKP - Auto Trade (自动交易)
--
-- 当交易窗口打开时，自动将分配给交易对象的装备放入交易窗口
----------------------------------------------------------------------

local DKP = YTHT_DKP

local f = CreateFrame("Frame")
f:RegisterEvent("TRADE_SHOW")

f:SetScript("OnEvent", function(self, event)
    if event ~= "TRADE_SHOW" then return end
    if not DKP.db or not DKP.db.sheets then return end

    -- 获取交易对象名字
    local tradeName = GetTradePlayerName()
    if not tradeName then return end

    -- 提取短名（去掉服务器后缀）
    local tradeShort = tradeName
    local dashPos = tradeName:find("-", 1, true)
    if dashPos then tradeShort = tradeName:sub(1, dashPos - 1) end

    -- 查找分配给该玩家的物品
    local itemsToTrade = {}
    for _, sheet in pairs(DKP.db.sheets) do
        for _, boss in ipairs(sheet.bosses or {}) do
            for _, item in ipairs(boss.items or {}) do
                if item.winner and item.winner ~= "" and item.link then
                    -- 匹配 winner（可能是角色名或玩家名）
                    local winnerShort = item.winner
                    local dp = item.winner:find("-", 1, true)
                    if dp then winnerShort = item.winner:sub(1, dp - 1) end

                    if winnerShort == tradeShort or item.winner == tradeName then
                        table.insert(itemsToTrade, item.link)
                    end
                end
            end
        end
    end

    if #itemsToTrade == 0 then return end

    -- 在背包里查找并放入交易窗
    local placed = 0
    for _, itemLink in ipairs(itemsToTrade) do
        -- 提取 itemID 用于匹配
        local targetID = C_Item.GetItemInfoInstant(itemLink)
        if targetID then
            local found = false
            for bag = 0, 4 do
                local numSlots = C_Container.GetContainerNumSlots(bag)
                for slot = 1, numSlots do
                    local bagLink = C_Container.GetContainerItemLink(bag, slot)
                    if bagLink then
                        local bagID = C_Item.GetItemInfoInstant(bagLink)
                        if bagID == targetID then
                            -- 放入交易窗
                            C_Container.PickupContainerItem(bag, slot)
                            ClickTradeButton(placed + 1)
                            placed = placed + 1
                            found = true

                            local itemName = bagLink:match("%[(.-)%]") or bagLink
                            DKP.Print("自动交易: " .. itemName .. " → " .. tradeShort)
                            break
                        end
                    end
                end
                if found then break end
            end
        end

        -- 交易窗最多放 6 个物品
        if placed >= 6 then break end
    end

    if placed > 0 then
        DKP.Print("已自动放入 " .. placed .. " 件装备到交易窗口 (请手动确认交易)")
    end
end)
