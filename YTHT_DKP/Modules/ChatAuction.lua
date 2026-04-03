----------------------------------------------------------------------
-- YTHT DKP - Chat Auction (聊天竞拍)
--
-- 监听团队/小队频道，自动收集竞价
-- 管理员在掉落列表点「聊天拍」发起 -> 团员在聊天打数字/sh/p竞拍
-- 结束后生成拍卖记录(CHAT_PENDING)，需人工在拍卖记录中确认扣分
----------------------------------------------------------------------

local DKP = YTHT_DKP

-- UI 常量
local PANEL_WIDTH = 440
local PANEL_HEIGHT = 450
local TITLE_COLOR = { r = 0.00, g = 0.75, b = 1.00 }
local ROW_HEIGHT = 16

-- 状态
local chatAuction = nil   -- 当前聊天竞拍
local chatAucCounter = 0
local panel = nil
local bidFontStrings = {}

local MSG_SEP = "\t"

----------------------------------------------------------------------
-- 插件通信：同步聊天竞拍状态给其他管理员
----------------------------------------------------------------------
local function SendChatAucMsg(msg)
    if IsInRaid() then
        C_ChatInfo.SendAddonMessage(DKP.AUCTION_PREFIX, msg, "RAID")
    elseif IsInGroup() then
        C_ChatInfo.SendAddonMessage(DKP.AUCTION_PREFIX, msg, "PARTY")
    end
end

----------------------------------------------------------------------
-- 查询当前聊天竞拍状态（供外部调用）
----------------------------------------------------------------------
function DKP.HasActiveChatAuction()
    return chatAuction ~= nil
end

----------------------------------------------------------------------
-- 工具
----------------------------------------------------------------------
local function StripRealm(name)
    return name and name:match("^([^%-]+)") or name
end

local function GetLocalFullPlayerName()
    if DKP.playerFullName and DKP.playerFullName ~= "" then
        return DKP.playerFullName
    end
    if DKP.playerName and DKP.playerName ~= "" then
        return DKP.playerName .. "-" .. GetRealmName()
    end
    return DKP.playerName
end

local function CanManageChatAuction()
    return DKP.IsOfficer and DKP.IsOfficer()
        and DKP.IsAdminMode and DKP.IsAdminMode()
end

local function GetItemIDFromLink(itemLink)
    return itemLink and itemLink:match("item:(%d+)") or nil
end

local function ParseBid(msg)
    msg = msg:match("^%s*(.-)%s*$")
    if not msg or msg == "" then return nil end
    local lower = msg:lower()
    -- pass
    if lower == "p" or lower == "pass" then
        return "pass", 0
    end
    -- 梭哈
    if lower == "sh" or msg == "梭哈" then
        return "allin", 0
    end
    -- 纯数字
    local num = tonumber(msg)
    if num and num > 0 and num == math.floor(num) then
        return "bid", num
    end
    return nil
end

----------------------------------------------------------------------
-- 获取聊天频道
----------------------------------------------------------------------
local function GetChatChannel()
    if IsInRaid() then return "RAID"
    elseif IsInGroup() then return "PARTY"
    end
    return nil
end

----------------------------------------------------------------------
-- 获取当前最高出价
----------------------------------------------------------------------
local function GetCurrentHighestBid()
    if not chatAuction or #chatAuction.bids == 0 then return 0 end
    local highest = 0
    for _, bid in ipairs(chatAuction.bids) do
        if bid.bidType ~= "pass" and bid.amount > highest then
            highest = bid.amount
        end
    end
    return highest
end

local function BuildDisplayResultFromHistoryEntry(entry)
    local activeBids = {}
    local passPlayers = {}
    local winner = nil
    local tiedBidders = nil
    local finalBid = entry and (entry.finalBid or 0) or 0

    if not entry then
        return activeBids, passPlayers, winner, tiedBidders, finalBid
    end

    for _, bid in ipairs(entry.bids or {}) do
        local displayBid = {
            charName = bid.bidder or bid.bidderPlayer or "?",
            playerName = bid.bidderPlayer or bid.bidder or "?",
            charClass = bid.bidderClass or entry.winnerClass or "WARRIOR",
            bidType = bid.bidType,
            amount = bid.amount or 0,
            isAllIn = bid.isAllIn and true or false,
            playerDKP = bid.playerDKP or 0,
            rawMessage = bid.rawMessage,
            timestamp = bid.timestamp or 0,
            inDKPSystem = bid.bidderPlayer ~= nil,
        }

        local isPass = bid.bidType == "pass"
            or ((bid.amount or 0) == 0 and not bid.isAllIn and entry.state ~= "ENDED")
        if isPass then
            table.insert(passPlayers, displayBid)
        else
            table.insert(activeBids, displayBid)
        end
    end

    if entry.tiedBidders and #entry.tiedBidders >= 2 then
        tiedBidders = {}
        for _, tb in ipairs(entry.tiedBidders) do
            table.insert(tiedBidders, {
                charName = tb.name or tb.playerName or "?",
                playerName = tb.playerName or tb.name or "?",
                charClass = entry.winnerClass or "WARRIOR",
            })
        end
    elseif entry.winner then
        winner = {
            charName = entry.winnerChar or entry.winner,
            playerName = entry.winner,
            charClass = entry.winnerClass or "WARRIOR",
            amount = finalBid,
            isAllIn = false,
        }
    end

    return activeBids, passPlayers, winner, tiedBidders, finalBid
end

