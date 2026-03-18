----------------------------------------------------------------------
-- YTHT DKP - Communication Layer
--
-- DKP 数据广播与同步
-- 管理员修改DKP后广播变动，团员本地同步更新
-- 支持全量同步（进团/reload时）
----------------------------------------------------------------------

local DKP = YTHT_DKP

local MSG_SEP = "\t"

-- 分包相关
local CHUNK_SIZE = 240  -- addon message 最大 255 byte，留余量
local pendingSync = {}  -- sender -> { chunks = {}, expected = N }

----------------------------------------------------------------------
-- 发送工具
----------------------------------------------------------------------
local function GetChannel()
    if IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return nil
end

function DKP.SendDKPMessage(msg)
    local channel = GetChannel()
    if channel then
        C_ChatInfo.SendAddonMessage(DKP.ADDON_PREFIX, msg, channel)
    end
end

----------------------------------------------------------------------
-- DKP 变动广播（管理员调用）
----------------------------------------------------------------------
function DKP.BroadcastDKPChange(playerName, newDKP, changeAmount, reason, timestamp, officer)
    if not DKP.IsOfficer() then return end
    local msg = table.concat({
        "DKP_CHANGE", playerName, tostring(newDKP), tostring(changeAmount),
        reason or "", tostring(timestamp or time()), officer or DKP.playerName
    }, MSG_SEP)
    DKP.SendDKPMessage(msg)
end

----------------------------------------------------------------------
-- 全量同步：序列化 players 数据
----------------------------------------------------------------------
local function SerializePlayers()
    if not DKP.db or not DKP.db.players then return "" end
    local parts = {}
    for name, data in pairs(DKP.db.players) do
        local charParts = {}
        for _, char in ipairs(data.characters or {}) do
            table.insert(charParts, char.name .. ":" .. (char.class or "WARRIOR"))
        end
        table.insert(parts, name .. "," .. tostring(data.dkp or 0) .. "," .. table.concat(charParts, ";"))
    end
    return table.concat(parts, "\n")
end

local function DeserializePlayers(text)
    local result = {}
    for line in text:gmatch("[^\n]+") do
        local parts = {}
        for part in line:gmatch("[^,]+") do
            table.insert(parts, part)
        end
        if #parts >= 2 then
            local name = parts[1]
            local dkp = tonumber(parts[2]) or 0
            local characters = {}
            if parts[3] and parts[3] ~= "" then
                for charEntry in parts[3]:gmatch("[^;]+") do
                    local charName, charClass = charEntry:match("^(.+):(.+)$")
                    if charName then
                        table.insert(characters, { name = charName, class = charClass })
                    end
                end
            end
            result[name] = { dkp = dkp, characters = characters }
        end
    end
    return result
end

----------------------------------------------------------------------
-- 分包发送
----------------------------------------------------------------------
local function SendChunked(prefix, msgType, data, channel, target)
    local totalLen = #data
    local numChunks = math.ceil(totalLen / CHUNK_SIZE)
    if numChunks == 0 then numChunks = 1 end

    for i = 1, numChunks do
        local startPos = (i - 1) * CHUNK_SIZE + 1
        local endPos = math.min(i * CHUNK_SIZE, totalLen)
        local chunk = data:sub(startPos, endPos)
        local msg = table.concat({ msgType, tostring(i), tostring(numChunks), chunk }, MSG_SEP)
        if target then
            C_ChatInfo.SendAddonMessage(prefix, msg, "WHISPER", target)
        else
            C_ChatInfo.SendAddonMessage(prefix, msg, channel or "RAID")
        end
    end
end

----------------------------------------------------------------------
-- 全量同步响应（管理员端）
----------------------------------------------------------------------
local function HandleSyncRequest(sender)
    if not DKP.IsOfficer() then return end
    local data = SerializePlayers()
    if data == "" then return end

    local channel = GetChannel()
    if channel then
        SendChunked(DKP.ADDON_PREFIX, "SYNC_FULL", data, nil, sender)
    end
end

----------------------------------------------------------------------
-- 全量同步接收（团员端）
----------------------------------------------------------------------
local function HandleSyncChunk(parts, sender)
    local chunkIndex = tonumber(parts[2])
    local totalChunks = tonumber(parts[3])
    local chunkData = parts[4] or ""

    if not chunkIndex or not totalChunks then return end

    if not pendingSync[sender] then
        pendingSync[sender] = { chunks = {}, expected = totalChunks }
    end

    local sync = pendingSync[sender]
    sync.chunks[chunkIndex] = chunkData

    -- 检查是否收齐
    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if received >= sync.expected then
        -- 重组数据
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingSync[sender] = nil

        -- 应用同步数据
        local playersData = DeserializePlayers(text)
        if next(playersData) then
            for name, data in pairs(playersData) do
                if not DKP.db.players[name] then
                    DKP.db.players[name] = {
                        dkp = data.dkp,
                        characters = data.characters,
                        note = "",
                        lastUpdated = time(),
                    }
                else
                    DKP.db.players[name].dkp = data.dkp
                    -- 合并角色列表
                    local existing = {}
                    for _, c in ipairs(DKP.db.players[name].characters or {}) do
                        existing[c.name] = true
                    end
                    for _, c in ipairs(data.characters) do
                        if not existing[c.name] then
                            table.insert(DKP.db.players[name].characters, c)
                        end
                    end
                    DKP.db.players[name].lastUpdated = time()
                end
            end
            DKP.Print("已从 " .. sender .. " 同步 DKP 数据")
            if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
        end
    end
