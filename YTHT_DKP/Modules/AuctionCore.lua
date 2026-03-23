----------------------------------------------------------------------
-- YTHT DKP - Auction Core
--
-- 多拍卖状态机、通信协议、计时器
-- 支持多件装备同时拍卖，玩家各拍卖领先出价之和不得超过DKP余额
-- 支持梭哈平局、提前结束、防重复拍卖
----------------------------------------------------------------------

local DKP = YTHT_DKP

local MSG_SEP = "\t"

-- 拍卖状态
DKP.AUCTION_STATE = {
    ACTIVE = "ACTIVE",
    ENDED = "ENDED",
    CANCELLED = "CANCELLED",
}

-- 活跃拍卖表 id -> auction
DKP.activeAuctions = {}

-- 拍卖ID计数器
local auctionCounter = 0

----------------------------------------------------------------------
-- DKP 可用余额：总余额减去所有活跃拍卖中的领先出价
----------------------------------------------------------------------
function DKP.GetAvailableDKP(playerName)
    local player = DKP.db and DKP.db.players[playerName]
    if not player then return 0 end
    local total = player.dkp or 0
    for _, auction in pairs(DKP.activeAuctions) do
        if auction.state == DKP.AUCTION_STATE.ACTIVE and auction.currentBidderPlayer == playerName then
            total = total - auction.currentBid
        end
    end
    return total
end

-- 获取当前玩家的DKP玩家名
local function GetMyPlayerName()
    local myName = DKP.playerName
    local playerName = DKP.GetPlayerByCharacter and DKP.GetPlayerByCharacter(myName)
    return playerName or myName
end

----------------------------------------------------------------------
-- 深拷贝 bids 用于历史记录
----------------------------------------------------------------------
local function CopyBidsForHistory(bids)
    local copy = {}
    for _, bid in ipairs(bids) do
        table.insert(copy, {
            bidder = bid.bidder,
            bidderPlayer = bid.bidderPlayer,
            amount = bid.amount,
            timestamp = bid.wallTime or time(),
            isAllIn = bid.isAllIn or false,
        })
    end
    return copy
end

----------------------------------------------------------------------
-- 发送拍卖消息
----------------------------------------------------------------------
local function SendAuctionMsg(msg)
    if IsInRaid() then
        C_ChatInfo.SendAddonMessage(DKP.AUCTION_PREFIX, msg, "RAID")
    elseif IsInGroup() then
        C_ChatInfo.SendAddonMessage(DKP.AUCTION_PREFIX, msg, "PARTY")
    end
end

local function SendAuctionWhisper(msg, target)
    C_ChatInfo.SendAddonMessage(DKP.AUCTION_PREFIX, msg, "WHISPER", target)
end

