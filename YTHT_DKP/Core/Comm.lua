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
-- 名字工具 + 信任检查（必须在所有 handler 之前定义）
----------------------------------------------------------------------
local function GetShortName(fullName)
    if not fullName then return "" end
    local dashPos = fullName:find("-", 1, true)
    if dashPos then
        return fullName:sub(1, dashPos - 1)
    end
    return fullName
end

local function IsTrustedSender(sender)
    local senderShort = sender
    local dashPos = sender:find("-", 1, true)
    if dashPos then senderShort = sender:sub(1, dashPos - 1) end
    if DKP.db.admins and next(DKP.db.admins) then
        local trusted = DKP.db.admins[senderShort] == true or DKP.db.admins[sender] == true
        if not trusted then
            DKP.Print("|cffFF8800[调试] 不信任: " .. senderShort .. "|r")
        end
        return trusted
    end
    return true
end

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
-- WoW addon message 限制: 每前缀突发10条，之后每秒恢复1条
-- 前10条用 0.1s 间隔快速发，之后每条间隔 1.1s
local CHUNK_BURST_LIMIT = 8      -- 保守用8（留2条余量给其他消息）
local CHUNK_BURST_INTERVAL = 0.1  -- 突发期间隔
local CHUNK_SLOW_INTERVAL = 1.1   -- 突发后间隔（等恢复）

