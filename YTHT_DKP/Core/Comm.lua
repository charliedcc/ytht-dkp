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
-- 全量同步：序列化 options 数据
----------------------------------------------------------------------
local function SerializeOptions()
    local opts = DKP.db.options
    if not opts then return "" end
    local parts = {}
    local keys = { "gatherPoints", "dismissPoints", "bossKillPoints", "auctionDuration",
        "minBidIncrement", "auctionExtendTime", "defaultStartingBid", "enableBossKillBonus",
        "progressionBonusPoints", "wipeBonus", "wipeBonusMax", "minItemQuality" }
    for _, k in ipairs(keys) do
        local v = opts[k]
        if v ~= nil then
            table.insert(parts, k .. "=" .. tostring(v))
        end
    end
    if opts.defaultBidByDifficulty then
        local diffParts = {}
        for did, dpts in pairs(opts.defaultBidByDifficulty) do
            table.insert(diffParts, tostring(did) .. ":" .. tostring(dpts))
        end
        table.insert(parts, "defaultBidByDifficulty=" .. table.concat(diffParts, ";"))
    end
    return table.concat(parts, "\n")
end

local function DeserializeOptions(text)
    local result = {}
    for line in text:gmatch("[^\n]+") do
        local key, val = line:match("^(.-)=(.+)$")
        if key and val then
            if key == "defaultBidByDifficulty" then
                result[key] = {}
                for entry in val:gmatch("[^;]+") do
                    local did, dpts = entry:match("^(%d+):(%d+)$")
                    if did then result[key][tonumber(did)] = tonumber(dpts) end
                end
            elseif val == "true" then
                result[key] = true
            elseif val == "false" then
                result[key] = false
            else
                result[key] = tonumber(val) or val
            end
        end
    end
    return result
end

----------------------------------------------------------------------
-- 分包发送
----------------------------------------------------------------------
local function SendChunked(prefix, msgType, data, channel, target)
    -- 动态计算 chunk 大小，确保总消息 <= 255 字节
    -- 头部格式: msgType\tchunkIndex\ttotalChunks\t
    -- 预估最大头部: msgType(15) + \t + chunkIndex(4) + \t + totalChunks(4) + \t = ~25
    local headerReserve = #msgType + 12  -- msgType长度 + 数字和分隔符
    local chunkSize = 255 - headerReserve
    if chunkSize < 50 then chunkSize = 50 end

    local totalLen = #data
    local numChunks = math.ceil(totalLen / chunkSize)
    if numChunks == 0 then numChunks = 1 end

    for i = 1, numChunks do
        local startPos = (i - 1) * chunkSize + 1
        local endPos = math.min(i * chunkSize, totalLen)
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
    if data ~= "" then
        SendChunked(DKP.ADDON_PREFIX, "SYNC_FULL", data, nil, sender)
    end
    -- 同时发送 options 和 admin 列表
    local optsData = SerializeOptions()
    if optsData ~= "" then
        SendChunked(DKP.ADDON_PREFIX, "SYNC_OPTIONS", optsData, nil, sender)
    end
    -- 发送 sheets
    if DKP.SerializeSheets then
        local sheetsData = DKP.SerializeSheets()
        if sheetsData ~= "" then
            SendChunked(DKP.ADDON_PREFIX, "SYNC_SHEETS", sheetsData, nil, sender)
        end
    end
    DKP.BroadcastAdminSync()
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
    -- 只接受管理员广播的DKP变动
    local senderShort = sender:match("^([^%-]+)") or sender
    if DKP.db.admins and next(DKP.db.admins) and not DKP.db.admins[senderShort] then
        return
    end
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
    local master = DKP.db.masterAdmin or ""
    local msg = table.concat({ "ADMIN_SYNC", table.concat(names, ";"), master }, MSG_SEP)
    DKP.SendDKPMessage(msg)
end

local function HandleAdminSync(parts, sender)
    local namesStr = parts[2] or ""
    if namesStr == "" then return end

    local newAdmins = {}
    for name in namesStr:gmatch("[^;]+") do
        newAdmins[name] = true
    end
    local newMaster = parts[3] or ""
    if newMaster == "" then newMaster = nil end

    local senderShort = sender:match("^([^%-]+)") or sender

    -- 发送者必须在新列表中（说明是合法管理员发出的）
    if not newAdmins[senderShort] then return end

    -- 接受管理员列表和主管理员
    DKP.db.admins = newAdmins
    if newMaster then
        DKP.db.masterAdmin = newMaster
    end
    DKP.Print("已同步管理员列表 (来自 " .. senderShort .. ")")