----------------------------------------------------------------------
-- 发起拍卖（管理员）
----------------------------------------------------------------------
function DKP.StartAuction(itemLink, startBid, duration, encounterInfo)
    if not DKP.IsOfficer() then
        DKP.Print("只有管理员可以发起拍卖")
        return false
    end

    startBid = startBid or DKP.db.options.defaultStartingBid or 10
    duration = duration or DKP.db.options.auctionDuration or 30

    -- 防重复：检查 itemData 的 activeAuctionID
    if encounterInfo and encounterInfo.itemData and encounterInfo.itemData.activeAuctionID then
        local existingAuction = DKP.activeAuctions[encounterInfo.itemData.activeAuctionID]
        if existingAuction and existingAuction.state == DKP.AUCTION_STATE.ACTIVE then
            DKP.Print("该物品已在拍卖中")
            return false
        end
    end

    auctionCounter = auctionCounter + 1
    local id = "auc_" .. time() .. "_" .. auctionCounter

    local auction = {
        id = id,
        itemLink = itemLink,
        startBid = startBid,
        currentBid = 0,
        currentBidder = nil,
        currentBidderPlayer = nil,
        currentBidIsAllIn = false,
        duration = duration,
        startTime = GetTime(),
        endTime = GetTime() + duration,
        state = DKP.AUCTION_STATE.ACTIVE,
        bids = {},
        tiedBidders = nil,
        officer = DKP.playerName,
        officerFullName = DKP.playerFullName or (DKP.playerName .. "-" .. GetRealmName()),
        -- encounter 信息
        encounterID = encounterInfo and encounterInfo.encounterID or nil,
        encounterName = encounterInfo and encounterInfo.encounterName or nil,
        instanceName = encounterInfo and encounterInfo.instanceName or nil,
        itemData = encounterInfo and encounterInfo.itemData or nil,
    }

    DKP.activeAuctions[id] = auction

    -- 防重复：标记 itemData
    if auction.itemData then
        auction.itemData.activeAuctionID = id
    end

    -- 广播 START (含 officerFullName 用于 WHISPER 出价)
    local myFullName = DKP.playerFullName or (DKP.playerName .. "-" .. GetRealmName())
    local msg = table.concat({
        "START", id, itemLink, tostring(startBid), tostring(duration), DKP.playerName, myFullName
    }, MSG_SEP)
    SendAuctionMsg(msg)

    -- RAID 聊天通知
    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    if channel then
        SendChatMessage(
            "[YTHT-DKP] 拍卖开始: " .. itemLink .. " | 起拍: " .. startBid .. " DKP | 时长: " .. duration .. "秒",
            channel
        )
    end

    DKP.Print("拍卖发起: " .. itemLink .. " 起拍 " .. startBid .. " DKP")

    -- 更新UI（延迟0.1秒确保 AuctionStart 对话框已关闭）
    C_Timer.After(0.1, function()
        if DKP.RefreshTableUI then DKP.RefreshTableUI() end
        if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
        if DKP.ShowAuctionUI then DKP.ShowAuctionUI() end
    end)

    return true
end

----------------------------------------------------------------------
-- 竞价（任何玩家）
----------------------------------------------------------------------
function DKP.PlaceBid(auctionID, amount, isAllIn)
    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then
        DKP.Print("该拍卖已结束或不存在")
        return false
    end

    amount = tonumber(amount)
    if not amount then return false end

    local minIncrement = DKP.db.options.minBidIncrement or 1
    local minBid = auction.currentBid > 0 and (auction.currentBid + minIncrement) or auction.startBid

    -- 梭哈同分允许: 当双方都梭哈且金额相同时允许
    local isTieAllowed = isAllIn and auction.currentBidIsAllIn and amount == auction.currentBid and auction.currentBid > 0

    if amount < minBid and not isTieAllowed then
        DKP.Print("出价必须 >= " .. minBid)
        return false
    end

    -- 检查可用余额
    local myPlayerName = GetMyPlayerName()
    if not DKP.db.players[myPlayerName] then
        DKP.Print("你不在DKP名单中，无法出价 (角色: " .. (DKP.playerName or "?") .. ")")
        return false
    end
    local available = DKP.GetAvailableDKP(myPlayerName)
    -- 如果我已经是这个拍卖的领先者，可用余额要加回当前出价
    if auction.currentBidderPlayer == myPlayerName then
        available = available + auction.currentBid
    end
    if amount > available then
        DKP.Print("DKP余额不足！可用: " .. available)
        return false
    end

    -- 如果自己是管理员（本地也是竞拍者），直接处理，不发 WHISPER
    if DKP.IsOfficer() and auction.officer == DKP.playerName then
        DKP.ProcessBid(DKP.playerName, auctionID, amount, isAllIn)
    elseif auction.officer then
        -- 非管理员：发 BID WHISPER 到管理员
        local officerFull = auction.officerFullName or auction.officer
        if not officerFull:find("-") then
            officerFull = officerFull .. "-" .. GetRealmName()
        end
        local msg = table.concat({ "BID", auctionID, tostring(amount), isAllIn and "1" or "0" }, MSG_SEP)
        SendAuctionWhisper(msg, officerFull)
    end

    return true
end