end

----------------------------------------------------------------------
-- DKP 变动接收（团员端）
----------------------------------------------------------------------
local function HandleDKPChange(parts, sender)
    -- parts: { "DKP_CHANGE", playerName, newDKP, changeAmount, reason, timestamp, officer }
    local playerName = parts[2]
    local newDKP = tonumber(parts[3])
    local changeAmount = tonumber(parts[4])
    local reason = parts[5] or ""
    local timestamp = tonumber(parts[6]) or time()
    local officer = parts[7] or sender

    if not playerName or not newDKP then return end

    -- 更新本地数据
    if DKP.db.players[playerName] then
        DKP.db.players[playerName].dkp = newDKP
        DKP.db.players[playerName].lastUpdated = time()
    end

    -- 追加到本地日志
    if changeAmount then
        table.insert(DKP.db.log, {
            type = changeAmount >= 0 and "award" or "deduct",
            player = playerName,
            amount = changeAmount,
            reason = reason,
            timestamp = timestamp,
            officer = officer,
        })
    end

    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
end

----------------------------------------------------------------------
-- 管理员列表广播
----------------------------------------------------------------------
function DKP.BroadcastAdminSync()
    if not DKP.IsOfficer() then return end
    local admins = DKP.db.admins
    if not admins then return end
    local names = {}
    for name in pairs(admins) do
        table.insert(names, name)
    end
    local msg = table.concat({ "ADMIN_SYNC", table.concat(names, ";") }, MSG_SEP)
    DKP.SendDKPMessage(msg)
end

local function HandleAdminSync(parts, sender)
    local namesStr = parts[2] or ""
    if namesStr == "" then return end

    local newAdmins = {}
    for name in namesStr:gmatch("[^;]+") do
        newAdmins[name] = true
    end

    -- 检查发送者是否是管理员（或当前无管理员列表时接受）
    local senderShort = sender:match("^([^%-]+)") or sender
    local currentAdmins = DKP.db.admins or {}
    local hasAdmins = next(currentAdmins) ~= nil

    if hasAdmins then
        -- 只接受来自管理员的同步
        if not currentAdmins[senderShort] then return end
        -- 如果本地是管理员且列表不同，提示确认
        if DKP.IsOfficer() then
            -- 检查是否相同
            local same = true
            for name in pairs(newAdmins) do
                if not currentAdmins[name] then same = false; break end
            end
            if same then
                for name in pairs(currentAdmins) do
                    if not newAdmins[name] then same = false; break end
                end
            end
            if same then return end  -- 相同不处理
            -- 管理员间冲突：接受（最后写入者胜）
        end
    end

    DKP.db.admins = newAdmins
    DKP.Print("已同步管理员列表 (来自 " .. senderShort .. ")")
end

----------------------------------------------------------------------
-- 拍卖历史条目广播
----------------------------------------------------------------------
function DKP.BroadcastHistoryEntry(entry)
    if not DKP.IsOfficer() then return end
    if not entry then return end
    -- 序列化关键字段（精简版，不含完整bids）
    local bidsStr = ""
    if entry.bids and #entry.bids > 0 then
        local bidParts = {}
        for _, b in ipairs(entry.bids) do
            table.insert(bidParts,
                (b.bidder or "") .. ":" ..
                tostring(b.amount or 0) .. ":" ..
                (b.isAllIn and "1" or "0") .. ":" ..
                tostring(b.timestamp or 0))
        end
        bidsStr = table.concat(bidParts, ";")
    end

    local tiedStr = ""
    if entry.tiedBidders then
        local parts = {}
        for _, tb in ipairs(entry.tiedBidders) do
            table.insert(parts, (tb.name or "") .. ":" .. (tb.playerName or ""))
        end
        tiedStr = table.concat(parts, ";")
    end

    local msg = table.concat({
        "HISTORY_ENTRY",
        entry.id or "",
        entry.itemLink or "",
        entry.state or "ENDED",
        entry.winner or "",
        entry.winnerChar or "",
        entry.winnerClass or "",
        tostring(entry.finalBid or 0),
        tostring(entry.startBid or 0),
        tostring(entry.bidCount or 0),
        tostring(entry.timestamp or 0),
        entry.officer or "",
        entry.encounterName or "",
        entry.instanceName or "",
        bidsStr,
        tiedStr,
    }, MSG_SEP)

    DKP.SendDKPMessage(msg)