end

----------------------------------------------------------------------
-- 拍卖历史条目广播
----------------------------------------------------------------------
function DKP.BroadcastHistoryEntry(entry)
    if not DKP.IsOfficer() then return end
    if not entry then return end
    -- 序列化关键字段
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

    -- 用 \031 (unit separator) 分隔字段（不用 \t 或 | 因为 itemLink 含 |）
    local data = table.concat({
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
    }, "\031")

    -- 用 chunked 发送（itemLink 可能很长，单条消息超 255 字节）
    local channel = GetChannel()
    if channel then
        SendChunked(DKP.ADDON_PREFIX, "HISTORY_ENTRY", data, channel)
    end
end

local pendingHistorySync = {}

local function HandleHistoryChunk(parts, sender)
    local chunkIndex = tonumber(parts[2])
    local totalChunks = tonumber(parts[3])
    local chunkData = parts[4] or ""
    if not chunkIndex or not totalChunks then return end

    local sKey = sender .. "_hist"
    if not pendingHistorySync[sKey] then
        pendingHistorySync[sKey] = { chunks = {}, expected = totalChunks }
    end
    local sync = pendingHistorySync[sKey]
    sync.chunks[chunkIndex] = chunkData

    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if received >= sync.expected then
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local data = table.concat(fullData)
        pendingHistorySync[sKey] = nil

        local senderShort = sender:match("^([^%-]+)") or sender
        -- 只接受管理员广播的历史
        if DKP.db.admins and next(DKP.db.admins) and not DKP.db.admins[senderShort] then
            return
        end

        -- 解析 \031 分隔的字段
        local f = { strsplit("\031", data) }
        local entryId = f[1] or ""
        local itemLink = f[2] or ""
        local state = f[3] or "ENDED"
        local winner = f[4]
        local winnerChar = f[5]
        local winnerClass = f[6]
        local finalBid = tonumber(f[7]) or 0
        local startBid = tonumber(f[8]) or 0
        local bidCount = tonumber(f[9]) or 0
        local timestamp = tonumber(f[10]) or time()
        local officer = f[11] or senderShort
        local encounterName = f[12]
        local instanceName = f[13]
        local bidsStr = f[14] or ""
        local tiedStr = f[15] or ""

        if winner == "" then winner = nil end
        if winnerChar == "" then winnerChar = nil end
        if winnerClass == "" then winnerClass = nil end
        if encounterName == "" then encounterName = nil end
        if instanceName == "" then instanceName = nil end

        -- 去重
        for _, existing in ipairs(DKP.db.auctionHistory) do
            if existing.id and existing.id == entryId and entryId ~= "" then
                return
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
end

----------------------------------------------------------------------
-- 拍卖表变化广播（关键操作时调用）
----------------------------------------------------------------------
local sheetsBroadcastPending = false

function DKP.BroadcastSheets()
    if not DKP.IsOfficer() then return end
    -- 防抖：0.5秒内多次调用只发一次
    if sheetsBroadcastPending then return end
    sheetsBroadcastPending = true
    C_Timer.After(0.5, function()
        sheetsBroadcastPending = false
        local channel = GetChannel()
        if not channel then return end
        if DKP.SerializeSheets then
            local data = DKP.SerializeSheets()
            if data ~= "" then
                SendChunked(DKP.ADDON_PREFIX, "SYNC_SHEETS", data, channel)
            end
        end
    end)
end

