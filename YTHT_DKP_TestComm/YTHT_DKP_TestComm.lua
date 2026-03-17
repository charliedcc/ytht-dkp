----------------------------------------------------------------------
-- YTHT DKP API Test Addon
-- 用于验证 WoW 12.0 中关键 API 的可用性
--
-- 测试命令:
--   /dkptest            - 显示所有可用的测试命令
--   /dkptest send       - 测试 C_ChatInfo.SendAddonMessage (RAID频道)
--   /dkptest whisper 名字 - 测试 WHISPER 频道发送
--   /dkptest guild      - 测试 GUILD 频道发送
--   /dkptest loot       - 显示当前拾取窗口中的物品信息
--   /dkptest combat     - 标记当前战斗状态，用于验证战斗中能否发送
--   /dkptest status     - 显示所有测试结果汇总
----------------------------------------------------------------------

local ADDON_PREFIX = "YTHTDKPTest"
local ADDON_NAME = "YTHT_DKP_TestComm"

-- 测试结果记录
local TestResults = {
    sendAddonMessage_raid = "未测试",
    sendAddonMessage_whisper = "未测试",
    sendAddonMessage_guild = "未测试",
    sendAddonMessage_combat = "未测试",
    receiveAddonMessage = "未测试",
    startLootRoll = "未测试",
    getLootRollItemInfo = "未测试",
    getLootRollItemLink = "未测试",
    encounterLootReceived = "未测试",
    encounterEnd = "未测试",
    lootReady = "未测试",
    getNumLootItems = "未测试",
    getLootSlotLink = "未测试",
}

-- SavedVariables 用于持久化测试结果
YTHT_DKP_TestComm_DB = YTHT_DKP_TestComm_DB or {}

-- 辅助函数：打印带前缀的消息
local function Print(msg)
    print("|cff00BFFF[DKP-Test]|r " .. msg)
end

local function PrintGood(msg)
    print("|cff00BFFF[DKP-Test]|r |cff00ff00✓|r " .. msg)
end

local function PrintBad(msg)
    print("|cff00BFFF[DKP-Test]|r |cffff0000✗|r " .. msg)
end

local function PrintWarn(msg)
    print("|cff00BFFF[DKP-Test]|r |cffffff00!|r " .. msg)
end

----------------------------------------------------------------------
-- 事件框架
----------------------------------------------------------------------
local f = CreateFrame("Frame")

-- 注册插件消息前缀
local prefixOK = C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
if prefixOK then
    PrintGood("RegisterAddonMessagePrefix 成功注册前缀: " .. ADDON_PREFIX)
else
    PrintBad("RegisterAddonMessagePrefix 注册失败!")
end

-- 战斗状态追踪
local inCombat = false
local pendingCombatSend = false