local function SendChunked(prefix, msgType, data, channel, target)
    -- 动态计算 chunk 大小，确保总消息 <= 255 字节
    local headerReserve = #msgType + 12
    local chunkSize = 255 - headerReserve
    if chunkSize < 50 then chunkSize = 50 end

    local totalLen = #data
    local numChunks = math.ceil(totalLen / chunkSize)
    if numChunks == 0 then numChunks = 1 end

    -- 超过5个chunk时显示发送进度
    local showProgress = numChunks > 5

    for i = 1, numChunks do
        -- 计算延迟: 前 BURST_LIMIT 条快速发，之后慢速
        local delay
        if i <= CHUNK_BURST_LIMIT then
            delay = (i - 1) * CHUNK_BURST_INTERVAL
        else
            delay = (CHUNK_BURST_LIMIT - 1) * CHUNK_BURST_INTERVAL
                  + (i - CHUNK_BURST_LIMIT) * CHUNK_SLOW_INTERVAL
        end

        C_Timer.After(delay, function()
            local startPos = (i - 1) * chunkSize + 1
            local endPos = math.min(i * chunkSize, totalLen)
            local chunk = data:sub(startPos, endPos)
            local msg = table.concat({ msgType, tostring(i), tostring(numChunks), chunk }, MSG_SEP)
            if target then
                C_ChatInfo.SendAddonMessage(prefix, msg, "WHISPER", target)
            else
                C_ChatInfo.SendAddonMessage(prefix, msg, channel or "RAID")
            end
            if showProgress and (i % 5 == 0 or i == numChunks) then
                DKP.Print("|cff888888[同步] " .. msgType .. " " .. i .. "/" .. numChunks .. "|r")
            end
        end)
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

        -- 信任检查
        DKP.Print("|cff888888[调试] SYNC_FULL 收到 " .. #text .. " 字节, 来自 " .. sender .. "|r")
        DKP.Print("|cff888888[调试] 当前团队: " .. tostring(DKP.db.currentTeam) .. " admins类型: " .. type(DKP.db.admins) .. "|r")
        if DKP.db.admins then
            local aList = {}
            for n in pairs(DKP.db.admins) do table.insert(aList, n) end
            DKP.Print("|cff888888[调试] admins: " .. table.concat(aList, ",") .. "|r")
        end

        local trusted = IsTrustedSender(sender)
        DKP.Print("|cff888888[调试] IsTrustedSender结果: " .. tostring(trusted) .. "|r")
        if not trusted then
            DKP.Print("|cffFF8800[调试] SYNC_FULL 被拒绝|r")
            return
        end

        -- 应用同步数据
        DKP.Print("|cff888888[调试] 开始解析 players...|r")
        local playersData = DeserializePlayers(text)
        local pCount = 0
        for _ in pairs(playersData) do pCount = pCount + 1 end
        DKP.Print("|cff888888[调试] 解析出 " .. pCount .. " 个玩家|r")
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
-- (GetShortName 和 IsTrustedSender 已移至文件顶部)
----------------------------------------------------------------------

----------------------------------------------------------------------
-- DKP 变动接收（团员端）
----------------------------------------------------------------------
local function HandleDKPChange(parts, sender)
    if not IsTrustedSender(sender) then return end
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
-- 团队权限广播（替代旧 ADMIN_SYNC）
----------------------------------------------------------------------
function DKP.BroadcastAdminSync()
    if not DKP.IsOfficer() then return end
    local team = DKP.GetCurrentTeam()
    if not team then return end

    local admins = team.admins or {}
    local adminNames = {}
    for name in pairs(admins) do table.insert(adminNames, name) end

    -- 收集 players 里所有角色名作为成员列表
    local charNames = {}
    for _, data in pairs(team.players or {}) do
        for _, char in ipairs(data.characters or {}) do
            table.insert(charNames, char.name)
        end
    end

    local teamID = DKP.GetCurrentTeamID()
    local teamName = team.name or "未命名"
    local master = team.masterAdmin or ""

    -- TEAM_SYNC: 可能超 255 字节（角色名多时），用 chunked 发送
    -- 数据用 \031 分隔（不用 \t 因为那是 chunk header 分隔符）
    local data = table.concat({
        teamID,
        teamName,
        master,
        table.concat(adminNames, ";"),
        table.concat(charNames, ";"),
    }, "\031")

    local channel = GetChannel()
    if channel then
        DKP.Print("|cff888888[调试] 发送TEAM_SYNC: " .. #data .. " 字节, " .. #charNames .. " 个角色|r")
        SendChunked(DKP.ADDON_PREFIX, "TEAM_SYNC", data, channel)
    end
end

local pendingTeamSync = {}

local function HandleTeamSync(parts, sender)
    -- chunked 接收
    local chunkIndex = tonumber(parts[2])
    local totalChunks = tonumber(parts[3])
    local chunkData = parts[4] or ""
    if not chunkIndex or not totalChunks then return end

    local sKey = sender .. "_team"
    if not pendingTeamSync[sKey] then
        pendingTeamSync[sKey] = { chunks = {}, expected = totalChunks }
    end
    local sync = pendingTeamSync[sKey]
    sync.chunks[chunkIndex] = chunkData

    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if received < sync.expected then return end

    local fullData = {}
    for i = 1, sync.expected do
        table.insert(fullData, sync.chunks[i] or "")
    end
    local data = table.concat(fullData)
    pendingTeamSync[sKey] = nil

    -- 解析 \031 分隔的字段
    local f = { strsplit("\031", data) }
    local teamID = f[1] or ""
    local teamName = f[2] or ""
    local masterAdmin = f[3] or ""
    local adminsStr = f[4] or ""
    local charsStr = f[5] or ""

    if teamID == "" or teamName == "" then
        DKP.Print("|cffFF8800[调试] TEAM_SYNC 数据不完整|r")
        return
    end
    if masterAdmin == "" then masterAdmin = nil end

    local senderShort = GetShortName(sender)

    local newAdmins = {}
    for name in adminsStr:gmatch("[^;]+") do newAdmins[name] = true end

    -- 发送者必须在 admins 列表中
    if not newAdmins[senderShort] then
        DKP.Print("|cffFF8800[调试] TEAM_SYNC 发送者 " .. senderShort .. " 不在admins中|r")
        return
    end

    -- 检查我的角色名是否在成员列表中（短名和全称都匹配）
    local myName = DKP.playerName
    local myFullName = DKP.playerFullName
    local isMember = false
    for name in charsStr:gmatch("[^;]+") do
        local nameShort = GetShortName(name)
        if name == myName or nameShort == myName or name == myFullName then
            isMember = true; break
        end
    end

    if not isMember then
        DKP.Print("|cff888888[调试] TEAM_SYNC: 我(" .. myName .. ")不在成员列表中|r")
        return
    end

    DKP.Print("|cff888888[调试] TEAM_SYNC 收到: 团队=" .. teamName .. " 发送者=" .. senderShort .. "|r")

    -- 检查本地是否已有这个团队
    if DKP.db.teams[teamID] then
        -- 已有：更新权限
        local team = DKP.db.teams[teamID]
        team.admins = newAdmins
        if masterAdmin then team.masterAdmin = masterAdmin end
        team.name = teamName
        -- 如果当前在这个团队，刷新快捷引用和UI
        if DKP.db.currentTeam == teamID then
            DKP.db.admins = team.admins
            DKP.db.masterAdmin = team.masterAdmin
            -- 刷新标题栏团队名
            if DKP.MainFrame and DKP.MainFrame.teamBtn and DKP.MainFrame.teamBtn.text then
                DKP.MainFrame.teamBtn.text:SetText(teamName)
            end
        end
        DKP.Print("已更新团队权限: " .. teamName .. " (来自 " .. senderShort .. ")")
        if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    else
        -- 新团队：弹确认加入对话框
        if not DKP._teamJoinDialog then
            local d = CreateFrame("Frame", "YTHTDKPTeamJoinDialog", UIParent, "BackdropTemplate")
            d:SetSize(340, 130)
            d:SetPoint("CENTER", 0, 100)
            d:SetFrameStrata("FULLSCREEN_DIALOG")
            d:SetFrameLevel(260)
            d:EnableMouse(true)
            d:SetBackdrop({
                bgFile = "Interface/Tooltips/UI-Tooltip-Background",
                edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
                edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            d:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
            d:Hide()
            local text = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            text:SetPoint("TOP", 0, -16)
            text:SetWidth(300)
            d.text = text
            local yesBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
            yesBtn:SetSize(80, 24)
            yesBtn:SetPoint("BOTTOMLEFT", 30, 12)
            yesBtn:SetText("加入")
            d.yesBtn = yesBtn
            local noBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
            noBtn:SetSize(80, 24)
            noBtn:SetPoint("BOTTOMRIGHT", -30, 12)
            noBtn:SetText("忽略")
            noBtn:SetScript("OnClick", function() d:Hide() end)
            DKP._teamJoinDialog = d
        end
        local d = DKP._teamJoinDialog
        d.text:SetText("收到团队邀请\n|cff00FF00" .. teamName .. "|r\n来自 " .. senderShort .. "\n是否加入？")
        d.yesBtn:SetScript("OnClick", function()
            d:Hide()
            -- 创建新团队
            local newTeam = CopyTable(DKP.db.teams["local"])  -- 基于 local 模板
            -- 清空数据（等待同步）
            newTeam.players = {}
            newTeam.log = {}
            newTeam.auctionHistory = {}
            newTeam.sheets = {}
            newTeam.activities = {}
            newTeam.currentSheet = nil
            newTeam.name = teamName
            newTeam.masterAdmin = masterAdmin
            newTeam.admins = newAdmins
            DKP.db.teams[teamID] = newTeam
            -- 切换到新团队
            DKP.SwitchTeam(teamID)
            DKP.Print("已加入团队: " .. teamName)
            DKP.Print("等待管理员同步数据...")
        end)
        d:Show()
    end
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

    if totalChunks > 3 and (received % 3 == 0 or received == totalChunks) then
        DKP.Print("|cff888888[接收] 拍卖记录 " .. received .. "/" .. totalChunks .. "|r")
    end

    if received >= sync.expected then
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local data = table.concat(fullData)
        pendingHistorySync[sKey] = nil

        if not IsTrustedSender(sender) then return end
        local senderShort = GetShortName(sender)

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
-- 单项广播函数
----------------------------------------------------------------------
function DKP.BroadcastDKPData()
    if not DKP.IsOfficer() then return end
    local channel = GetChannel()
    if not channel then DKP.Print("不在队伍中"); return end
    local data = SerializePlayers()
    if data ~= "" then
        SendChunked(DKP.ADDON_PREFIX, "SYNC_FULL", data, channel)
        DKP.Print("已广播: DKP数据")
    end
end

function DKP.BroadcastOptions()
    if not DKP.IsOfficer() then return end
    local channel = GetChannel()
    if not channel then DKP.Print("不在队伍中"); return end
    local data = SerializeOptions()
    if data ~= "" then
        SendChunked(DKP.ADDON_PREFIX, "SYNC_OPTIONS", data, channel)
        DKP.Print("已广播: 配置")
    end
end

function DKP.BroadcastSheetsData()
    if not DKP.IsOfficer() then return end
    local channel = GetChannel()
    if not channel then DKP.Print("不在队伍中"); return end
    if DKP.SerializeSheets then
        local data = DKP.SerializeSheets()
        if data ~= "" then
            SendChunked(DKP.ADDON_PREFIX, "SYNC_SHEETS", data, channel)
            DKP.Print("已广播: 掉落列表")
        end
    end
end

function DKP.BroadcastActivityData()
    if not DKP.IsOfficer() then return end
    local channel = GetChannel()
    if not channel then DKP.Print("不在队伍中"); return end
    if DKP.SerializeActivity then
        local act = {
            name = "sync",
            startTime = DKP.db.session and DKP.db.session.startTime or 0,
            endTime = time(),
            log = DKP.db.log or {},
            auctionHistory = DKP.db.auctionHistory or {},
            sheets = {},
            players = {},
        }
        local data = DKP.SerializeActivity(act)
        if data ~= "" then
            SendChunked(DKP.ADDON_PREFIX, "SYNC_ACTIVITY", data, channel)
            DKP.Print("已广播: 操作记录和拍卖记录")
        end
    end
end

----------------------------------------------------------------------
-- 全量广播（含 players + options + admins）
----------------------------------------------------------------------
function DKP.BroadcastFullSync()
    if not DKP.IsOfficer() then return end
    if not GetChannel() then
        DKP.Print("不在队伍中，无法广播")
        return
    end

    DKP.Print("开始全量同步 (分5批发送)...")

    -- 第1批: 权限
    DKP.BroadcastAdminSync()

    -- 第2批: DKP数据（延迟1秒）
    C_Timer.After(1, function() DKP.BroadcastDKPData() end)

    -- 第3批: 配置（延迟3秒）
    C_Timer.After(3, function() DKP.BroadcastOptions() end)

    -- 第4批: 掉落列表（延迟5秒）
    C_Timer.After(5, function() DKP.BroadcastSheetsData() end)

    -- 第5批: 操作记录+拍卖记录（延迟30秒，等前面 chunks 全部发完）
    C_Timer.After(30, function() DKP.BroadcastActivityData() end)
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
        pendingActivitySync[sKey] = { chunks = {}, expected = totalChunks, lastReceived = GetTime() }
    end
    local sync = pendingActivitySync[sKey]
    sync.chunks[chunkIndex] = chunkData
    sync.lastReceived = GetTime()

    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if totalChunks > 5 and (received % 5 == 0 or received == totalChunks) then
        DKP.Print("|cff888888[接收] 活动数据 " .. received .. "/" .. totalChunks .. "|r")
    end

    -- 超时检测：5秒内没收到新 chunk 且未收全，提示丢包
    if received < sync.expected then
        C_Timer.After(8, function()
            if pendingActivitySync[sKey] and pendingActivitySync[sKey].lastReceived
               and (GetTime() - pendingActivitySync[sKey].lastReceived) >= 7 then
                local got = 0
                for _ in pairs(pendingActivitySync[sKey].chunks) do got = got + 1 end
                if got < pendingActivitySync[sKey].expected then
                    local missing = pendingActivitySync[sKey].expected - got
                    DKP.Print("|cffFF8800[同步] 活动数据传输中断: 收到 " .. got .. "/" ..
                        pendingActivitySync[sKey].expected .. " (丢失 " .. missing .. " 包，请重新同步)|r")
                    pendingActivitySync[sKey] = nil
                end
            end
        end)
    end

    if received >= sync.expected then
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingActivitySync[sKey] = nil

        DKP.Print("|cff888888[调试] 活动数据重组完成: " .. #text .. " 字节|r")

        if not IsTrustedSender(sender) then return end

        if DKP.DeserializeActivity then
            local act = DKP.DeserializeActivity(text)
            if act then
                local senderShort = GetShortName(sender)
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
            else
                DKP.Print("|cffFF4444[调试] DeserializeActivity 返回 nil|r")
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

    if totalChunks > 5 and (received % 5 == 0 or received == totalChunks) then
        DKP.Print("|cff888888[接收] 掉落列表 " .. received .. "/" .. totalChunks .. "|r")
    end

    if received >= sync.expected then
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingSheetsSync[sKey] = nil

        if not IsTrustedSender(sender) then return end

        local newSheets = DKP.DeserializeSheets(text)
        if not next(newSheets) then return end

        local senderShort = GetShortName(sender)

        -- 合并掉落列表（按 sheetName + encounterID + rollID 去重）
        for sheetName, newSheet in pairs(newSheets) do
            if not DKP.db.sheets[sheetName] then
                DKP.db.sheets[sheetName] = newSheet
            else
                local localSheet = DKP.db.sheets[sheetName]
                for _, newBoss in ipairs(newSheet.bosses or {}) do
                    -- 查找本地是否已有该 boss
                    local localBoss = nil
                    for _, lb in ipairs(localSheet.bosses or {}) do
                        if lb.encounterID == newBoss.encounterID then
                            localBoss = lb
                            break
                        end
                    end
                    if not localBoss then
                        table.insert(localSheet.bosses, newBoss)
                    else
                        -- 合并击杀状态
                        if newBoss.killed then localBoss.killed = true end
                        -- 合并 items（按 rollID 去重）
                        local existingRolls = {}
                        for _, item in ipairs(localBoss.items or {}) do
                            existingRolls[item.rollID] = true
                        end
                        for _, newItem in ipairs(newBoss.items or {}) do
                            if not existingRolls[newItem.rollID] then
                                table.insert(localBoss.items, newItem)
                            else
                                -- 更新已有 item 的 winner/dkp（可能对方已分配）
                                for _, item in ipairs(localBoss.items) do
                                    if item.rollID == newItem.rollID then
                                        if (newItem.winner or "") ~= "" and (item.winner or "") == "" then
                                            item.winner = newItem.winner
                                            item.winnerClass = newItem.winnerClass
                                            item.dkp = newItem.dkp
                                        end
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
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

        if not IsTrustedSender(sender) then return end

        local newOpts = DeserializeOptions(text)
        if next(newOpts) then
            for k, v in pairs(newOpts) do
                DKP.db.options[k] = v
            end
            local senderShort = GetShortName(sender)
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
        elseif msgType == "ADMIN_SYNC" or msgType == "TEAM_SYNC" then
            HandleTeamSync(parts, sender)
        elseif msgType == "HISTORY_ENTRY" then
            HandleHistoryChunk(parts, sender)
        elseif msgType == "VERSION_QUERY" then
            -- 回复自己的版本号 + 团队信息
            local teamName = DKP.GetCurrentTeamName and DKP.GetCurrentTeamName() or "?"
            local teamID = DKP.GetCurrentTeamID and DKP.GetCurrentTeamID() or "?"
            local reply = table.concat({ "VERSION_REPLY", DKP.version or "?", DKP.playerName or "?", teamName, teamID }, MSG_SEP)
            DKP.SendDKPMessage(reply)
        elseif msgType == "VERSION_REPLY" then
            -- 收集版本回复（含团队信息）
            local version = parts[2] or "?"
            local playerName = parts[3] or "?"
            local teamName = parts[4] or "?"
            local teamID = parts[5] or "?"
            local senderShort2 = GetShortName(sender)
            if DKP._versionResults then
                DKP._versionResults[senderShort2] = { version = version, name = playerName, teamName = teamName, teamID = teamID, time = GetTime() }
                if DKP._refreshVersionUI then DKP._refreshVersionUI() end
            end
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
