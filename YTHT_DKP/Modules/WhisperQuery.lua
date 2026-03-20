----------------------------------------------------------------------
-- YTHT DKP - Whisper Query
--
-- 密语查分：玩家密语 "dkp"/"查分" 自动回复DKP余额
-- 同时支持 addon message 方式查询
----------------------------------------------------------------------

local DKP = YTHT_DKP

local QUERY_PATTERNS = { "dkp", "DKP", "查分", "查dkp", "dkp查询" }
local QUERY_COOLDOWN = 5
local lastQueryTime = {}

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("CHAT_MSG_ADDON")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_WHISPER" then
        local msg, sender = ...

        -- 只在有DKP数据时回复
        if not DKP.db or not DKP.db.players or not next(DKP.db.players) then return end

        -- 忽略自己发出的回复（含 [YTHT-DKP] 前缀）
        if msg:find("%[YTHT%-DKP%]") then return end

        local isQuery = false
        local trimmed = (msg or ""):match("^%s*(.-)%s*$"):lower()
        for _, pattern in ipairs(QUERY_PATTERNS) do
            -- 只匹配简短查询（整条消息就是查询词，或非常短的消息包含查询词）
            if trimmed == pattern:lower() or (#trimmed <= 10 and trimmed:find(pattern:lower(), 1, true)) then
                isQuery = true
                break
            end
        end
        if not isQuery then return end

        -- 冷却
        local now = GetTime()
        if lastQueryTime[sender] and (now - lastQueryTime[sender]) < QUERY_COOLDOWN then
            return
        end
        lastQueryTime[sender] = now

        -- 查找DKP
        local shortName = sender:match("^([^%-]+)")
        local playerName = DKP.GetPlayerByCharacter(sender) or DKP.GetPlayerByCharacter(shortName)

        if playerName then
            local player = DKP.db.players[playerName]
            if player then
                SendChatMessage(
                    "[YTHT-DKP] " .. playerName .. " 当前DKP: " .. (player.dkp or 0),
                    "WHISPER", nil, sender
                )
            end
        else
            SendChatMessage(
                "[YTHT-DKP] 未找到你的DKP记录。请联系团长添加。",
                "WHISPER", nil, sender
            )
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= DKP.ADDON_PREFIX then return end

        -- 只在有DKP数据时回复
        if not DKP.db or not DKP.db.players or not next(DKP.db.players) then return end

        if msg == "QUERY_DKP" then
            local shortName = sender:match("^([^%-]+)")
            local playerName = DKP.GetPlayerByCharacter(sender) or DKP.GetPlayerByCharacter(shortName)
            if playerName then
                local player = DKP.db.players[playerName]
                if player then
                    C_ChatInfo.SendAddonMessage(DKP.ADDON_PREFIX,
                        "DKP_REPLY\t" .. playerName .. "\t" .. (player.dkp or 0),
                        "WHISPER", sender)
                end
            end
        end
    end
end)
