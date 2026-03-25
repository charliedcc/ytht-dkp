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
        end
        return trusted
    end
    return true
end

----------------------------------------------------------------------
-- 同步确认弹窗（管理员收到同步数据时确认）
-- 每种数据类型用独立弹窗名，避免后到的弹窗覆盖前一个
----------------------------------------------------------------------
for _, suffix in ipairs({"DKP", "SHEETS", "LOG", "AUCTION", "ACTIVITY"}) do
    StaticPopupDialogs["YTHT_DKP_SYNC_" .. suffix] = {
        text = "%s",
        button1 = "接受",
        button2 = "拒绝",
        OnAccept = function(self, data)
            if data and data.apply then
                data.apply()
            end
        end,
        timeout = 60,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
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
-- 冲红广播：通知其他客户端标记某条日志为已冲红
-- 发送: REVERSE\tentryID  （用 UUID 精确匹配）
----------------------------------------------------------------------
function DKP.BroadcastReverse(entryID)
    if not DKP.IsOfficer() then return end
    if not entryID then return end
    local msg = table.concat({ "REVERSE", entryID }, MSG_SEP)
    DKP.SendDKPMessage(msg)
end

----------------------------------------------------------------------
-- 单条日志广播（批量操作完成后发送，接收方追加到本地日志）
-- 复用 SerializeLogEntry 格式，单条消息即可
----------------------------------------------------------------------
function DKP.BroadcastLogEntry(entry)
    if not DKP.IsOfficer() then return end
    if not entry then return end
    if DKP.SerializeLogEntryFn then
        local data = DKP.SerializeLogEntryFn(entry)
        if data and data ~= "" then
            local msg = table.concat({ "LOG_ENTRY", data }, MSG_SEP)
            DKP.SendDKPMessage(msg)
        end
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
-- WoW addon message 限制: 约10条突发，之后每秒恢复1条
-- burst 配额是全局共享的（所有前缀 + 频道），要留足余量
local CHUNK_BURST_LIMIT = 4       -- 保守 burst（其他插件也占配额）
local CHUNK_BURST_INTERVAL = 0.15 -- 突发期间隔（略长以防丢包）
local CHUNK_SLOW_INTERVAL = 1.2   -- 突发后间隔（确保恢复 1 token）

local function SendChunked(prefix, msgType, data, channel, target, onComplete)
    -- 动态计算 chunk 大小，确保总消息 <= 255 字节
    local headerReserve = #msgType + 12
    local chunkSize = 255 - headerReserve
    if chunkSize < 50 then chunkSize = 50 end

    local totalLen = #data
    local numChunks = math.ceil(totalLen / chunkSize)
    if numChunks == 0 then numChunks = 1 end

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
            if i == numChunks and onComplete then
                -- 等消息队列 burst bucket 恢复再启动下一批
                C_Timer.After(4, onComplete)
            end
        end)
    end
end

----------------------------------------------------------------------
-- 串行发送队列：上一批发完再发下一批
----------------------------------------------------------------------
local function RunSendChain(steps)
    local function runNext(idx)
        if idx > #steps then return end
        steps[idx](function()
            runNext(idx + 1)
        end)
    end
    runNext(1)
end