----------------------------------------------------------------------
-- 处理出价（管理员端）
----------------------------------------------------------------------
function DKP.ProcessBid(senderChar, auctionID, amount, isAllIn)
    if not DKP.IsOfficer() then return end

    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then return end

    amount = tonumber(amount)
    if not amount then return end

    local minIncrement = DKP.db.options.minBidIncrement or 1
    local minBid = auction.currentBid > 0 and (auction.currentBid + minIncrement) or auction.startBid

    -- 查找出价者的 DKP 玩家名
    local shortName = senderChar:match("^([^%-]+)") or senderChar
    local bidderPlayer = DKP.GetPlayerByCharacter(senderChar) or DKP.GetPlayerByCharacter(shortName) or shortName

    -- 梭哈同分处理
    local isTieBid = isAllIn and auction.currentBidIsAllIn and amount == auction.currentBid and auction.currentBid > 0
    -- 不能和自己平局
    if isTieBid and auction.currentBidderPlayer == bidderPlayer then
        isTieBid = false
    end

    if amount < minBid and not isTieBid then return end

    -- 验证余额
    local available = DKP.GetAvailableDKP(bidderPlayer)
    if auction.currentBidderPlayer == bidderPlayer then
        available = available + auction.currentBid
    end
    if amount > available then return end

    if isTieBid then
        -- 梭哈同分 → 平局
        if not auction.tiedBidders then
            -- 初始化：包含当前领先者
            auction.tiedBidders = {
                { name = auction.currentBidder, playerName = auction.currentBidderPlayer },
            }
        end
        -- 检查是否已在平局列表中
        local alreadyTied = false
        for _, tb in ipairs(auction.tiedBidders) do
            if tb.playerName == bidderPlayer then
                alreadyTied = true
                break
            end
        end
        if not alreadyTied then
            table.insert(auction.tiedBidders, { name = shortName, playerName = bidderPlayer })
        end

        -- 记录 bid
        table.insert(auction.bids, {
            bidder = shortName,
            bidderPlayer = bidderPlayer,
            amount = amount,
            timestamp = GetTime(),
            wallTime = time(),
            isAllIn = true,
        })

        -- 广播 TIE_UPDATE
        local names = {}
        for _, tb in ipairs(auction.tiedBidders) do
            table.insert(names, tb.name)
        end
        local msg = table.concat({
            "TIE_UPDATE", auctionID, tostring(amount), table.concat(names, ";")
        }, MSG_SEP)
        SendAuctionMsg(msg)

        if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
        return
    end

    -- 正常出价（高于当前价）
    auction.currentBid = amount
    auction.currentBidder = shortName
    auction.currentBidderPlayer = bidderPlayer
    auction.currentBidIsAllIn = isAllIn and true or false
    auction.tiedBidders = nil  -- 清除平局状态

    table.insert(auction.bids, {
        bidder = shortName,
        bidderPlayer = bidderPlayer,
        amount = amount,
        timestamp = GetTime(),
        wallTime = time(),
        isAllIn = isAllIn and true or false,
    })

    -- 延长计时（最后N秒出价自动延长）
    local extendTime = DKP.db.options.auctionExtendTime or 10
    local remaining = auction.endTime - GetTime()
    if remaining < extendTime then
        auction.endTime = GetTime() + extendTime
    end

    -- 广播 UPDATE
    local msg = table.concat({
        "UPDATE", auctionID, tostring(amount), shortName, isAllIn and "1" or "0"
    }, MSG_SEP)
    SendAuctionMsg(msg)

    -- 更新UI
    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
end

