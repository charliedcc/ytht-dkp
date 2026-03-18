----------------------------------------------------------------------
-- YTHT DKP - Auction Core
--
-- 多拍卖状态机、通信协议、计时器
-- 支持多件装备同时拍卖，玩家各拍卖领先出价之和不得超过DKP余额
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
function DKP.StartAuction(itemLink, startBid, duration)
    if not DKP.IsOfficer() then
        DKP.Print("只有团长或助理可以发起拍卖")
        return false
    end

    startBid = startBid or DKP.db.options.defaultStartingBid or 10
    duration = duration or DKP.db.options.auctionDuration or 30

    auctionCounter = auctionCounter + 1
    local id = "auc_" .. time() .. "_" .. auctionCounter

    local auction = {
        id = id,
        itemLink = itemLink,
        startBid = startBid,
        currentBid = 0,
        currentBidder = nil,
        currentBidderPlayer = nil,
        duration = duration,
        startTime = GetTime(),
        endTime = GetTime() + duration,
        state = DKP.AUCTION_STATE.ACTIVE,
        bids = {},
        officer = DKP.playerName,
    }

    DKP.activeAuctions[id] = auction

    -- 广播 START
    local msg = table.concat({
        "START", id, itemLink, tostring(startBid), tostring(duration), DKP.playerName
    }, MSG_SEP)
    SendAuctionMsg(msg)

    -- RAID 聊天通知
    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
    if channel then
        local itemName = C_Item.GetItemInfo(itemLink) or itemLink
        SendChatMessage(
            "[YTHT-DKP] 拍卖开始: " .. itemLink .. " | 起拍: " .. startBid .. " DKP | 时长: " .. duration .. "秒",
            channel
        )
    end

    DKP.Print("拍卖发起: " .. itemLink .. " 起拍 " .. startBid .. " DKP")

    -- 更新UI
    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
    if DKP.ShowAuctionUI then DKP.ShowAuctionUI() end

    return true
end

----------------------------------------------------------------------
-- 竞价（任何玩家）
----------------------------------------------------------------------
function DKP.PlaceBid(auctionID, amount)
    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then
        DKP.Print("该拍卖已结束或不存在")
        return false
    end

    amount = tonumber(amount)
    if not amount then return false end

    local minIncrement = DKP.db.options.minBidIncrement or 1
    local minBid = auction.currentBid > 0 and (auction.currentBid + minIncrement) or auction.startBid

    if amount < minBid then
        DKP.Print("出价必须 >= " .. minBid)
        return false
    end

    -- 检查可用余额
    local myPlayerName = GetMyPlayerName()
    local available = DKP.GetAvailableDKP(myPlayerName)
    -- 如果我已经是这个拍卖的领先者，可用余额要加回当前出价
    if auction.currentBidderPlayer == myPlayerName then
        available = available + auction.currentBid
    end
    if amount > available then
        DKP.Print("DKP余额不足！可用: " .. available)
        return false
    end

    -- 发送 BID 到管理员
    if auction.officer then
        local officerFull = auction.officer
        -- 尝试带服务器名
        if not officerFull:find("-") then
            officerFull = officerFull .. "-" .. GetRealmName()
        end
        local msg = table.concat({ "BID", auctionID, tostring(amount) }, MSG_SEP)
        SendAuctionWhisper(msg, officerFull)
    end

    -- 如果自己是管理员（本地也是竞拍者），直接处理
    if DKP.IsOfficer() and auction.officer == DKP.playerName then
        DKP.ProcessBid(DKP.playerName, auctionID, amount)
    end

    return true
end

----------------------------------------------------------------------
-- 处理出价（管理员端）
----------------------------------------------------------------------
function DKP.ProcessBid(senderChar, auctionID, amount)
    if not DKP.IsOfficer() then return end

    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then return end

    amount = tonumber(amount)
    if not amount then return end

    local minIncrement = DKP.db.options.minBidIncrement or 1
    local minBid = auction.currentBid > 0 and (auction.currentBid + minIncrement) or auction.startBid

    if amount < minBid then return end

    -- 查找出价者的 DKP 玩家名
    local shortName = senderChar:match("^([^%-]+)") or senderChar
    local bidderPlayer = DKP.GetPlayerByCharacter(senderChar) or DKP.GetPlayerByCharacter(shortName) or shortName

    -- 验证余额
    local available = DKP.GetAvailableDKP(bidderPlayer)
    if auction.currentBidderPlayer == bidderPlayer then
        available = available + auction.currentBid
    end
    if amount > available then return end

    -- 更新拍卖状态
    auction.currentBid = amount
    auction.currentBidder = shortName
    auction.currentBidderPlayer = bidderPlayer

    table.insert(auction.bids, {
        bidder = shortName,
        bidderPlayer = bidderPlayer,
        amount = amount,
        timestamp = GetTime(),
    })

    -- 延长计时（最后N秒出价自动延长）
    local extendTime = DKP.db.options.auctionExtendTime or 10
    local remaining = auction.endTime - GetTime()
    if remaining < extendTime then
        auction.endTime = GetTime() + extendTime
    end

    -- 广播 UPDATE
    local msg = table.concat({
        "UPDATE", auctionID, tostring(amount), shortName
    }, MSG_SEP)
    SendAuctionMsg(msg)

    -- 更新UI
    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