----------------------------------------------------------------------
-- 事件注册
----------------------------------------------------------------------
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PLAYER_REGEN_DISABLED")  -- 进入战斗
f:RegisterEvent("PLAYER_REGEN_ENABLED")   -- 脱离战斗
f:RegisterEvent("ENCOUNTER_END")
f:RegisterEvent("ENCOUNTER_LOOT_RECEIVED")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("LOOT_ROLLS_COMPLETE")
f:RegisterEvent("LOOT_READY")
f:RegisterEvent("LOOT_OPENED")
f:RegisterEvent("LOOT_CLOSED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

f:SetScript("OnEvent", function(self, event, ...)
    -- 插件消息接收
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix == ADDON_PREFIX then
            TestResults.receiveAddonMessage = "成功"
            PrintGood("收到插件消息! 频道=" .. channel .. " 发送者=" .. sender .. " 内容=" .. msg)

            -- 如果是战斗中发的消息，记录
            if msg:find("COMBAT_TEST") then
                TestResults.sendAddonMessage_combat = "成功 (脱战后收到战斗中发送的消息)"
                PrintGood("战斗中发送的消息已收到!")
            end

            -- 保存结果
            YTHT_DKP_TestComm_DB.results = TestResults
        end

    -- 进入战斗
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        Print("进入战斗状态")

        -- 如果有待发送的战斗测试
        if pendingCombatSend then
            Print("尝试在战斗中发送插件消息...")
            local ok, err = pcall(function()
                C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "COMBAT_TEST:" .. time(), "RAID")
            end)
            if ok then
                PrintGood("战斗中 SendAddonMessage 调用成功 (等待确认是否真正送达)")
            else
                PrintBad("战斗中 SendAddonMessage 调用失败: " .. tostring(err))
                TestResults.sendAddonMessage_combat = "失败: " .. tostring(err)
            end
            pendingCombatSend = false
        end

    -- 脱离战斗
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        Print("脱离战斗状态")

    -- Boss战斗结束
    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        TestResults.encounterEnd = "成功"
        PrintGood("ENCOUNTER_END 事件触发!")
        Print("  encounterID=" .. tostring(encounterID))
        Print("  encounterName=" .. tostring(encounterName))
        Print("  difficultyID=" .. tostring(difficultyID))
        Print("  groupSize=" .. tostring(groupSize))
        Print("  success=" .. tostring(success) .. (success == 1 and " (击杀)" or " (团灭)"))
        YTHT_DKP_TestComm_DB.results = TestResults

    -- Boss掉落物品
    elseif event == "ENCOUNTER_LOOT_RECEIVED" then
        local encounterID, itemID, itemLink, quantity, playerName, className = ...
        TestResults.encounterLootReceived = "成功"
        PrintGood("ENCOUNTER_LOOT_RECEIVED 事件触发!")
        Print("  encounterID=" .. tostring(encounterID))
        Print("  itemID=" .. tostring(itemID))
        Print("  itemLink=" .. tostring(itemLink))
        Print("  quantity=" .. tostring(quantity))
        Print("  playerName=" .. tostring(playerName))
        Print("  className=" .. tostring(className))
        YTHT_DKP_TestComm_DB.results = TestResults

    -- 拾取roll开始
    elseif event == "START_LOOT_ROLL" then
        local rollID, rollTime, lootHandle = ...
        TestResults.startLootRoll = "成功"
        PrintGood("START_LOOT_ROLL 事件触发!")
        Print("  rollID=" .. tostring(rollID))
        Print("  rollTime=" .. tostring(rollTime))
        Print("  lootHandle=" .. tostring(lootHandle))

        -- 尝试获取roll物品信息
        local ok, result = pcall(function()
            return GetLootRollItemInfo(rollID)
        end)
        if ok and result then
            TestResults.getLootRollItemInfo = "成功"
            PrintGood("GetLootRollItemInfo 可用!")
            -- 返回值: texture, name, count, quality, bop, canNeed, canGreed, canDisenchant, ...
            Print("  物品名称: " .. tostring(select(2, GetLootRollItemInfo(rollID))))
            Print("  物品品质: " .. tostring(select(4, GetLootRollItemInfo(rollID))))
        else
            TestResults.getLootRollItemInfo = "失败: " .. tostring(result)
            PrintBad("GetLootRollItemInfo 不可用: " .. tostring(result))
        end

        -- 尝试获取roll物品链接
        local ok2, link = pcall(GetLootRollItemLink, rollID)
        if ok2 and link then
            TestResults.getLootRollItemLink = "成功"
            PrintGood("GetLootRollItemLink 可用! 物品链接: " .. tostring(link))
        else
            TestResults.getLootRollItemLink = "失败: " .. tostring(link)
            PrintBad("GetLootRollItemLink 不可用: " .. tostring(link))
        end

        YTHT_DKP_TestComm_DB.results = TestResults

    -- Roll完成
    elseif event == "LOOT_ROLLS_COMPLETE" then
        local lootHandle = ...
        PrintGood("LOOT_ROLLS_COMPLETE 事件触发! lootHandle=" .. tostring(lootHandle))

    -- 拾取窗口打开
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        TestResults.lootReady = "成功"
        PrintGood(event .. " 事件触发!")

        -- 尝试获取拾取窗口中的物品
        local ok, numItems = pcall(GetNumLootItems)
        if ok and numItems then
            TestResults.getNumLootItems = "成功"
            PrintGood("GetNumLootItems 可用! 物品数量: " .. numItems)

            for i = 1, numItems do
                local ok2, link = pcall(GetLootSlotLink, i)
                if ok2 and link then
                    TestResults.getLootSlotLink = "成功"
                    PrintGood("  槽位" .. i .. ": " .. tostring(link))
                else
                    TestResults.getLootSlotLink = "失败: " .. tostring(link)
                    PrintBad("  槽位" .. i .. " GetLootSlotLink 失败: " .. tostring(link))
                end
            end
        else
            TestResults.getNumLootItems = "失败: " .. tostring(numItems)
            PrintBad("GetNumLootItems 不可用: " .. tostring(numItems))
        end

        YTHT_DKP_TestComm_DB.results = TestResults

    elseif event == "LOOT_CLOSED" then
        Print("拾取窗口关闭")

    elseif event == "PLAYER_ENTERING_WORLD" then
        Print("===================================")
        Print("YTHT DKP API 测试插件已加载")
        Print("输入 /dkptest 查看所有测试命令")
        Print("===================================")

        -- 恢复之前的测试结果
        if YTHT_DKP_TestComm_DB.results then
            for k, v in pairs(YTHT_DKP_TestComm_DB.results) do
                if TestResults[k] == "未测试" then
                    TestResults[k] = v
                end
            end
        end
    end
end)