----------------------------------------------------------------------
-- 全量同步响应（管理员端）
----------------------------------------------------------------------
local function HandleSyncRequest(sender)
    if not DKP.IsOfficer() then return end

    RunSendChain({
        -- 1. 权限
        function(done)
            DKP.BroadcastAdminSync()
            -- TEAM_SYNC 通常很小（1-2 chunk），等 0.5s 再继续
            C_Timer.After(0.5, done)
        end,
        -- 2. DKP 数据
        function(done)
            local data = SerializePlayers()
            if data ~= "" then
                SendChunked(DKP.ADDON_PREFIX, "SYNC_FULL", data, nil, sender, done)
            else
                done()
            end
        end,
        -- 3. Options
        function(done)
            local optsData = SerializeOptions()
            if optsData ~= "" then
                SendChunked(DKP.ADDON_PREFIX, "SYNC_OPTIONS", optsData, nil, sender, done)
            else
                done()
            end
        end,
        -- 4. Sheets
        function(done)
            if DKP.SerializeSheets then
                local sheetsData = DKP.SerializeSheets()
                if sheetsData ~= "" then
                    SendChunked(DKP.ADDON_PREFIX, "SYNC_SHEETS", sheetsData, nil, sender, done)
                else
                    done()
                end
            else
                done()
            end
        end,
    })
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
        if not IsTrustedSender(sender) then return end

        -- 应用同步数据
        local playersData = DeserializePlayers(text)
        if not next(playersData) then return end

        local count = 0
        for _ in pairs(playersData) do count = count + 1 end

        local function applySync()
            -- 完全替换玩家列表（管理员数据为准）
            local newPlayers = {}
            for name, data in pairs(playersData) do
                newPlayers[name] = {
                    dkp = data.dkp,
                    characters = data.characters,
                    lastUpdated = time(),
                }
            end
            DKP.db.players = newPlayers
            if DKP.RebuildCharLookup then DKP.RebuildCharLookup() end
            DKP.Print("已从 " .. GetShortName(sender) .. " 同步 DKP 数据 (" .. count .. " 名玩家)")
            if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
        end

        if DKP.IsAdminMode() then
            StaticPopup_Show("YTHT_DKP_SYNC_DKP",
                format("收到来自 |cff00FF00%s|r 的 DKP 数据\n(%d 名玩家)\n\n是否覆盖本地数据？",
                    GetShortName(sender), count),
                nil, { apply = applySync })
        else
            applySync()
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

    -- 如果收到其他管理员的 Boss 击杀加分，标记本地 bossKills 防止重复
    if reason:find("Boss击杀:") and DKP.db.session then
        -- 从 reason 提取 encounterName，标记已加分
        local bossName = reason:match("Boss击杀: ([^(]+)")
        if bossName then
            bossName = bossName:match("^%s*(.-)%s*$")
            -- 查找对应的 encounterID
            if DKP.db.sheets then
                for _, sheet in pairs(DKP.db.sheets) do
                    for _, boss in ipairs(sheet.bosses or {}) do
                        if boss.name == bossName and boss.encounterID then
                            DKP.db.session.bossKills[boss.encounterID] = true
                        end
                    end
                end
            end
        end
        -- 关闭本地的 boss 击杀确认框（如果还开着）
        if DKP._bossKillConfirmDialog and DKP._bossKillConfirmDialog:IsShown() then
            DKP._bossKillConfirmDialog:Hide()
            DKP.Print("其他管理员已执行Boss击杀加分，自动跳过")
        end
    end

    -- 更新本地数据
    if DKP.db.players[playerName] then
        DKP.db.players[playerName].dkp = newDKP
        DKP.db.players[playerName].lastUpdated = time()
    end

    -- 追加到本地日志
    if changeAmount then
        table.insert(DKP.db.log, {
            id = DKP.GenerateLogID and DKP.GenerateLogID() or (time() .. "_" .. math.random(100000, 999999)),
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
        return
    end
    if masterAdmin == "" then masterAdmin = nil end

    local senderShort = GetShortName(sender)

    local newAdmins = {}
    for name in adminsStr:gmatch("[^;]+") do newAdmins[name] = true end

    -- 发送者必须在 admins 列表中
    if not newAdmins[senderShort] then
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
        return
    end


    -- 检查本地是否已有这个团队
    if DKP.db.teams[teamID] then
        -- 已有：更新权限
        local team = DKP.db.teams[teamID]
        team.admins = newAdmins
        if masterAdmin then team.masterAdmin = masterAdmin end
        team.name = teamName

        -- 团员自动切换到该团队（TEAM_SYNC 明确指定了 teamID）
        if DKP.db.currentTeam ~= teamID and not DKP.IsAdminMode() then
            DKP.SwitchTeam(teamID)
            -- 确保团员模式
            if DKP.db.mode ~= "member" and not (team.admins and team.admins[DKP.playerName]) then
                DKP.db.mode = "member"
            end
            DKP.Print("已自动切换到团队: " .. teamName)
        end

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
    end
end

function DKP.BroadcastOptions()
    if not DKP.IsOfficer() then return end
    local channel = GetChannel()
    if not channel then DKP.Print("不在队伍中"); return end
    local data = SerializeOptions()
    if data ~= "" then
        SendChunked(DKP.ADDON_PREFIX, "SYNC_OPTIONS", data, channel)
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
        end
    end
end

function DKP.BroadcastActivityData()
    if not DKP.IsOfficer() then return end
    DKP.BroadcastLogData()
    C_Timer.After(5, function() DKP.BroadcastAuctionHistoryData() end)
end

function DKP.BroadcastLogData()
    if not DKP.IsOfficer() then return end
    local channel = GetChannel()
    if not channel then DKP.Print("不在队伍中"); return end
    if DKP.SerializeActivity then
        local act = {
            name = "sync_log",
            startTime = 0, endTime = time(),
            log = DKP.db.log or {},
            auctionHistory = {},
            sheets = {}, players = {},
        }
        local data = DKP.SerializeActivity(act)
        if data ~= "" then
            SendChunked(DKP.ADDON_PREFIX, "SYNC_LOG", data, channel)
        end
    end
end

function DKP.BroadcastAuctionHistoryData()
    if not DKP.IsOfficer() then return end
    local channel = GetChannel()
    if not channel then DKP.Print("不在队伍中"); return end
    if DKP.SerializeActivity then
        local act = {
            name = "sync_history",
            startTime = 0, endTime = time(),
            log = {},
            auctionHistory = DKP.db.auctionHistory or {},
            sheets = {}, players = {},
        }
        local data = DKP.SerializeActivity(act)
        if data ~= "" then
            SendChunked(DKP.ADDON_PREFIX, "SYNC_AUCTION_HISTORY", data, channel)
        end
    end
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

    DKP.Print("开始全量同步...")

    RunSendChain({
        -- 1. 权限
        function(done)
            DKP.BroadcastAdminSync()
            C_Timer.After(0.5, done)
        end,
        -- 2. DKP 数据
        function(done)
            local data = SerializePlayers()
            if data ~= "" then
                DKP.Print("正在同步 DKP 数据...")
                SendChunked(DKP.ADDON_PREFIX, "SYNC_FULL", data, channel, nil, done)
            else
                done()
            end
        end,
        -- 3. Options
        function(done)
            local optsData = SerializeOptions()
            if optsData ~= "" then
                DKP.Print("正在同步配置...")
                SendChunked(DKP.ADDON_PREFIX, "SYNC_OPTIONS", optsData, channel, nil, function()
                    DKP.Print("[同步进度] 配置发送完成")
                    done()
                end)
            else
                DKP.Print("[同步进度] 无配置数据，跳过")
                done()
            end
        end,
        -- 4. 掉落列表
        function(done)
            if DKP.SerializeSheets then
                local sheetsData = DKP.SerializeSheets()
                if sheetsData ~= "" then
                    local numChunks = math.ceil(#sheetsData / (255 - #"SYNC_SHEETS" - 12))
                    DKP.Print("正在同步掉落列表... (" .. #sheetsData .. " 字节, " .. numChunks .. " 包)")
                    SendChunked(DKP.ADDON_PREFIX, "SYNC_SHEETS", sheetsData, channel, nil, function()
                        DKP.Print("[同步进度] 掉落列表发送完成")
                        done()
                    end)
                else
                    DKP.Print("[同步进度] 无掉落列表数据，跳过")
                    done()
                end
            else
                DKP.Print("[同步进度] SerializeSheets 不存在，跳过")
                done()
            end
        end,
        -- 5. 拍卖记录
        function(done)
            if DKP.SerializeActivity then
                local act = {
                    name = "sync_history", startTime = 0, endTime = time(),
                    log = {}, auctionHistory = DKP.db.auctionHistory or {},
                    sheets = {}, players = {},
                }
                local data = DKP.SerializeActivity(act)
                if data ~= "" then
                    local numChunks = math.ceil(#data / (255 - #"SYNC_AUCTION_HISTORY" - 12))
                    DKP.Print("正在同步拍卖记录... (" .. #data .. " 字节, " .. numChunks .. " 包)")
                    SendChunked(DKP.ADDON_PREFIX, "SYNC_AUCTION_HISTORY", data, channel, nil, function()
                        DKP.Print("[同步进度] 拍卖记录发送完成")
                        done()
                    end)
                else
                    DKP.Print("[同步进度] 无拍卖记录数据，跳过")
                    done()
                end
            else
                done()
            end
        end,
        -- 6. 操作记录
        function(done)
            if DKP.SerializeActivity then
                local act = {
                    name = "sync_log", startTime = 0, endTime = time(),
                    log = DKP.db.log or {}, auctionHistory = {},
                    sheets = {}, players = {},
                }
                local data = DKP.SerializeActivity(act)
                if data ~= "" then
                    local numChunks = math.ceil(#data / (255 - #"SYNC_LOG" - 12))
                    DKP.Print("正在同步操作记录... (" .. #data .. " 字节, " .. numChunks .. " 包)")
                    SendChunked(DKP.ADDON_PREFIX, "SYNC_LOG", data, channel, nil, function()
                        DKP.Print("[同步进度] 操作记录发送完成")
                        done()
                    end)
                else
                    DKP.Print("[同步进度] 无操作记录数据，跳过")
                    done()
                end
            else
                done()
            end
        end,
        -- 完成
        function(done)
            DKP.Print("|cff00FF00全量同步完成|r")
            done()
        end,
    })
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
        -- sheetName|createdAt=boss1@@boss2@@boss3
        local createdAt = sheet.createdAt or 0
        table.insert(parts, sheetName .. "|" .. tostring(createdAt) .. "=" .. table.concat(bossParts, "@@"))
    end
    return table.concat(parts, "\n")
end

function DKP.DeserializeSheets(text)
    local result = {}
    for line in text:gmatch("[^\n]+") do
        local sheetName, bossesStr = line:match("^(.-)=(.*)$")
        if sheetName then
            -- 解析 createdAt（格式: sheetName|createdAt=...，兼容旧格式 sheetName=...）
            local createdAt = 0
            if sheetName:find("|") then
                local name, ts = sheetName:match("^(.-)|(%d+)$")
                if name then
                    sheetName = name
                    createdAt = tonumber(ts) or 0
                end
            end
            local sheet = { bosses = {}, createdAt = createdAt }
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
local pendingLogSync = {}
local pendingAuctionHistSync = {}

-- 通用 activity 格式接收器（用于 SYNC_LOG / SYNC_AUCTION_HISTORY / SYNC_ACTIVITY）
local function HandleActivityFormatChunk(parts, sender, pendingTable, sKey, label, applyFn)
    local chunkIndex = tonumber(parts[2])
    local totalChunks = tonumber(parts[3])
    local chunkData = parts[4] or ""
    if not chunkIndex or not totalChunks then return end

    if not pendingTable[sKey] then
        pendingTable[sKey] = { chunks = {}, expected = totalChunks, lastReceived = GetTime() }
    end
    local sync = pendingTable[sKey]
    sync.chunks[chunkIndex] = chunkData
    sync.lastReceived = GetTime()

    local received = 0
    for _ in pairs(sync.chunks) do received = received + 1 end

    if totalChunks > 5 and (received % 5 == 0 or received == totalChunks) then
    end

    if received >= sync.expected then
        DKP.Print("|cff888888[" .. label .. "] 收齐 " .. received .. " 包，开始解析...|r")
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingTable[sKey] = nil

        if not IsTrustedSender(sender) then
            DKP.Print("|cffFF4444[" .. label .. "] 不信任的发送者: " .. sender .. "|r")
            return
        end

        if DKP.DeserializeActivity then
            local act = DKP.DeserializeActivity(text)
            if act then
                DKP.Print("|cff888888[" .. label .. "] 解析成功: log=" .. #(act.log or {}) .. " auction=" .. #(act.auctionHistory or {}) .. "|r")
                applyFn(act, sender)
            else
                DKP.Print("|cffFF4444[" .. label .. "] DeserializeActivity 返回 nil (数据长度: " .. #text .. ", 前50字符: " .. text:sub(1, 50) .. ")|r")
            end
        else
            DKP.Print("|cffFF4444[" .. label .. "] DKP.DeserializeActivity 不存在|r")
        end
    end
end

local function HandleLogChunk(parts, sender)
    HandleActivityFormatChunk(parts, sender, pendingLogSync, sender .. "_log", "操作记录", function(act, s)
        if not act.log or #act.log == 0 then return end

        local function applyLog()
            DKP.db.log = act.log
            DKP.Print("已同步操作记录 (" .. #act.log .. " 条, 来自 " .. GetShortName(s) .. ")")
            if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
        end

        if DKP.IsAdminMode() then
            StaticPopup_Show("YTHT_DKP_SYNC_LOG",
                format("收到来自 |cff00FF00%s|r 的操作记录\n(%d 条)\n\n是否覆盖本地数据？",
                    GetShortName(s), #act.log),
                nil, { apply = applyLog })
        else
            applyLog()
        end
    end)
end

local function HandleAuctionHistChunk(parts, sender)
    HandleActivityFormatChunk(parts, sender, pendingAuctionHistSync, sender .. "_ahist", "拍卖记录", function(act, s)
        if not act.auctionHistory or #act.auctionHistory == 0 then return end

        local function applyHist()
            DKP.db.auctionHistory = act.auctionHistory
            DKP.Print("已同步拍卖记录 (" .. #act.auctionHistory .. " 条, 来自 " .. GetShortName(s) .. ")")
            if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
        end

        if DKP.IsAdminMode() then
            StaticPopup_Show("YTHT_DKP_SYNC_AUCTION",
                format("收到来自 |cff00FF00%s|r 的拍卖记录\n(%d 条)\n\n是否覆盖本地数据？",
                    GetShortName(s), #act.auctionHistory),
                nil, { apply = applyHist })
        else
            applyHist()
        end
    end)
end

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


        if not IsTrustedSender(sender) then return end

        if DKP.DeserializeActivity then
            local act = DKP.DeserializeActivity(text)
            if act then
                local senderShort = GetShortName(sender)
                local logCount = #(act.log or {})
                local histCount = #(act.auctionHistory or {})

                local function applyActivity()
                    if act.log and #act.log > 0 then
                        DKP.db.log = act.log
                    end
                    if act.auctionHistory and #act.auctionHistory > 0 then
                        DKP.db.auctionHistory = act.auctionHistory
                    end
                    DKP.Print("已同步活动数据 (来自 " .. senderShort .. "): " ..
                        logCount .. " 条日志, " .. histCount .. " 条拍卖")
                    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
                    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
                end

                if DKP.IsAdminMode() then
                    StaticPopup_Show("YTHT_DKP_SYNC_ACTIVITY",
                        format("收到来自 |cff00FF00%s|r 的活动数据\n(%d 条日志, %d 条拍卖)\n\n是否覆盖本地数据？",
                            senderShort, logCount, histCount),
                        nil, { apply = applyActivity })
                else
                    applyActivity()
                end
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
    end

    if received >= sync.expected then
        DKP.Print("|cff888888[Sheets] 收齐 " .. received .. " 包，开始解析...|r")
        local fullData = {}
        for i = 1, sync.expected do
            table.insert(fullData, sync.chunks[i] or "")
        end
        local text = table.concat(fullData)
        pendingSheetsSync[sKey] = nil

        if not IsTrustedSender(sender) then
            DKP.Print("|cffFF4444[Sheets] 不信任的发送者: " .. sender .. "|r")
            return
        end

        local newSheets = DKP.DeserializeSheets(text)
        if not next(newSheets) then
            DKP.Print("|cffFF4444[Sheets] 反序列化结果为空 (数据长度: " .. #text .. ")|r")
            return
        end

        local senderShort = GetShortName(sender)
        local sheetCount = 0
        for _ in pairs(newSheets) do sheetCount = sheetCount + 1 end

        local function applySheets()
            -- 完全替换掉落列表（管理员数据为准）
            DKP.db.sheets = newSheets
            DKP.Print("已同步掉落列表 (" .. sheetCount .. " 个副本, 来自 " .. senderShort .. ")")
            if DKP.RefreshTableUI then DKP.RefreshTableUI() end
        end

        if DKP.IsAdminMode() then
            StaticPopup_Show("YTHT_DKP_SYNC_SHEETS",
                format("收到来自 |cff00FF00%s|r 的掉落列表\n(%d 个副本)\n\n是否覆盖本地数据？",
                    senderShort, sheetCount),
                nil, { apply = applySheets })
        else
            applySheets()
        end
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
            -- 完全替换配置（保留未同步的本地字段如 enableChatAuction）
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

        -- DEBUG: 显示接收到的同步消息类型和分包进度
        if msgType and msgType:find("^SYNC_") then
            local ci = parts[2] or "?"
            local tc = parts[3] or "?"
            DKP.Print("|cff888888[收到] " .. msgType .. " " .. ci .. "/" .. tc .. " (来自 " .. GetShortName(sender) .. ")|r")
        end

        if msgType == "REVERSE" then
            -- 冲红通知：按 UUID 匹配本地日志并标记 reversed
            if IsTrustedSender(sender) then
                local entryID = parts[2] or ""
                local senderShort = GetShortName(sender)
                local found = false
                local foundEntry = nil
                local foundIndex = 0
                if entryID ~= "" then
                    for i, e in ipairs(DKP.db.log) do
                        if e.id == entryID and not e.reversed then
                            e.reversed = true
                            found = true
                            foundEntry = e
                            foundIndex = i
                            break
                        end
                    end
                end
                if found and foundEntry then
                    -- 生成本地冲红记录
                    local genID = DKP.GenerateLogID and DKP.GenerateLogID() or (time() .. "_" .. math.random(100000, 999999))
                    local reverseEntry = {
                        id = genID,
                        type = "reverse",
                        amount = -(foundEntry.amount or 0),
                        reason = "冲红: " .. (foundEntry.reason or ""),
                        timestamp = time(),
                        officer = senderShort,
                        reversedIndex = foundIndex,
                    }
                    -- 复制玩家信息
                    if foundEntry.players then
                        reverseEntry.players = foundEntry.players
                    else
                        reverseEntry.player = foundEntry.player
                    end
                    table.insert(DKP.db.log, reverseEntry)
                    DKP.Print("收到冲红通知 (来自 " .. senderShort .. ")")
                    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
                else
                    DKP.Print("|cff888888收到冲红通知但未找到匹配记录 (来自 " .. senderShort .. ", id=" .. entryID .. ")|r")
                end
            end
        elseif msgType == "LOG_ENTRY" then
            -- 单条日志追加（批量操作后广播）
            if IsTrustedSender(sender) then
                local data = parts[2] or ""
                if data ~= "" then
                    local fields = {}
                    for part in data:gmatch("[^,]+") do table.insert(fields, part) end
                    if #fields >= 6 then
                        local entry = {
                            timestamp = tonumber(fields[1]) or 0,
                            type = fields[2] or "award",
                            amount = tonumber(fields[4]) or 0,
                            reason = (fields[5] or ""):gsub(";", ","),
                            officer = fields[6] or "",
                            reversed = fields[7] == "1",
                            id = fields[8] and fields[8] ~= "" and fields[8] or nil,
                        }
                        local playerField = fields[3] or ""
                        if playerField:find(";") then
                            if playerField:find(":%-?%d") then
                                entry.players = {}
                                for pd in playerField:gmatch("[^;]+") do
                                    local n, a = pd:match("^(.+):(%-?%d+)$")
                                    if n then table.insert(entry.players, { name = n, amount = tonumber(a) }) end
                                end
                            else
                                entry.players = {}
                                for n in playerField:gmatch("[^;]+") do table.insert(entry.players, n) end
                            end
                        else
                            entry.player = playerField
                        end
                        -- 去重：按 id 检查
                        local dup = false
                        if entry.id then
                            for _, e in ipairs(DKP.db.log) do
                                if e.id == entry.id then dup = true; break end
                            end
                        end
                        if not dup then
                            table.insert(DKP.db.log, entry)
                            if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
                        end
                    end
                end
            end
        elseif msgType == "DKP_CHANGE" then
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
        elseif msgType == "SYNC_LOG" then
            HandleLogChunk(parts, sender)
        elseif msgType == "SYNC_AUCTION_HISTORY" then
            HandleAuctionHistChunk(parts, sender)
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
                -- 管理员自动切换到管理模式
                if DKP.db and DKP.db.mode ~= "admin" then
                    DKP.db.mode = "admin"
                    DKP.Print("|cff00FF00检测到管理员身份，已自动切换到管理模式|r")
                    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
                    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
                end
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