----------------------------------------------------------------------
-- 全量广播（含 players + options + admins）
----------------------------------------------------------------------
function DKP.BroadcastFullSync()
    if not DKP.IsOfficer() then return end

    local channel = GetChannel()
    if not channel then
        DKP.Print("不在队伍中，无法广播")
        return
    end

    -- 分批发送，用延迟避免 WoW 消息节流
    -- 第1批: admin 列表 + players
    DKP.BroadcastAdminSync()
    local playersData = SerializePlayers()
    if playersData ~= "" then
        SendChunked(DKP.ADDON_PREFIX, "SYNC_FULL", playersData, channel)
    end

    -- 第2批: options（延迟1秒）
    C_Timer.After(1, function()
        local ch = GetChannel()
        if not ch then return end
        local optsData = SerializeOptions()
        if optsData ~= "" then
            SendChunked(DKP.ADDON_PREFIX, "SYNC_OPTIONS", optsData, ch)
        end
        DKP.Print("已广播: 配置")
    end)

    -- 第3批: sheets（延迟2秒）
    C_Timer.After(2, function()
        local ch = GetChannel()
        if not ch then return end
        if DKP.SerializeSheets then
            local sheetsData = DKP.SerializeSheets()
            if sheetsData ~= "" then
                SendChunked(DKP.ADDON_PREFIX, "SYNC_SHEETS", sheetsData, ch)
                DKP.Print("已广播: 掉落列表")
            end
        end
    end)

    -- 第4批: log + auctionHistory（延迟3秒，不含 players 避免冗余）
    C_Timer.After(3, function()
        local ch = GetChannel()
        if not ch then return end
        if DKP.SerializeActivity then
            local act = {
                name = "sync",
                startTime = DKP.db.session and DKP.db.session.startTime or 0,
                endTime = time(),
                log = DKP.db.log or {},
                auctionHistory = DKP.db.auctionHistory or {},
                sheets = {},
                players = {},  -- 不重复发 players
            }
            local actData = DKP.SerializeActivity(act)
            if actData ~= "" then
                SendChunked(DKP.ADDON_PREFIX, "SYNC_ACTIVITY", actData, ch)
                DKP.Print("已广播: 操作记录和拍卖记录")
            end
        end
    end)

    DKP.Print("开始广播数据到团队 (分4批发送)...")
end

----------------------------------------------------------------------
-- 拍卖表序列化/反序列化
----------------------------------------------------------------------
local FIELD_SEP = "\031"  -- unit separator, 用于 item 字段分隔（避免和 itemLink 的 | 冲突）

function DKP.SerializeSheets()
    if not DKP.db or not DKP.db.sheets then return "" end
    local parts = {}
    for sheetName, sheet in pairs(DKP.db.sheets) do
        local bossParts = {}
        for _, boss in ipairs(sheet.bosses or {}) do
            local itemParts = {}
            for _, item in ipairs(boss.items or {}) do
                -- 用 \031 分隔 item 字段（itemLink 含 | 不能用 |）
                table.insert(itemParts, table.concat({
                    item.link or "",
                    item.winner or "",
                    item.winnerClass or "",
                    tostring(item.dkp or 0),
                    tostring(item.rollID or 0),
                }, FIELD_SEP))
            end
            -- bossName~encounterID~killed~item1^item2^item3
            table.insert(bossParts, table.concat({
                boss.name or "",
                tostring(boss.encounterID or 0),
                boss.killed and "1" or "0",
                table.concat(itemParts, "^"),
            }, "~"))
        end
        -- sheetName=boss1@@boss2@@boss3
        table.insert(parts, sheetName .. "=" .. table.concat(bossParts, "@@"))
    end
    return table.concat(parts, "\n")
end

function DKP.DeserializeSheets(text)
    local result = {}
    for line in text:gmatch("[^\n]+") do
        local sheetName, bossesStr = line:match("^(.-)=(.*)$")
        if sheetName then
            local sheet = { bosses = {} }
            if bossesStr ~= "" then
                -- 用 @@ 作为分隔符拆分 boss（gsub+gmatch 绕开 Lua 模式限制）
                for bossStr in (bossesStr .. "@@"):gmatch("(.-)@@") do
                    if bossStr ~= "" then
                        local bParts = { strsplit("~", bossStr) }
                        local boss = {
                            name = bParts[1] or "",
                            encounterID = tonumber(bParts[2]) or 0,
                            killed = bParts[3] == "1",
                            items = {},
                        }
                        local itemsStr = bParts[4] or ""
                        if itemsStr ~= "" then
                            for itemStr in itemsStr:gmatch("[^%^]+") do
                                local iParts = { strsplit(FIELD_SEP, itemStr) }
                                table.insert(boss.items, {
                                    link = iParts[1] or "",
                                    winner = iParts[2] or "",
                                    winnerClass = iParts[3] or "",
                                    dkp = tonumber(iParts[4]) or 0,
                                    rollID = tonumber(iParts[5]) or 0,
                                })
                            end
                        end
                        table.insert(sheet.bosses, boss)
                    end
                end
            end
            result[sheetName] = sheet
        end
    end
    return result