local function RecordChatAuctionBid(sender, msg, timestamp, isLocalPreview)
    if not chatAuction or chatAuction.state ~= "collecting" then return false end

    local bidType, bidAmount = ParseBid(msg)
    if not bidType then return false end

    local charName = StripRealm(sender)
    local playerName = DKP.GetPlayerByCharacter and DKP.GetPlayerByCharacter(charName) or charName

    local resolvedAmount = bidAmount
    local isAllIn = false
    if bidType == "allin" then
        isAllIn = true
        local playerData = DKP.db and DKP.db.players[playerName]
        resolvedAmount = playerData and math.max(0, playerData.dkp or 0) or 0
    end

    local charClass = "WARRIOR"
    local playerData = DKP.db and DKP.db.players[playerName]
    local playerDKP = 0
    if playerData then
        playerDKP = playerData.dkp or 0
        for _, char in ipairs(playerData.characters or {}) do
            if char.name == charName then
                charClass = char.class
                break
            end
        end
    end

    local ch = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    local shouldBroadcast = (not isLocalPreview) and ch
        and DKP.IsOfficer and DKP.IsOfficer()
        and (not DKP.db or not DKP.db.options or DKP.db.options.enableChatAuctionBroadcast ~= false)

    if bidType == "bid" and playerData and resolvedAmount > playerDKP then
        if shouldBroadcast then
            SendChatMessage("[竞拍] " .. charName .. " 出价 " .. resolvedAmount
                .. " 超过DKP余额(" .. playerDKP .. ")，不计入", ch)
        end
        return false
    end

    if bidType ~= "pass" then
        local prevMax = 0
        for _, b in ipairs(chatAuction.bids) do
            if b.playerName == playerName and b.bidType ~= "pass" and b.amount > prevMax then
                prevMax = b.amount
            end
        end
        if not isAllIn and resolvedAmount <= prevMax then
            if shouldBroadcast then
                SendChatMessage("[竞拍] " .. charName .. " 出价 " .. resolvedAmount
                    .. " 不高于当前出价(" .. prevMax .. ")，不计入", ch)
            end
            return false
        end
    end

    if isAllIn and shouldBroadcast then
        SendChatMessage("[竞拍] " .. charName .. " sh = " .. resolvedAmount .. " DKP", ch)
    end

    local rawMessage = msg:match("^%s*(.-)%s*$")
    local lastBid = chatAuction.bids[#chatAuction.bids]
    if lastBid
        and lastBid.playerName == playerName
        and lastBid.bidType == bidType
        and lastBid.amount == resolvedAmount
        and lastBid.rawMessage == rawMessage
        and math.abs((lastBid.timestamp or 0) - (timestamp or time())) <= 1 then
        return false
    end

    table.insert(chatAuction.bids, {
        charName = charName,
        playerName = playerName,
        charClass = charClass,
        bidType = bidType,
        amount = resolvedAmount,
        isAllIn = isAllIn,
        playerDKP = playerDKP,
        rawMessage = rawMessage,
        timestamp = timestamp or time(),
        inDKPSystem = playerData ~= nil,
    })

    if DKP.RefreshChatAuctionPanel then DKP.RefreshChatAuctionPanel() end
    return true
end

local function TryRecordLocalOutgoingBid(msg, chatType)
    if not chatAuction or chatAuction.state ~= "collecting" then return end
    if not msg or msg == "" then return end
    if chatType ~= "RAID" and chatType ~= "RAID_LEADER"
        and chatType ~= "PARTY" and chatType ~= "PARTY_LEADER" then
        return
    end

    -- Ignore addon-generated helper messages and only mirror actual bids.
    if msg:find("^%[竞拍") or msg:find("^%[DKP%]") or msg:find("^%[YTHT%-DKP%]") then
        return
    end

    RecordChatAuctionBid(GetLocalFullPlayerName(), msg, time(), true)
end

hooksecurefunc("SendChatMessage", function(msg, chatType)
    TryRecordLocalOutgoingBid(msg, chatType)
end)

----------------------------------------------------------------------
-- 在掉落列表中查找装备（精确匹配优先，item ID 兜底）
----------------------------------------------------------------------
local function IsUnassigned(item)
    return (not item.winner or item.winner == "") and not item.activeAuctionID
end

local function FindItemInSheets(itemLink)
    if not DKP.db or not DKP.db.sheets then return nil, nil end

    -- 精确匹配
    for _, sheet in pairs(DKP.db.sheets) do
        for _, boss in ipairs(sheet.bosses or {}) do
            for _, item in ipairs(boss.items or {}) do
                if item.link == itemLink and IsUnassigned(item) then
                    return item, boss
                end
            end
        end
    end

    -- 兜底：按 item ID 匹配
    local searchID = itemLink:match("item:(%d+)")
    if not searchID then return nil, nil end
    for _, sheet in pairs(DKP.db.sheets) do
        for _, boss in ipairs(sheet.bosses or {}) do
            for _, item in ipairs(boss.items or {}) do
                if item.link and IsUnassigned(item) then
                    if item.link:match("item:(%d+)") == searchID then
                        return item, boss
                    end
                end
            end
        end
    end
    return nil, nil
end

local function FindChatAuctionPlaceholderItem(instanceName, itemLink)
    if not DKP.db or not DKP.db.sheets or not instanceName then return nil, nil end

    local sheet = DKP.db.sheets[instanceName]
    if not sheet then return nil, nil end

    local searchID = GetItemIDFromLink(itemLink)
    for _, boss in ipairs(sheet.bosses or {}) do
        if boss.encounterID == 99999 or boss.name == "聊天拍卖" then
            for _, item in ipairs(boss.items or {}) do
                if IsUnassigned(item) and item.link then
                    local itemID = GetItemIDFromLink(item.link)
                    if item.link == itemLink or (searchID and itemID == searchID) then
                        return item, boss
                    end
                end
            end
        end
    end

    return nil, nil
end

local function FindLiveItemForChatAuctionEntry(entry)
    if not entry or not entry.itemLink or not DKP.db or not DKP.db.sheets then
        return nil
    end

    local searchID = GetItemIDFromLink(entry.itemLink)

    local function matchesItem(item)
        if not item or not item.link then return false end
        if item == entry.itemData then return true end
        if item.link == entry.itemLink then return true end
        local itemID = GetItemIDFromLink(item.link)
        return searchID and itemID and itemID == searchID
    end

    local function isAssignable(item)
        return not item.winner or item.winner == ""
    end

    local function searchItems(requireInstance, requireEncounter, exactLinkOnly)
        for sheetName, sheet in pairs(DKP.db.sheets or {}) do
            if not requireInstance or sheetName == entry.instanceName then
                for _, boss in ipairs(sheet.bosses or {}) do
                    if not requireEncounter or boss.name == entry.encounterName then
                        for _, item in ipairs(boss.items or {}) do
                            if isAssignable(item) and matchesItem(item) then
                                if not exactLinkOnly or item.link == entry.itemLink then
                                    return item
                                end
                            end
                        end
                    end
                end
            end
        end
        return nil
    end

    if entry.itemData and isAssignable(entry.itemData) then
        local liveByReference = searchItems(false, false, false)
        if liveByReference == entry.itemData then
            return liveByReference
        end
    end

    return searchItems(true, true, true)
        or searchItems(true, true, false)
        or searchItems(true, false, true)
        or searchItems(true, false, false)
        or searchItems(false, false, true)
        or searchItems(false, false, false)
end

local function FindAuctionHistoryEntryByID(entryID)
    if not entryID or not DKP.db or not DKP.db.auctionHistory then return nil end
    for _, historyEntry in ipairs(DKP.db.auctionHistory) do
        if historyEntry.id == entryID then
            return historyEntry
        end
    end
    return nil
end

----------------------------------------------------------------------
-- 计算当前竞拍结果（每人取最后一次动作）
----------------------------------------------------------------------
local function ComputeResult()
    if not chatAuction then return {}, {}, nil, nil, 0 end

    -- 每人最后一次动作
    local lastAction = {}  -- playerName -> bid entry
    local actionOrder = {} -- 保持顺序
    for _, bid in ipairs(chatAuction.bids) do
        if not lastAction[bid.playerName] then
            table.insert(actionOrder, bid.playerName)
        end
        lastAction[bid.playerName] = bid
    end

    -- 分成出价和pass
    local activeBids = {}
    local passPlayers = {}
    for _, pn in ipairs(actionOrder) do
        local bid = lastAction[pn]
        if bid.bidType == "pass" then
            table.insert(passPlayers, bid)
        else
            table.insert(activeBids, bid)
        end
    end

    -- 按金额降序，同分按时间升序
    table.sort(activeBids, function(a, b)
        if a.amount ~= b.amount then return a.amount > b.amount end
        return a.timestamp < b.timestamp
    end)

    -- 检测最高分并列
    local tiedBidders = nil
    local winner = nil
    local finalBid = 0
    if #activeBids > 0 then
        finalBid = activeBids[1].amount
        local tied = {}
        for _, bid in ipairs(activeBids) do
            if bid.amount == finalBid then
                table.insert(tied, bid)
            end
        end
        if #tied > 1 then
            tiedBidders = tied
        else
            winner = activeBids[1]
        end
    end

    return activeBids, passPlayers, winner, tiedBidders, finalBid
end

----------------------------------------------------------------------
-- 聊天事件监听
----------------------------------------------------------------------
local chatFrame = CreateFrame("Frame")
chatFrame:RegisterEvent("CHAT_MSG_RAID")
chatFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
chatFrame:RegisterEvent("CHAT_MSG_PARTY")
chatFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")

chatFrame:SetScript("OnEvent", function(self, event, msg, sender, ...)
    local senderShort = StripRealm(sender)

    -- ① 检测管理员发送的装备链接，自动发起（有进行中的拍卖会自动结束旧的）
    if not chatAuction or chatAuction.state == "collecting" then
        local senderIsAdmin = DKP.db and DKP.db.admins and DKP.db.admins[senderShort]
        if senderIsAdmin
           and DKP.IsOfficer and DKP.IsOfficer()
           and DKP.IsAdminMode and DKP.IsAdminMode()
           and (not DKP.db or not DKP.db.options or DKP.db.options.enableChatAuction ~= false) then
            -- 跳过插件自身产生的消息（拍卖结果、DKP通报等）
            if msg:find("^%[竞拍")
                or msg:find("^%[DKP%]")
                or msg:find("^%[YTHT%-DKP%]")
                or msg:find("^%[竞拍结束%]") then
                -- 插件消息，不触发自动竞拍
            else
                local itemLink = msg:match("(|c.-|Hitem:.-|h.-|h|r)")
                if itemLink then
                    -- 如果是当前正在拍的同一件装备的链接，不重复触发
                    if chatAuction and chatAuction.itemLink == itemLink then
                        -- 同一件装备，跳过
                    else
                        local foundItem, foundBoss = FindItemInSheets(itemLink)
                        if not foundItem then
                            local instanceName = DKP.db.currentSheet or "手动记录"

                            -- 若当前聊天拍占位区已有同件未分配物品，直接复用；
                            -- 不再用全局 itemID 去重，避免合法重复掉落（如兑换物）被挡掉。
                            foundItem, foundBoss = FindChatAuctionPlaceholderItem(instanceName, itemLink)

                            if not foundItem and DKP.db.options and DKP.db.options.enableAutoAddItem then
                                -- 自动添加到掉落列表
                                if DKP.GetOrCreateSheet then DKP.GetOrCreateSheet(instanceName) end
                                local bossName = "聊天拍卖"
                                local encounterID = 99999
                                if DKP.AddBossToSheet then
                                    foundBoss = DKP.AddBossToSheet(instanceName, bossName, encounterID)
                                end
                                if DKP.AddItemToBoss then
                                    local rollID = time() + math.random(10000)
                                    foundItem = DKP.AddItemToBoss(instanceName, encounterID, itemLink, rollID)
                                end
                                if foundItem then
                                    DKP.Print("自动添加装备到掉落列表: " .. (itemLink:match("%[(.-)%]") or itemLink))
                                    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
                                end
                            end
                        end
                        if foundItem then
                            DKP.StartChatAuction(itemLink, foundItem, foundBoss)
                        end
                    end
                end
            end
        end
        if not chatAuction then return end
    end

    -- ② 竞价收集中 → 解析出价
    if chatAuction.state ~= "collecting" then return end

    RecordChatAuctionBid(sender, msg, time(), false)
end)

----------------------------------------------------------------------
-- 发起聊天竞拍
----------------------------------------------------------------------
function DKP.StartChatAuction(itemLink, itemData, bossData)
    if not DKP.IsOfficer or not DKP.IsOfficer() then
        DKP.Print("只有管理员可以发起聊天竞拍")
        return false
    end
    -- 有进行中的竞拍则自动结束
    if chatAuction and chatAuction.state == "collecting" then
        DKP.EndChatAuction()
    end
    -- 清理残留状态（已结束但面板还开着）
    if chatAuction then
        chatAuction = nil
    end

    chatAucCounter = chatAucCounter + 1
    chatAuction = {
        id = "chat_" .. time() .. "_" .. chatAucCounter,
        itemLink = itemLink,
        itemData = itemData,
        bossData = bossData,
        encounterID = bossData and bossData.encounterID or nil,
        encounterName = bossData and bossData.name or nil,
        instanceName = DKP.db and DKP.db.currentSheet or nil,
        bids = {},
        startTime = time(),
        state = "collecting",
    }

    -- 发送到团队频道（始终带物品链接）
    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    if channel then
        SendChatMessage("[竞拍] " .. itemLink .. " 数字=出价 sh=全押 p=pass", channel)
    end

    -- 广播给其他管理员
    SendChatAucMsg(table.concat({
        "CHAT_START", chatAuction.id, itemLink,
        tostring(chatAuction.encounterID or ""),
        chatAuction.encounterName or "",
        chatAuction.instanceName or "",
    }, MSG_SEP))

    DKP.Print("聊天竞拍已开始: " .. itemLink)
    DKP.ShowChatAuctionPanel()
    return true
end

----------------------------------------------------------------------
-- 结束聊天竞拍
----------------------------------------------------------------------
function DKP.EndChatAuction()
    if not chatAuction then return end
    chatAuction.state = "ended"

    local activeBids, passPlayers, winner, tiedBidders, finalBid = ComputeResult()

    -- 构建历史 bids（每人只保留最终出价：sh 覆盖普通出价，pass 覆盖一切）
    local lastBidByPlayer = {}
    local bidOrder = {}
    for _, bid in ipairs(chatAuction.bids) do
        if not lastBidByPlayer[bid.playerName] then
            table.insert(bidOrder, bid.playerName)
        end
        lastBidByPlayer[bid.playerName] = bid
    end
    local historyBids = {}
    for _, pn in ipairs(bidOrder) do
        local bid = lastBidByPlayer[pn]
        table.insert(historyBids, {
            bidder = bid.charName,
            bidderPlayer = bid.playerName,
            bidderClass = bid.charClass,
            amount = bid.amount,
            timestamp = bid.timestamp,
            isAllIn = bid.isAllIn,
            rawMessage = bid.rawMessage,
            bidType = bid.bidType,
        })
    end

    -- pass 列表
    local passedList = {}
    for _, bid in ipairs(passPlayers) do
        table.insert(passedList, bid.playerName)
    end

    -- 并列信息
    local histTied = nil
    if tiedBidders then
        histTied = {}
        for _, bid in ipairs(tiedBidders) do
            table.insert(histTied, { name = bid.charName, playerName = bid.playerName })
        end
    end

    -- 获胜者职业
    local winnerClass = winner and winner.charClass or nil

    local historyEntry = {
        id = chatAuction.id,
        itemLink = chatAuction.itemLink,
        itemData = chatAuction.itemData,  -- 掉落列表物品引用，供确认扣分时直接更新
        state = tiedBidders and "TIE" or (winner and "CHAT_PENDING" or "ENDED"),
        winner = winner and winner.playerName or nil,
        winnerChar = winner and winner.charName or nil,
        winnerClass = winnerClass,
        finalBid = finalBid,
        startBid = 0,
        bidCount = #activeBids,
        bids = historyBids,
        tiedBidders = histTied,
        passedPlayers = passedList,
        timestamp = time(),
        officer = DKP.playerName,
        encounterID = chatAuction.encounterID,
        encounterName = chatAuction.encounterName,
        instanceName = chatAuction.instanceName,
        isChatAuction = true,
    }

    table.insert(DKP.db.auctionHistory, historyEntry)
    DKP.hasUnsavedChanges = true

    -- 同步团队引用
    local team = DKP.GetCurrentTeam and DKP.GetCurrentTeam()
    if team then team.auctionHistory = DKP.db.auctionHistory end

    -- 团队通知
    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    if channel then
        local resultMsg = "[竞拍结束] " .. (chatAuction.itemLink or "物品")
        if tiedBidders then
            local names = {}
            for _, b in ipairs(tiedBidders) do table.insert(names, b.charName) end
            resultMsg = resultMsg .. " 并列: " .. table.concat(names, " vs ") .. " @ " .. finalBid .. " DKP -> 需人工处理"
        elseif winner then
            resultMsg = resultMsg .. " -> " .. winner.charName .. " (" .. finalBid .. " DKP) [待确认]"
        else
            resultMsg = resultMsg .. " (无人出价)"
        end
        SendChatMessage(resultMsg, channel)
    end

    -- 广播结束信号 + 历史记录给其他管理员
    SendChatAucMsg(table.concat({"CHAT_END", chatAuction.id}, MSG_SEP))
    if DKP.BroadcastHistoryEntry then
        DKP.BroadcastHistoryEntry(historyEntry)
    end

    DKP.Print("聊天竞拍结束: " .. (chatAuction.itemLink or ""))

    -- 保存结果供面板显示
    chatAuction.result = {
        activeBids = activeBids,
        passPlayers = passPlayers,
        winner = winner,
        tiedBidders = tiedBidders,
        finalBid = finalBid,
    }
    chatAuction.historyEntry = historyEntry

    DKP.RefreshChatAuctionPanel()
    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
end

----------------------------------------------------------------------
-- 取消聊天竞拍
----------------------------------------------------------------------
function DKP.CancelChatAuction()
    if not chatAuction then return end
    local itemLink = chatAuction.itemLink
    -- 广播取消信号
    if not chatAuction.isRemote then
        SendChatAucMsg(table.concat({"CHAT_CANCEL", chatAuction.id}, MSG_SEP))
    end
    chatAuction = nil
    if panel then panel:Hide() end
    DKP.Print("聊天竞拍已取消: " .. (itemLink or ""))
end

----------------------------------------------------------------------
-- 隐藏面板（竞拍继续进行）
----------------------------------------------------------------------
local function HideChatAuctionPanel()
    if panel then panel:Hide() end
end

----------------------------------------------------------------------
-- 关闭面板（结束后）
----------------------------------------------------------------------
local function CloseChatAuctionPanel()
    chatAuction = nil
    HideChatAuctionPanel()
end

----------------------------------------------------------------------
-- 确认聊天竞拍扣分（从拍卖记录调用）
----------------------------------------------------------------------
function DKP.ConfirmChatAuctionEntry(entry)
    if not CanManageChatAuction() then
        DKP.Print("只有管理员可确认聊天竞拍扣分")
        return
    end
    local liveEntry = entry and (FindAuctionHistoryEntryByID(entry.id) or entry) or nil
    if not liveEntry or liveEntry.state ~= "CHAT_PENDING" then return end
    if liveEntry.confirming then return end
    if not liveEntry.winner or not liveEntry.finalBid or liveEntry.finalBid <= 0 then
        DKP.Print("无法确认: 没有获胜者或出价为0")
        return
    end
    liveEntry.confirming = true

    -- 校验获胜者是否在DKP系统中
    local playerData = DKP.db and DKP.db.players[liveEntry.winner]
    if not playerData then
        liveEntry.confirming = nil
        DKP.Print("|cffFF0000无法确认: 玩家 " .. liveEntry.winner .. " 不在DKP名单中|r")
        return
    end

    -- 拒绝扣成负数
    local currentDKP = playerData.dkp or 0
    if liveEntry.finalBid > currentDKP then
        liveEntry.confirming = nil
        DKP.Print("|cffFF0000无法确认: " .. liveEntry.winner .. " 当前DKP=" .. currentDKP
            .. "，不足以扣除 " .. liveEntry.finalBid .. "|r")
        return
    end

    -- 扣除DKP
    local targetItem = FindLiveItemForChatAuctionEntry(liveEntry)
    if not targetItem then
        liveEntry.confirming = nil
        DKP.Print("|cffFF0000无法确认: 找不到对应掉落记录，已取消扣分以避免数据不一致|r")
        return
    end

    liveEntry.state = "ENDED"
    if entry and entry ~= liveEntry then
        entry.state = "ENDED"
    end
    DKP.hasUnsavedChanges = true
    if DKP.BroadcastHistoryEntry then DKP.BroadcastHistoryEntry(liveEntry) end

    DKP.AdjustDKP(liveEntry.winner, -liveEntry.finalBid, "聊天竞拍: " .. (liveEntry.itemLink or "物品"))

    -- 始终更新当前 sheets 中的 live item，避免 history 里保存的旧引用失效。
    targetItem.winner = liveEntry.winnerChar or liveEntry.winner
    targetItem.winnerClass = liveEntry.winnerClass
    targetItem.dkp = liveEntry.finalBid
    liveEntry.itemData = targetItem
    if entry and entry ~= liveEntry then
        entry.itemData = targetItem
    end

    -- 广播 DKP 全量数据（与批量操作一致）
    if DKP.BroadcastDKPData then DKP.BroadcastDKPData() end
    if DKP.BroadcastSheets then DKP.BroadcastSheets() end
    liveEntry.confirming = nil

    DKP.Print("竞拍已确认: " .. (liveEntry.winnerChar or liveEntry.winner) ..
        " 获得 " .. (liveEntry.itemLink or "物品") .. " (" .. liveEntry.finalBid .. " DKP)")

    if DKP.RefreshAuctionLogUI then DKP.RefreshAuctionLogUI() end
    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
end

----------------------------------------------------------------------
-- UI: 创建面板
----------------------------------------------------------------------
local function CreatePanel()
    local f = CreateFrame("Frame", "YTHTDKPChatAuctionPanel", UIParent, "BackdropTemplate")
    f:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 220, 80)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(160)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    f:SetBackdropBorderColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.8)
    f:Hide()

    -- 标题栏
    local titleBar = f:CreateTexture(nil, "ARTWORK")
    titleBar:SetPoint("TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", -4, -4)
    titleBar:SetHeight(24)
    titleBar:SetColorTexture(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b, 0.3)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    title:SetTextColor(TITLE_COLOR.r, TITLE_COLOR.g, TITLE_COLOR.b)
    f.titleText = title

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        if chatAuction and chatAuction.state == "collecting" then
            HideChatAuctionPanel()
        else
            CloseChatAuctionPanel()
        end
    end)

    -- 物品图标 + 名字
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("TOPLEFT", 12, -34)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.itemIcon = icon

    local itemText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    itemText:SetWidth(340)
    itemText:SetJustifyH("LEFT")
    itemText:SetWordWrap(false)
    f.itemText = itemText

    -- Tooltip
    icon:SetScript("OnEnter", function(self)
        if chatAuction and chatAuction.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(chatAuction.itemLink)
            GameTooltip:Show()
        end
    end)
    -- icon is a Texture, not a Frame, so we handle tooltip via the parent
    -- Actually Textures don't receive mouse events by default. Let's use a button overlay.
    local iconBtn = CreateFrame("Button", nil, f)
    iconBtn:SetAllPoints(icon)
    iconBtn:SetScript("OnEnter", function(self)
        if chatAuction and chatAuction.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(chatAuction.itemLink)
            GameTooltip:Show()
        end
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- 状态文字
    local statusText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", 12, -68)
    statusText:SetWidth(PANEL_WIDTH - 24)
    statusText:SetJustifyH("LEFT")
    f.statusText = statusText

    -- 并列警告
    local tieText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tieText:SetPoint("TOPLEFT", 12, -84)
    tieText:SetWidth(PANEL_WIDTH - 24)
    tieText:SetJustifyH("LEFT")
    tieText:SetTextColor(1, 0.3, 0.3)
    f.tieText = tieText

    -- DKP 余额显示
    local dkpBalanceText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dkpBalanceText:SetPoint("TOPLEFT", 12, -104)
    dkpBalanceText:SetWidth(PANEL_WIDTH - 24)
    dkpBalanceText:SetJustifyH("LEFT")
    dkpBalanceText:SetTextColor(0.8, 0.8, 0.8)
    f.dkpBalanceText = dkpBalanceText

    -- 竞价控件（所有插件用户可用）
    local bidAmountBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    bidAmountBox:SetSize(50, 22)
    bidAmountBox:SetPoint("TOPLEFT", 12, -120)
    bidAmountBox:SetAutoFocus(false)
    bidAmountBox:SetNumeric(true)
    f.bidAmountBox = bidAmountBox

    local bidSubmitBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    bidSubmitBtn:SetSize(42, 22)
    bidSubmitBtn:SetPoint("LEFT", bidAmountBox, "RIGHT", 4, 0)
    bidSubmitBtn:SetText("出价")
    bidSubmitBtn:SetScript("OnClick", function()
        local ch = GetChatChannel()
        if not ch then return end
        local text = bidAmountBox:GetText()
        if text and text ~= "" and tonumber(text) then
            RecordChatAuctionBid(GetLocalFullPlayerName(), text, time(), true)
            SendChatMessage(text, ch)
        end
    end)
    f.bidSubmitBtn = bidSubmitBtn

    local bidPlus1Btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    bidPlus1Btn:SetSize(28, 22)
    bidPlus1Btn:SetPoint("LEFT", bidSubmitBtn, "RIGHT", 4, 0)
    bidPlus1Btn:SetText("+1")
    bidPlus1Btn:SetScript("OnClick", function()
        local ch = GetChatChannel()
        if not ch then return end
        local bidText = tostring(GetCurrentHighestBid() + 1)
        RecordChatAuctionBid(GetLocalFullPlayerName(), bidText, time(), true)
        SendChatMessage(bidText, ch)
    end)
    f.bidPlus1Btn = bidPlus1Btn

    local bidPlus5Btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    bidPlus5Btn:SetSize(28, 22)
    bidPlus5Btn:SetPoint("LEFT", bidPlus1Btn, "RIGHT", 2, 0)
    bidPlus5Btn:SetText("+5")
    bidPlus5Btn:SetScript("OnClick", function()
        local ch = GetChatChannel()
        if not ch then return end
        local bidText = tostring(GetCurrentHighestBid() + 5)
        RecordChatAuctionBid(GetLocalFullPlayerName(), bidText, time(), true)
        SendChatMessage(bidText, ch)
    end)
    f.bidPlus5Btn = bidPlus5Btn

    local bidAllInBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    bidAllInBtn:SetSize(30, 22)
    bidAllInBtn:SetPoint("LEFT", bidPlus5Btn, "RIGHT", 4, 0)
    bidAllInBtn:SetText("SH")
    bidAllInBtn:SetScript("OnClick", function()
        local ch = GetChatChannel()
        if not ch then return end
        RecordChatAuctionBid(GetLocalFullPlayerName(), "sh", time(), true)
        SendChatMessage("sh", ch)
    end)
    f.bidAllInBtn = bidAllInBtn

    local bidPassBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    bidPassBtn:SetSize(36, 22)
    bidPassBtn:SetPoint("LEFT", bidAllInBtn, "RIGHT", 4, 0)
    bidPassBtn:SetText("Pass")
    bidPassBtn:SetScript("OnClick", function()
        local ch = GetChatChannel()
        if not ch then return end
        RecordChatAuctionBid(GetLocalFullPlayerName(), "p", time(), true)
        SendChatMessage("p", ch)
    end)
    f.bidPassBtn = bidPassBtn

    -- Enter 键提交出价
    bidAmountBox:SetScript("OnEnterPressed", function(self)
        local ch = GetChatChannel()
        if not ch then return end
        local text = self:GetText()
        if text and text ~= "" and tonumber(text) then
            RecordChatAuctionBid(GetLocalFullPlayerName(), text, time(), true)
            SendChatMessage(text, ch)
        end
        self:ClearFocus()
    end)

    -- 竞价列表 滚动区
    local scrollFrame = CreateFrame("ScrollFrame", "YTHTDKPChatAucScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -148)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 40)

    local scrollChild = CreateFrame("Frame", "YTHTDKPChatAucScrollChild", scrollFrame)
    scrollChild:SetWidth(scrollFrame:GetWidth())
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)
    f.scrollChild = scrollChild

    -- 底部按钮
    local endBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    endBtn:SetSize(80, 24)
    endBtn:SetPoint("BOTTOMLEFT", 12, 10)
    endBtn:SetText("结束竞拍")
    endBtn:SetScript("OnClick", function() DKP.EndChatAuction() end)
    f.endBtn = endBtn

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(60, 24)
    cancelBtn:SetPoint("LEFT", endBtn, "RIGHT", 8, 0)
    cancelBtn:SetText("取消")
    cancelBtn:SetScript("OnClick", function() DKP.CancelChatAuction() end)
    f.cancelBtn = cancelBtn

    local closeResultBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeResultBtn:SetSize(60, 24)
    closeResultBtn:SetPoint("BOTTOMRIGHT", -12, 10)
    closeResultBtn:SetText("关闭")
    closeResultBtn:SetScript("OnClick", function() CloseChatAuctionPanel() end)
    closeResultBtn:Hide()
    f.closeResultBtn = closeResultBtn

    -- 确认扣分按钮（竞拍结束后、有获胜者时显示）
    local confirmBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    confirmBtn:SetSize(100, 24)
    confirmBtn:SetPoint("BOTTOMLEFT", 12, 10)
    confirmBtn:SetText("确认扣分")
    confirmBtn:Hide()
    f.confirmBtn = confirmBtn

    panel = f
    return f
end

----------------------------------------------------------------------
-- 显示面板
----------------------------------------------------------------------
function DKP.ShowChatAuctionPanel()
    if not panel then CreatePanel() end
    DKP.RefreshChatAuctionPanel()
    panel:Show()
end

----------------------------------------------------------------------
-- 刷新面板内容
----------------------------------------------------------------------
function DKP.RefreshChatAuctionPanel()
    if not panel or not chatAuction then return end
    local f = panel

    -- 标题
    if chatAuction.state == "collecting" then
        f.titleText:SetText("聊天竞拍")
    else
        f.titleText:SetText("竞拍结束")
    end

    -- 物品
    if chatAuction.itemLink then
        local _, _, _, _, iconTex = C_Item.GetItemInfoInstant(chatAuction.itemLink)
        f.itemIcon:SetTexture(iconTex)
        local itemName, _, quality = C_Item.GetItemInfo(chatAuction.itemLink)
        if itemName then
            local c = DKP.GetQualityColor(quality)
            f.itemText:SetTextColor(c.r, c.g, c.b)
            f.itemText:SetText(itemName)
        else
            f.itemText:SetText(chatAuction.itemLink)
            f.itemText:SetTextColor(1, 1, 1)
        end
    end

    -- 计算结果
    local activeBids, passPlayers, winner, tiedBidders, finalBid = ComputeResult()
    if chatAuction.state ~= "collecting" and chatAuction.historyEntry then
        activeBids, passPlayers, winner, tiedBidders, finalBid =
            BuildDisplayResultFromHistoryEntry(chatAuction.historyEntry)
    end

    -- 状态
    local bidCount = #activeBids
    local passCount = #passPlayers
    if chatAuction.state == "collecting" then
        f.statusText:SetText("|cff00FF00竞价中...|r  出价: " .. bidCount .. " 人  pass: " .. passCount .. " 人")
        f.statusText:SetTextColor(0.8, 0.8, 0.8)
    else
        if winner then
            f.statusText:SetText("最高出价: " .. DKP.ClassColorText(winner.charName, winner.charClass) ..
                "  |cffFFD700" .. finalBid .. "|r DKP" ..
                (winner.isAllIn and " |cffFF8800[sh]|r" or ""))
        elseif bidCount == 0 then
            f.statusText:SetText("|cff888888无人出价|r")
        else
            f.statusText:SetText("出价: " .. bidCount .. " 人")
        end
        f.statusText:SetTextColor(0.8, 0.8, 0.8)
    end

    -- 并列警告
    if tiedBidders and #tiedBidders >= 2 then
        local names = {}
        for _, b in ipairs(tiedBidders) do
            table.insert(names, DKP.ClassColorText(b.charName, b.charClass))
        end
        f.tieText:SetText("!! 并列: " .. table.concat(names, " vs ") .. "  @ |cffFFD700" .. finalBid .. "|r DKP")
        f.tieText:Show()
    else
        f.tieText:SetText("")
        f.tieText:Hide()
    end

    -- DKP 余额
    local myPlayer = DKP.GetPlayerByCharacter and DKP.GetPlayerByCharacter(DKP.playerName) or DKP.playerName
    local myDKP = 0
    if DKP.db and DKP.db.players[myPlayer] then
        myDKP = DKP.db.players[myPlayer].dkp or 0
    end
    f.dkpBalanceText:SetText("DKP余额: |cffFFD700" .. myDKP .. "|r")

    -- 竞价控件：竞价中显示，结束后隐藏
    local showBidControls = (chatAuction.state == "collecting")
    f.dkpBalanceText:SetShown(showBidControls)
    f.bidAmountBox:SetShown(showBidControls)
    f.bidSubmitBtn:SetShown(showBidControls)
    f.bidPlus1Btn:SetShown(showBidControls)
    f.bidPlus5Btn:SetShown(showBidControls)
    f.bidAllInBtn:SetShown(showBidControls)
    f.bidPassBtn:SetShown(showBidControls)

    -- 自动填充下一个出价（用户没在输入时）
    if showBidControls and not f.bidAmountBox:HasFocus() then
        local nextBid = GetCurrentHighestBid() + 1
        f.bidAmountBox:SetText(tostring(nextBid))
    end

    -- 按钮状态
    f.endBtn:Hide()
    f.cancelBtn:Hide()
    f.closeResultBtn:Hide()
    f.confirmBtn:Hide()

    if chatAuction.state == "collecting" and not chatAuction.isRemote then
        f.endBtn:Show()
        f.cancelBtn:Show()
    elseif chatAuction.state == "collecting" and chatAuction.isRemote then
        f.closeResultBtn:Show()
    else
        -- 竞拍已结束
        f.closeResultBtn:Show()
        -- 有获胜者且待确认 → 显示确认扣分
        if CanManageChatAuction()
           and winner and chatAuction.historyEntry
           and chatAuction.historyEntry.state == "CHAT_PENDING" then
            f.confirmBtn:SetText("确认扣分 (" .. winner.charName .. " -" .. finalBid .. ")")
            f.confirmBtn:SetScript("OnClick", function()
                if DKP.ConfirmChatAuctionEntry then
                    DKP.ConfirmChatAuctionEntry(chatAuction.historyEntry)
                    DKP.RefreshChatAuctionPanel()
                end
            end)
            f.confirmBtn:Show()
        end
    end

    -- 竞价列表
    local scrollChild = f.scrollChild
    -- 隐藏旧内容
    for _, fs in ipairs(bidFontStrings) do
        fs:SetText("")
        fs:Hide()
    end

    local fontIdx = 0
    local function GetFS(template)
        fontIdx = fontIdx + 1
        local fs = bidFontStrings[fontIdx]
        if not fs then
            fs = scrollChild:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
            bidFontStrings[fontIdx] = fs
        else
            fs:SetFontObject(template or "GameFontNormalSmall")
        end
        fs:ClearAllPoints()
        fs:SetWidth(scrollChild:GetWidth() - 8)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:Show()
        return fs
    end

    local yOffset = 0

    -- 表头
    local header = GetFS("GameFontNormalSmall")
    header:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yOffset)
    header:SetText("|cff888888#    玩家                  出价          原始消息|r")
    yOffset = yOffset - ROW_HEIGHT

    -- 分隔线
    local sep = GetFS("GameFontNormalSmall")
    sep:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yOffset)
    sep:SetText("|cff444444" .. string.rep("-", 60) .. "|r")
    yOffset = yOffset - ROW_HEIGHT

    -- 活跃出价
    for i, bid in ipairs(activeBids) do
        local fs = GetFS("GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yOffset)

        local idx = tostring(i) .. "."
        local name = DKP.ClassColorText(bid.charName, bid.charClass)
        local amountStr = "|cffFFD700" .. bid.amount .. "|r DKP"
        local allInTag = bid.isAllIn and " |cffFF8800[sh=" .. bid.amount .. "]|r" or ""
        local rawStr = bid.rawMessage and ("|cff666666\"" .. bid.rawMessage .. "\"|r") or ""
        local notInSystem = (not bid.inDKPSystem) and " |cffFF0000[未注册]|r" or ""

        -- 高亮并列
        local tieTag = ""
        if tiedBidders then
            for _, tb in ipairs(tiedBidders) do
                if tb.playerName == bid.playerName then
                    tieTag = " |cffFF4444[并列]|r"
                    break
                end
            end
        end

        local detailText = idx .. "  " .. name .. "  " .. amountStr .. allInTag .. tieTag .. notInSystem
        if rawStr ~= "" then
            detailText = detailText .. "  " .. rawStr
        end
        fs:SetText(detailText)
        fs:SetTextColor(0.9, 0.9, 0.9)
        yOffset = yOffset - ROW_HEIGHT
    end

    -- pass 区
    if #passPlayers > 0 then
        local passSep = GetFS("GameFontNormalSmall")
        passSep:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yOffset)
        passSep:SetText("|cff888888---- pass ----|r")
        yOffset = yOffset - ROW_HEIGHT

        for _, bid in ipairs(passPlayers) do
            local fs = GetFS("GameFontNormalSmall")
            fs:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yOffset)
            local name = DKP.ClassColorText(bid.charName, bid.charClass)
            local passText = "    " .. name .. "  |cff888888pass|r"
            if bid.rawMessage and bid.rawMessage ~= "" then
                passText = passText .. "  |cff666666\"" .. bid.rawMessage .. "\"|r"
            end
            fs:SetText(passText)
            yOffset = yOffset - ROW_HEIGHT
        end
    end

    -- 无竞价提示
    if #activeBids == 0 and #passPlayers == 0 then
        local empty = GetFS("GameFontNormal")
        empty:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yOffset)
        empty:SetText("|cff555555等待竞价...|r")
        yOffset = yOffset - ROW_HEIGHT
    end

    -- 结束后的提示
    if chatAuction.state == "ended" then
        yOffset = yOffset - 8
        local hint = GetFS("GameFontNormalSmall")
        hint:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yOffset)
        if CanManageChatAuction() then
            hint:SetText("|cffFFCC00已保存到拍卖记录，请在拍卖记录中确认扣分|r")
        else
            hint:SetText("|cffFFCC00已保存到拍卖记录，等待管理员确认扣分|r")
        end
        yOffset = yOffset - ROW_HEIGHT
    end

    scrollChild:SetHeight(math.abs(yOffset) + 10)