----------------------------------------------------------------------
-- 结束拍卖（管理员端，计时到期或提前结束时调用）
----------------------------------------------------------------------
function DKP.EndAuction(auctionID)
    if not DKP.IsOfficer() then return end

    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then return end

    auction.state = DKP.AUCTION_STATE.ENDED

    -- 查找获胜者职业的辅助函数
    local function GetWinnerClass(winnerPlayer, winnerChar)
        local winnerClass = "WARRIOR"
        local playerData = DKP.db.players[winnerPlayer]
        if playerData then
            for _, char in ipairs(playerData.characters or {}) do
                if char.name == winnerChar then
                    winnerClass = char.class
                    break
                end
            end
        end
        return winnerClass
    end

    -- 梭哈平局处理
    if auction.tiedBidders and #auction.tiedBidders >= 2 then
        -- 不扣DKP，记录为平局
        local historyEntry = {
            id = auction.id,
            itemLink = auction.itemLink,
            state = "TIE",
            winner = nil,
            winnerChar = nil,
            winnerClass = nil,
            finalBid = auction.currentBid,
            startBid = auction.startBid,
            bidCount = #auction.bids,
            bids = CopyBidsForHistory(auction.bids),
            tiedBidders = {},
            timestamp = time(),
            officer = auction.officer,
            encounterID = auction.encounterID,
            encounterName = auction.encounterName,
            instanceName = auction.instanceName,
        }
        for _, tb in ipairs(auction.tiedBidders) do
            table.insert(historyEntry.tiedBidders, { name = tb.name, playerName = tb.playerName })
        end
        table.insert(DKP.db.auctionHistory, historyEntry)

        -- 更新 loot table itemData
        if auction.itemData then
            auction.itemData.winner = "转人工"
            auction.itemData.tiedBidders = auction.tiedBidders
            auction.itemData.tiedAmount = auction.currentBid
            auction.itemData.activeAuctionID = nil
        end

        DKP.hasUnsavedChanges = true

        -- 广播 END with TIE
        local msg = table.concat({ "END", auctionID, "TIE", tostring(auction.currentBid) }, MSG_SEP)
        SendAuctionMsg(msg)

        -- RAID 通知
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if channel then
            local names = {}
            for _, tb in ipairs(auction.tiedBidders) do
                table.insert(names, tb.name)
            end
            SendChatMessage(
                "[YTHT-DKP] 拍卖平局: " .. (auction.itemLink or "物品") ..
                " | " .. table.concat(names, " vs ") .. " @ " .. auction.currentBid .. " DKP → 转人工处理",
                channel
            )
        end

        DKP.Print(auction.itemLink .. " sh平局! 转人工处理")

        -- 广播历史记录
        if DKP.BroadcastHistoryEntry then
            DKP.BroadcastHistoryEntry(historyEntry)
        end

        DKP.activeAuctions[auctionID] = nil
        if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
        if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
        if DKP.RefreshTableUI then DKP.RefreshTableUI() end
        if DKP.BroadcastSheets then DKP.BroadcastSheets() end
        return
    end

    local winner = auction.currentBidder
    local winnerPlayer = auction.currentBidderPlayer
    local finalBid = auction.currentBid

    if winner and finalBid > 0 then
        -- 扣除DKP
        DKP.AdjustDKP(winnerPlayer, -finalBid, "拍卖: " .. (auction.itemLink or "物品"))

        -- 广播DKP变动
        local playerData = DKP.db.players[winnerPlayer]
        if playerData and DKP.BroadcastDKPChange then
            DKP.BroadcastDKPChange(winnerPlayer, playerData.dkp, -finalBid,
                "拍卖: " .. (auction.itemLink or "物品"), time(), DKP.playerName)
        end

        local winnerClass = GetWinnerClass(winnerPlayer, winner)

        -- 更新 loot table itemData
        if auction.itemData then
            auction.itemData.winner = winner
            auction.itemData.winnerClass = winnerClass
            auction.itemData.dkp = finalBid
            auction.itemData.activeAuctionID = nil
        end

        -- 记录拍卖历史
        local historyEntry = {
            id = auction.id,
            itemLink = auction.itemLink,
            state = "ENDED",
            winner = winnerPlayer,
            winnerChar = winner,
            winnerClass = winnerClass,
            finalBid = finalBid,
            startBid = auction.startBid,
            bidCount = #auction.bids,
            bids = CopyBidsForHistory(auction.bids),
            timestamp = time(),
            officer = auction.officer,
            encounterID = auction.encounterID,
            encounterName = auction.encounterName,
            instanceName = auction.instanceName,
        }
        table.insert(DKP.db.auctionHistory, historyEntry)

        DKP.hasUnsavedChanges = true

        -- 广播 END
        local msg = table.concat({ "END", auctionID, winner, tostring(finalBid) }, MSG_SEP)
        SendAuctionMsg(msg)

        -- RAID 通知
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if channel then
            SendChatMessage(
                "[YTHT-DKP] 拍卖结束: " .. (auction.itemLink or "物品") ..
                " -> " .. winner .. " (" .. finalBid .. " DKP)",
                channel
            )
        end

        DKP.Print(auction.itemLink .. " 拍卖结束: " .. winner .. " 以 " .. finalBid .. " DKP 获得")

        -- 广播历史记录
        if DKP.BroadcastHistoryEntry then
            DKP.BroadcastHistoryEntry(historyEntry)
        end
    else
        -- 无人出价
        -- 清除 itemData 的 activeAuctionID
        if auction.itemData then
            auction.itemData.activeAuctionID = nil
        end

        local historyEntry = {
            id = auction.id,
            itemLink = auction.itemLink,
            state = "ENDED",
            winner = nil,
            winnerChar = nil,
            winnerClass = nil,
            finalBid = 0,
            startBid = auction.startBid,
            bidCount = 0,
            bids = {},
            timestamp = time(),
            officer = auction.officer,
            encounterID = auction.encounterID,
            encounterName = auction.encounterName,
            instanceName = auction.instanceName,
        }
        table.insert(DKP.db.auctionHistory, historyEntry)

        local msg = table.concat({ "END", auctionID, "", "0" }, MSG_SEP)
        SendAuctionMsg(msg)

        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if channel then
            SendChatMessage(
                "[YTHT-DKP] 拍卖流拍: " .. (auction.itemLink or "物品") .. " (无人出价)",
                channel
            )
        end

        DKP.Print(auction.itemLink .. " 拍卖流拍（无人出价）")

        if DKP.BroadcastHistoryEntry then
            DKP.BroadcastHistoryEntry(historyEntry)
        end
    end

    -- 移除活跃拍卖
    DKP.activeAuctions[auctionID] = nil

    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
    if DKP.BroadcastSheets then DKP.BroadcastSheets() end