----------------------------------------------------------------------
-- 斜杠命令
----------------------------------------------------------------------
SLASH_DKPTEST1 = "/dkptest"
SlashCmdList["DKPTEST"] = function(msg)
    local cmd, arg1 = strsplit(" ", msg, 2)
    cmd = cmd:lower()

    if cmd == "" or cmd == "help" then
        Print("===== YTHT DKP API 测试命令 =====")
        Print("/dkptest send      - 测试 RAID 频道发送插件消息")
        Print("/dkptest whisper 名字 - 测试 WHISPER 频道发送")
        Print("/dkptest guild     - 测试 GUILD 频道发送")
        Print("/dkptest combat    - 下次进入战斗时测试发送")
        Print("/dkptest loot      - 显示当前拾取窗口物品")
        Print("/dkptest status    - 显示所有测试结果汇总")
        Print("/dkptest reset     - 重置所有测试结果")
        Print("=================================")
        Print("自动测试: Boss击杀(ENCOUNTER_END)、装备掉落(START_LOOT_ROLL)、")
        Print("         拾取窗口(LOOT_READY)等事件会自动记录")

    elseif cmd == "send" then
        if not IsInRaid() then
            PrintWarn("你不在团队中，无法测试 RAID 频道。请先加入团队。")
            return
        end
        Print("发送测试消息到 RAID 频道...")
        Print("  当前战斗状态: " .. (inCombat and "战斗中" or "脱战"))
        local ok, err = pcall(function()
            C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "TEST_RAID:" .. time(), "RAID")
        end)
        if ok then
            TestResults.sendAddonMessage_raid = "调用成功 (等待回收确认)"
            PrintGood("SendAddonMessage(RAID) 调用成功! 等待回收消息...")
        else
            TestResults.sendAddonMessage_raid = "失败: " .. tostring(err)
            PrintBad("SendAddonMessage(RAID) 失败: " .. tostring(err))
        end
        YTHT_DKP_TestComm_DB.results = TestResults

    elseif cmd == "whisper" then
        if not arg1 or arg1 == "" then
            PrintWarn("用法: /dkptest whisper 目标玩家名")
            return
        end
        Print("发送测试消息到 WHISPER 频道，目标: " .. arg1)
        local ok, err = pcall(function()
            C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "TEST_WHISPER:" .. time(), "WHISPER", arg1)
        end)
        if ok then
            TestResults.sendAddonMessage_whisper = "调用成功 (目标: " .. arg1 .. ")"
            PrintGood("SendAddonMessage(WHISPER) 调用成功!")
        else
            TestResults.sendAddonMessage_whisper = "失败: " .. tostring(err)
            PrintBad("SendAddonMessage(WHISPER) 失败: " .. tostring(err))
        end
        YTHT_DKP_TestComm_DB.results = TestResults

    elseif cmd == "guild" then
        if not IsInGuild() then
            PrintWarn("你不在公会中，无法测试 GUILD 频道。")
            return
        end
        Print("发送测试消息到 GUILD 频道...")
        local ok, err = pcall(function()
            C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "TEST_GUILD:" .. time(), "GUILD")
        end)
        if ok then
            TestResults.sendAddonMessage_guild = "调用成功 (等待回收确认)"
            PrintGood("SendAddonMessage(GUILD) 调用成功!")
        else
            TestResults.sendAddonMessage_guild = "失败: " .. tostring(err)
            PrintBad("SendAddonMessage(GUILD) 失败: " .. tostring(err))
        end
        YTHT_DKP_TestComm_DB.results = TestResults

    elseif cmd == "combat" then
        if inCombat then
            Print("当前已在战斗中，直接测试...")
            local ok, err = pcall(function()
                C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "COMBAT_TEST:" .. time(), "RAID")
            end)
            if ok then
                PrintGood("战斗中 SendAddonMessage 调用成功!")
            else
                PrintBad("战斗中 SendAddonMessage 失败: " .. tostring(err))
                TestResults.sendAddonMessage_combat = "失败: " .. tostring(err)
            end
        else
            pendingCombatSend = true
            PrintWarn("已标记。下次进入战斗时将自动测试发送插件消息。")
            PrintWarn("请确保你在团队中(需要RAID频道)，然后开始一场战斗。")
        end
        YTHT_DKP_TestComm_DB.results = TestResults

    elseif cmd == "loot" then
        Print("尝试读取当前拾取窗口...")
        local ok, numItems = pcall(GetNumLootItems)
        if ok and numItems and numItems > 0 then
            PrintGood("拾取窗口已打开，包含 " .. numItems .. " 个物品:")
            for i = 1, numItems do
                local ok2, link = pcall(GetLootSlotLink, i)
                if ok2 and link then
                    Print("  " .. i .. ": " .. link)
                else
                    Print("  " .. i .. ": (无法获取链接)")
                end
            end
        else
            PrintWarn("拾取窗口未打开或没有物品。请在打开拾取窗口时使用此命令。")
        end

    elseif cmd == "status" then
        Print("===== API 测试结果汇总 =====")
        Print("")
        Print("|cffFFD700--- 插件通信 API ---|r")
        local function StatusLine(name, result)
            local color = "|cff888888"  -- 灰色 = 未测试
            if result:find("成功") then
                color = "|cff00ff00"    -- 绿色 = 成功
            elseif result:find("失败") then
                color = "|cffff0000"    -- 红色 = 失败
            end
            Print("  " .. name .. ": " .. color .. result .. "|r")
        end

        StatusLine("SendAddonMessage(RAID)", TestResults.sendAddonMessage_raid)
        StatusLine("SendAddonMessage(WHISPER)", TestResults.sendAddonMessage_whisper)
        StatusLine("SendAddonMessage(GUILD)", TestResults.sendAddonMessage_guild)
        StatusLine("SendAddonMessage(战斗中)", TestResults.sendAddonMessage_combat)
        StatusLine("接收 CHAT_MSG_ADDON", TestResults.receiveAddonMessage)

        Print("")
        Print("|cffFFD700--- 拾取/战利品 API ---|r")
        StatusLine("ENCOUNTER_END 事件", TestResults.encounterEnd)
        StatusLine("ENCOUNTER_LOOT_RECEIVED", TestResults.encounterLootReceived)
        StatusLine("START_LOOT_ROLL 事件", TestResults.startLootRoll)
        StatusLine("GetLootRollItemInfo()", TestResults.getLootRollItemInfo)
        StatusLine("GetLootRollItemLink()", TestResults.getLootRollItemLink)
        StatusLine("LOOT_READY/OPENED 事件", TestResults.lootReady)
        StatusLine("GetNumLootItems()", TestResults.getNumLootItems)
        StatusLine("GetLootSlotLink()", TestResults.getLootSlotLink)

        Print("")
        Print("=================================")

    elseif cmd == "reset" then
        for k in pairs(TestResults) do
            TestResults[k] = "未测试"
        end
        YTHT_DKP_TestComm_DB.results = {}
        PrintGood("所有测试结果已重置。")

    else
        PrintWarn("未知命令: " .. cmd .. "。输入 /dkptest 查看帮助。")
    end
end