end

----------------------------------------------------------------------
-- 结束拍卖（管理员端，计时到期时调用）
----------------------------------------------------------------------
function DKP.EndAuction(auctionID)
    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then return end

    auction.state = DKP.AUCTION_STATE.ENDED

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

        -- 查找获胜者职业
        local winnerClass = "WARRIOR"
        if playerData then
            for _, char in ipairs(playerData.characters or {}) do
                if char.name == winner then
                    winnerClass = char.class
                    break
                end
            end
        end

        -- 记录拍卖历史
        table.insert(DKP.db.auctionHistory, {
            itemLink = auction.itemLink,
            winner = winnerPlayer,
            winnerChar = winner,
            winnerClass = winnerClass,
            finalBid = finalBid,
            startBid = auction.startBid,
            bidCount = #auction.bids,
            timestamp = time(),
            officer = auction.officer,
        })

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
    else
        -- 无人出价
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
    end

    -- 移除活跃拍卖
    DKP.activeAuctions[auctionID] = nil

    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
    if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
end

----------------------------------------------------------------------
-- 取消拍卖（管理员）
----------------------------------------------------------------------
function DKP.CancelAuction(auctionID)
    if not DKP.IsOfficer() then return end

    local auction = DKP.activeAuctions[auctionID]
    if not auction or auction.state ~= DKP.AUCTION_STATE.ACTIVE then return end

    auction.state = DKP.AUCTION_STATE.CANCELLED

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

    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
end

----------------------------------------------------------------------
-- 接收消息处理
----------------------------------------------------------------------
local function HandleAuctionStart(parts, sender)
    -- parts: START, id, itemLink, startBid, duration, officer
    local id = parts[2]
    local itemLink = parts[3]
    local startBid = tonumber(parts[4]) or 10
    local duration = tonumber(parts[5]) or 30
    local officer = parts[6] or sender

    if DKP.activeAuctions[id] then return end  -- 已存在

    DKP.activeAuctions[id] = {
        id = id,
        itemLink = itemLink,
        startBid = startBid,
        currentBid = 0,
        currentBidder = nil,
        currentBidderPlayer = nil,
        duration = duration,
        startTime = GetTime(),
        endTime = GetTime() + duration,
        state = DKP.AUCTION_STATE.ACTIVE,
        bids = {},
        officer = officer,
    }

    DKP.Print("拍卖开始: " .. (itemLink or "物品") .. " 起拍 " .. startBid .. " DKP")
    if DKP.RefreshAuctionUI then DKP.RefreshAuctionUI() end
    if DKP.ShowAuctionUI then DKP.ShowAuctionUI() end
end

local function HandleAuctionBid(parts, sender)
    -- parts: BID, auctionID, amount — 只有管理员接收
    if not DKP.IsOfficer() then return end
    local auctionID = parts[2]
    local amount = tonumber(parts[3])
    if auctionID and amount then
        DKP.ProcessBid(sender, auctionID, amount)
    end
end

local function HandleAuctionUpdate(parts, sender)
    -- parts: UPDATE, auctionID, currentBid, bidderName
    local auctionID = parts[2]
    local currentBid = tonumber(parts[3])
    local bidderName = parts[4]

    local auction = DKP.activeAuctions[auctionID]
    if not auction then return end

    auction.currentBid = currentBid or auction.currentBid
    auction.currentBidder = bidderName or auction.currentBidder
    if bidderName then
        auction.currentBidderPlayer = DKP.GetPlayerByCharacter(bidderName) or bidderName
    end

    -- 延长计时（客户端同步）
    local extendTime = DKP.db.options.auctionExtendTime or 10
    local remaining = auction.endTime - GetTime()
    if remaining < extendTime then
        auction.endTime = GetTime() + extendTime
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

    if winner and winner ~= "" and finalBid and finalBid > 0 then
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
            local msg = table.concat({
                "START", id, auction.itemLink or "", tostring(auction.startBid),
                tostring(remaining), auction.officer or DKP.playerName
            }, MSG_SEP)
            -- 发送给请求者
            local target = sender
            if not target:find("-") then
                target = target .. "-" .. GetRealmName()
            end
            SendAuctionWhisper(msg, target)
            -- 发送当前出价状态
            if auction.currentBid > 0 then
                local updateMsg = table.concat({
                    "UPDATE", id, tostring(auction.currentBid), auction.currentBidder or ""
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