end

----------------------------------------------------------------------
-- 取消拍卖（管理员）
----------------------------------------------------------------------
function DKP.CancelAuction(auctionID)
    if not DKP.IsOfficer() then return end

    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then return end

    auction.state = DKP.AUCTION_STATE.CANCELLED

    -- 清除 itemData 的 activeAuctionID
    if auction.itemData then
        auction.itemData.activeAuctionID = nil
    end

    -- 记录取消历史
    local historyEntry = {
        id = auction.id,
        itemLink = auction.itemLink,
        state = "CANCELLED",
        winner = nil,
        winnerChar = nil,
        winnerClass = nil,
        finalBid = auction.currentBid,
        startBid = auction.startBid,
        bidCount = #auction.bids,
        bids = CopyBidsForHistory(auction.bids),
        timestamp = time(),
        officer = auction.officer,
        encounterID = auction.encounterID,
        encounterName = auction.encounterName,
        instanceName = auction.instanceName,
    }
    table.insert(DKP.db.auctionHistory, historyEntry)

    DKP.hasUnsavedChanges = true

    local msg = table.concat({ "CANCEL", auctionID }, MSG_SEP)
    SendAuctionMsg(msg)

    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    if channel then
        SendChatMessage(
            "[YTHT-DKP] 拍卖取消: " .. (auction.itemLink or "物品"),
            channel
        )
    end

    DKP.activeAuctions[auctionID] = nil
    DKP.Print("拍卖已取消: " .. (auction.itemLink or "物品"))

    if DKP.BroadcastHistoryEntry then
        DKP.BroadcastHistoryEntry(historyEntry)
    end

    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
    if DKP.RefreshTableUI then DKP.RefreshTableUI() end
    if DKP.BroadcastSheets then DKP.BroadcastSheets() end
end