end

local function HandleHistoryEntry(parts, sender)
    local senderShort = sender:match("^([^%-]+)") or sender
    -- 只接受管理员广播的历史
    if DKP.db.admins and next(DKP.db.admins) and not DKP.db.admins[senderShort] then
        return
    end

    local entryId = parts[2] or ""
    local itemLink = parts[3] or ""
    local state = parts[4] or "ENDED"
    local winner = parts[5]
    local winnerChar = parts[6]
    local winnerClass = parts[7]
    local finalBid = tonumber(parts[8]) or 0
    local startBid = tonumber(parts[9]) or 0
    local bidCount = tonumber(parts[10]) or 0
    local timestamp = tonumber(parts[11]) or time()
    local officer = parts[12] or senderShort
    local encounterName = parts[13]
    local instanceName = parts[14]
    local bidsStr = parts[15] or ""
    local tiedStr = parts[16] or ""

    if winner == "" then winner = nil end
    if winnerChar == "" then winnerChar = nil end
    if winnerClass == "" then winnerClass = nil end
    if encounterName == "" then encounterName = nil end
    if instanceName == "" then instanceName = nil end

    -- 去重：检查是否已有相同 id 的记录
    for _, existing in ipairs(DKP.db.auctionHistory) do
        if existing.id and existing.id == entryId and entryId ~= "" then
            return  -- 已存在
        end
    end

    -- 解析 bids
    local bids = {}
    if bidsStr ~= "" then
        for bidEntry in bidsStr:gmatch("[^;]+") do
            local bidder, amount, isAllIn, ts = bidEntry:match("^(.+):(%d+):([01]):(%d+)$")
            if bidder then
                table.insert(bids, {
                    bidder = bidder,
                    bidderPlayer = DKP.GetPlayerByCharacter and DKP.GetPlayerByCharacter(bidder) or bidder,
                    amount = tonumber(amount) or 0,
                    isAllIn = isAllIn == "1",
                    timestamp = tonumber(ts) or 0,
                })
            end
        end
    end

    -- 解析 tiedBidders
    local tiedBidders = nil
    if tiedStr ~= "" then
        tiedBidders = {}
        for tbEntry in tiedStr:gmatch("[^;]+") do
            local name, playerName = tbEntry:match("^(.+):(.+)$")
            if name then
                table.insert(tiedBidders, { name = name, playerName = playerName })
            end
        end
    end

    local entry = {
        id = entryId,
        itemLink = itemLink,
        state = state,
        winner = winner,
        winnerChar = winnerChar,
        winnerClass = winnerClass,
        finalBid = finalBid,
        startBid = startBid,
        bidCount = bidCount,
        bids = bids,
        tiedBidders = tiedBidders,
        timestamp = timestamp,
        officer = officer,
        encounterName = encounterName,
        instanceName = instanceName,
    }
    table.insert(DKP.db.auctionHistory, entry)

    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
end

----------------------------------------------------------------------
-- 事件处理
----------------------------------------------------------------------
local commFrame = CreateFrame("Frame")
commFrame:RegisterEvent("CHAT_MSG_ADDON")
commFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

commFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= DKP.ADDON_PREFIX then return end

        -- 忽略自己发的消息（管理员端已处理）
        local myName = DKP.playerFullName or (DKP.playerName .. "-" .. GetRealmName())
        if sender == myName or sender == DKP.playerName then return end

        local parts = { strsplit(MSG_SEP, msg) }
        local msgType = parts[1]

        if msgType == "DKP_CHANGE" then
            HandleDKPChange(parts, sender)
        elseif msgType == "SYNC_REQUEST" then
            HandleSyncRequest(sender)
        elseif msgType == "SYNC_FULL" then
            HandleSyncChunk(parts, sender)
        elseif msgType == "ADMIN_SYNC" then
            HandleAdminSync(parts, sender)
        elseif msgType == "HISTORY_ENTRY" then
            HandleHistoryEntry(parts, sender)
        elseif msgType == "QUERY_DKP" then
            -- 由 WhisperQuery.lua 处理
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if IsInRaid() or IsInGroup() then
            if DKP.IsOfficer() then
                -- 管理员进团后广播 admin 列表
                C_Timer.After(3, function()
                    if DKP.IsOfficer() then
                        DKP.BroadcastAdminSync()
                    end
                end)
            else
                -- 团员进团后请求同步
                C_Timer.After(3, function()
                    if not DKP.IsOfficer() then
                        DKP.SendDKPMessage("SYNC_REQUEST")
                    end
                end)
            end
        end
    end
end)