end

----------------------------------------------------------------------
-- 接收其他管理员的聊天竞拍信号
----------------------------------------------------------------------
local syncFrame = CreateFrame("Frame")
syncFrame:RegisterEvent("CHAT_MSG_ADDON")

syncFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if prefix ~= DKP.AUCTION_PREFIX then return end

    local senderShort = sender:match("^([^%-]+)") or sender
    if senderShort == DKP.playerName then return end

    local parts = { strsplit(MSG_SEP, msg) }
    local msgType = parts[1]

    if msgType == "CHAT_START" then
        if chatAuction then return end
        local id = parts[2]
        local itemLink = parts[3]
        local encounterID = tonumber(parts[4])
        local encounterName = parts[5]
        local instanceName = parts[6]
        if encounterName == "" then encounterName = nil end
        if instanceName == "" then instanceName = nil end

        chatAucCounter = chatAucCounter + 1
        chatAuction = {
            id = id,
            itemLink = itemLink,
            itemData = nil,
            bossData = nil,
            encounterID = encounterID,
            encounterName = encounterName,
            instanceName = instanceName,
            bids = {},
            startTime = time(),
            state = "collecting",
            isRemote = true,
            starter = senderShort,
        }
        DKP.Print(senderShort .. " 发起了聊天竞拍: " .. (itemLink or ""))
        DKP.ShowChatAuctionPanel()

    elseif msgType == "CHAT_END" then
        if chatAuction and chatAuction.isRemote then
            chatAuction.state = "ended"
            -- 本地也计算结果用于面板展示（历史记录由 BroadcastHistoryEntry 同步）
            local activeBids, passPlayers, winner, tiedBidders, finalBid = ComputeResult()
            chatAuction.result = {
                activeBids = activeBids,
                passPlayers = passPlayers,
                winner = winner,
                tiedBidders = tiedBidders,
                finalBid = finalBid,
            }
            -- 延迟查找拍卖记录（等 BroadcastHistoryEntry 同步到达）
            C_Timer.After(3, function()
                if chatAuction and chatAuction.id then
                    for _, entry in ipairs(DKP.db.auctionHistory or {}) do
                        if entry.id == chatAuction.id then
                            chatAuction.historyEntry = entry
                            break
                        end
                    end
                    DKP.RefreshChatAuctionPanel()
                end
            end)
            DKP.RefreshChatAuctionPanel()
            DKP.Print("聊天竞拍已结束 (由 " .. senderShort .. ")")
        end

    elseif msgType == "CHAT_CANCEL" then
        if chatAuction and chatAuction.isRemote then
            chatAuction = nil
            if panel then panel:Hide() end
            DKP.Print("聊天竞拍已被 " .. senderShort .. " 取消")
        end
    end
end)