----------------------------------------------------------------------
-- 接收消息处理
----------------------------------------------------------------------
local function HandleAuctionStart(parts, sender)
    -- parts: START, id, itemLink, startBid, duration, officer, officerFullName
    local id = parts[2]
    local itemLink = parts[3]
    local startBid = tonumber(parts[4]) or 10
    local duration = tonumber(parts[5]) or 30
    local officer = parts[6] or sender
    local officerFullName = parts[7] or sender

    if DKP.activeAuctions[id] then return end  -- 已存在

    DKP.activeAuctions[id] = {
        id = id,
        itemLink = itemLink,
        startBid = startBid,
        currentBid = 0,
        currentBidder = nil,
        currentBidderPlayer = nil,
        currentBidIsAllIn = false,
        duration = duration,
        startTime = GetTime(),
        endTime = GetTime() + duration,
        state = DKP.AUCTION_STATE.ACTIVE,
        bids = {},
        tiedBidders = nil,
        officer = officer,
        officerFullName = officerFullName,
    }

    DKP.Print("拍卖开始: " .. (itemLink or "物品") .. " 起拍 " .. startBid .. " DKP")
    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
    if DKP.ShowAuctionUI then DKP.ShowAuctionUI() end
end

local function HandleAuctionBid(parts, sender)
    -- parts: BID, auctionID, amount, isAllIn
    if not DKP.IsOfficer() then return end
    local auctionID = parts[2]
    local amount = tonumber(parts[3])
    local isAllIn = parts[4] == "1"
    if auctionID and amount then
        DKP.ProcessBid(sender, auctionID, amount, isAllIn)
    end
end

local function HandleAuctionUpdate(parts, sender)
    -- parts: UPDATE, auctionID, currentBid, bidderName, isAllIn
    local auctionID = parts[2]
    local currentBid = tonumber(parts[3])
    local bidderName = parts[4]
    local isAllIn = parts[5] == "1"

    local auction = DKP.activeAuctions[auctionID]
    if not auction then return end

    auction.currentBid = currentBid or auction.currentBid
    auction.currentBidder = bidderName or auction.currentBidder
    auction.currentBidIsAllIn = isAllIn
    auction.tiedBidders = nil  -- 正常出价清除平局
    if bidderName then
        auction.currentBidderPlayer = DKP.GetPlayerByCharacter(bidderName) or bidderName
    end

    -- 追加到本地 bids 记录（去重：同一出价者同一金额不重复追加）
    if bidderName and currentBid then
        local isDuplicate = false
        local bids = auction.bids
        if #bids > 0 then
            local last = bids[#bids]
            if last.bidder == bidderName and last.amount == currentBid then
                isDuplicate = true
            end
        end
        if not isDuplicate then
            table.insert(bids, {
                bidder = bidderName,
                bidderPlayer = auction.currentBidderPlayer or bidderName,
                amount = currentBid,
                timestamp = GetTime(),
                wallTime = time(),
                isAllIn = isAllIn,
            })
        end
    end

    -- 延长计时（客户端同步）
    local extendTime = DKP.db.options.auctionExtendTime or 10
    local remaining = auction.endTime - GetTime()
    if remaining < extendTime then
        auction.endTime = GetTime() + extendTime
    end

    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
end

local function HandleTieUpdate(parts, sender)
    -- parts: TIE_UPDATE, auctionID, amount, name1;name2;...
    local auctionID = parts[2]
    local amount = tonumber(parts[3])
    local namesStr = parts[4] or ""

    local auction = DKP.activeAuctions[auctionID]
    if not auction then return end

    auction.currentBid = amount or auction.currentBid
    auction.currentBidIsAllIn = true
    auction.tiedBidders = {}
    for name in namesStr:gmatch("[^;]+") do
        table.insert(auction.tiedBidders, {
            name = name,
            playerName = DKP.GetPlayerByCharacter(name) or name,
        })
    end

    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
end

local function HandleAuctionEnd(parts, sender)
    -- parts: END, auctionID, winner, finalBid
    local auctionID = parts[2]
    local winner = parts[3]
    local finalBid = tonumber(parts[4])

    local auction = DKP.activeAuctions[auctionID]
    if auction then
        auction.state = DKP.AUCTION_STATE.ENDED
        DKP.activeAuctions[auctionID] = nil
    end

    if winner == "TIE" then
        DKP.Print("拍卖平局! 转人工处理")
    elseif winner and winner ~= "" and finalBid and finalBid > 0 then
        DKP.Print("拍卖结束: " .. winner .. " 以 " .. finalBid .. " DKP 获胜")
    else
        DKP.Print("拍卖流拍（无人出价）")
    end

    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
end

local function HandleAuctionCancel(parts, sender)
    local auctionID = parts[2]
    local auction = DKP.activeAuctions[auctionID]
    if auction then
        auction.state = DKP.AUCTION_STATE.CANCELLED
        DKP.activeAuctions[auctionID] = nil
        DKP.Print("拍卖已被取消: " .. (auction.itemLink or "物品"))
    end
    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
end

local function HandleAuctionSync(parts, sender)
    -- 管理员响应同步请求，发送所有活跃拍卖信息
    if not DKP.IsOfficer() then return end
    for id, auction in pairs(DKP.activeAuctions) do
        if auction.state == DKP.AUCTION_STATE.ACTIVE then
            local remaining = math.max(0, math.floor(auction.endTime - GetTime()))
            local myFullName = DKP.playerFullName or (DKP.playerName .. "-" .. GetRealmName())
            local msg = table.concat({
                "START", id, auction.itemLink or "", tostring(auction.startBid),
                tostring(remaining), auction.officer or DKP.playerName,
                auction.officerFullName or myFullName
            }, MSG_SEP)
            local target = sender
            SendAuctionWhisper(msg, target)
            if auction.currentBid > 0 then
                local updateMsg = table.concat({
                    "UPDATE", id, tostring(auction.currentBid), auction.currentBidder or "",
                    auction.currentBidIsAllIn and "1" or "0"
                }, MSG_SEP)
                SendAuctionWhisper(updateMsg, target)
            end
        end
    end
end

----------------------------------------------------------------------
-- 事件处理
----------------------------------------------------------------------
local auctionFrame = CreateFrame("Frame")
auctionFrame:RegisterEvent("CHAT_MSG_ADDON")

auctionFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if prefix ~= DKP.AUCTION_PREFIX then return end

    local parts = { strsplit(MSG_SEP, msg) }
    local msgType = parts[1]

    if msgType == "START" then
        HandleAuctionStart(parts, sender)
    elseif msgType == "BID" then
        HandleAuctionBid(parts, sender)
    elseif msgType == "UPDATE" then
        HandleAuctionUpdate(parts, sender)
    elseif msgType == "TIE_UPDATE" then
        HandleTieUpdate(parts, sender)
    elseif msgType == "END" then
        HandleAuctionEnd(parts, sender)
    elseif msgType == "CANCEL" then
        HandleAuctionCancel(parts, sender)
    elseif msgType == "SYNC_AUCTIONS" then
        HandleAuctionSync(parts, sender)
    end
end)