end

local pendingOptSync = {}
local pendingActivitySync = {}

----------------------------------------------------------------------
-- Activity 同步接收（log + auctionHistory）
----------------------------------------------------------------------
local function HandleActivityChunk(parts, sender)
    local chunkIndex = tonumber(parts[2])
    local totalChunks = tonumber(parts[3])
    local chunkData = parts[4] or ""
    if not chunkIndex or not totalChunks then return end

    local sKey = sender .. "_activity"
    if not pendingActivitySync[sKey] then
        pendingActivitySync[sKey] = { chunks = {}, expected = totalChunks }
    end
    local sync = pendingActivitySync[sKey]
    sync.chunks[chunkIndex] = chunkData

    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if received >= sync.expected then
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingActivitySync[sKey] = nil

        if DKP.DeserializeActivity then
            local act = DKP.DeserializeActivity(text)
            if act then
                local senderShort = sender:match("^([^%-]+)") or sender
                -- 同步 log（替换）
                if act.log and #act.log > 0 then
                    DKP.db.log = act.log
                end
                -- 同步 auctionHistory（替换）
                if act.auctionHistory and #act.auctionHistory > 0 then
                    DKP.db.auctionHistory = act.auctionHistory
                end
                DKP.Print("已同步活动数据 (来自 " .. senderShort .. "): " ..
                    #(act.log or {}) .. " 条日志, " .. #(act.auctionHistory or {}) .. " 条拍卖")
                if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
                if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
            end
        end
    end
end
local pendingSheetsSync = {}

----------------------------------------------------------------------
-- Sheets 同步接收（管理员需确认）
----------------------------------------------------------------------
local function HandleSheetsChunk(parts, sender)
    local chunkIndex = tonumber(parts[2])
    local totalChunks = tonumber(parts[3])
    local chunkData = parts[4] or ""
    if not chunkIndex or not totalChunks then return end

    local sKey = sender .. "_sheets"
    if not pendingSheetsSync[sKey] then
        pendingSheetsSync[sKey] = { chunks = {}, expected = totalChunks }
    end
    local sync = pendingSheetsSync[sKey]
    sync.chunks[chunkIndex] = chunkData

    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if received >= sync.expected then
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingSheetsSync[sKey] = nil

        local newSheets = DKP.DeserializeSheets(text)
        if not next(newSheets) then return end

        local senderShort = sender:match("^([^%-]+)") or sender

        -- 直接接受掉落列表同步（来自管理员的数据默认信任）
        DKP.db.sheets = newSheets
        DKP.Print("已同步掉落列表 (来自 " .. senderShort .. ")")
        if DKP.RefreshTableUI then DKP.RefreshTableUI() end
    end
end

local function HandleOptionsChunk(parts, sender)
    local chunkIndex = tonumber(parts[2])
    local totalChunks = tonumber(parts[3])
    local chunkData = parts[4] or ""
    if not chunkIndex or not totalChunks then return end

    local sKey = sender .. "_opts"
    if not pendingOptSync[sKey] then
        pendingOptSync[sKey] = { chunks = {}, expected = totalChunks }
    end
    local sync = pendingOptSync[sKey]
    sync.chunks[chunkIndex] = chunkData

    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if received >= sync.expected then
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingOptSync[sKey] = nil

        local newOpts = DeserializeOptions(text)
        if next(newOpts) then
            for k, v in pairs(newOpts) do
                DKP.db.options[k] = v
            end
            local senderShort = sender:match("^([^%-]+)") or sender
            DKP.Print("已同步配置 (来自 " .. senderShort .. ")")
        end
    end
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
        elseif msgType == "SYNC_OPTIONS" then
            HandleOptionsChunk(parts, sender)
        elseif msgType == "SYNC_SHEETS" then
            HandleSheetsChunk(parts, sender)
        elseif msgType == "SYNC_ACTIVITY" then
            HandleActivityChunk(parts, sender)
        elseif msgType == "ADMIN_SYNC" then
            HandleAdminSync(parts, sender)
        elseif msgType == "HISTORY_ENTRY" then
            HandleHistoryChunk(parts, sender)
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