----------------------------------------------------------------------
-- 全局计时器：驱动所有活跃拍卖的倒计时
----------------------------------------------------------------------
local auctionTicker = nil

local function StartGlobalTicker()
    if auctionTicker then return end
    auctionTicker = C_Timer.NewTicker(0.1, function()
        local hasActive = false
        for id, auction in pairs(DKP.activeAuctions) do
            if auction.state == DKP.AUCTION_STATE.ACTIVE then
                hasActive = true
                local remaining = auction.endTime - GetTime()
                if remaining <= 0 then
                    -- 只有管理员处理结束
                    if DKP.IsOfficer() and auction.officer == DKP.playerName then
                        DKP.EndAuction(id)
                    end
                end
            end
        end

        -- 更新UI计时
        if DKP.UpdateAuctionTimers then
            DKP.UpdateAuctionTimers()
        end

        -- 定时刷新拍卖记录页（进行中拍卖倒计时）
        if DKP.UpdateAuctionLogTimer then
            DKP.UpdateAuctionLogTimer()
        end

        -- 没有活跃拍卖时停止ticker
        if not hasActive then
            auctionTicker:Cancel()
            auctionTicker = nil
        end
    end)
end

-- Hook 到 StartAuction 和消息接收时启动 ticker
local origStartAuction = DKP.StartAuction
DKP.StartAuction = function(...)
    local result = origStartAuction(...)
    if result then StartGlobalTicker() end
    return result
end

-- 接收 START 消息时也启动 ticker
local origHandleStart = HandleAuctionStart
HandleAuctionStart = function(...)
    origHandleStart(...)
    StartGlobalTicker()
end
