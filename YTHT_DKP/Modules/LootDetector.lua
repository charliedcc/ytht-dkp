----------------------------------------------------------------------
-- YTHT DKP - Loot Detector
--
-- 监听 12.0 Group Loot 事件，自动将装备记录到表格
--
-- 事件流程:
--   1. ENCOUNTER_START → 记录当前Boss信息
--   2. START_LOOT_ROLL → 获取装备信息，添加到当前Boss
--   3. ENCOUNTER_END   → 标记Boss击杀状态
--   4. ENCOUNTER_LOOT_RECEIVED → 记录谁获得了装备
----------------------------------------------------------------------

local DKP = YTHT_DKP

-- 当前战斗的Boss信息
local currentEncounter = {
    id = nil,
    name = nil,
    difficultyID = nil,
    groupSize = nil,
}

-- 当前副本信息
local currentInstance = {
    name = nil,
    id = nil,
}

-- rollID → encounterID 映射，用于关联roll物品和Boss
local rollEncounterMap = {}

-- 最近的Boss encounterID（用于START_LOOT_ROLL时关联）
local lastEncounterID = nil
local lastEncounterName = nil

----------------------------------------------------------------------
-- 获取当前副本信息
----------------------------------------------------------------------
local function UpdateInstanceInfo()
    local name, instanceType, difficultyID, difficultyName,
          maxPlayers, dynamicDifficulty, isDynamic, instanceID,
          instanceGroupSize, lfgDungeonID = GetInstanceInfo()

    if instanceType == "raid" or instanceType == "party" then
        -- 构建副本显示名称（包含难度）
        local displayName = name
        if difficultyName and difficultyName ~= "" then
            displayName = name .. " (" .. difficultyName .. ")"
        end
        currentInstance.name = displayName
        currentInstance.id = instanceID
        return displayName
    else
        currentInstance.name = nil
        currentInstance.id = nil
        return nil
    end
end

----------------------------------------------------------------------
-- 获取物品品质过滤（只记录蓝色及以上品质的装备）
----------------------------------------------------------------------
local MIN_QUALITY = 3  -- Rare (蓝色)

local function ShouldTrackItem(quality)
    return quality and quality >= MIN_QUALITY
end

----------------------------------------------------------------------
-- 事件处理
----------------------------------------------------------------------
local f = CreateFrame("Frame")

f:RegisterEvent("ENCOUNTER_START")
f:RegisterEvent("ENCOUNTER_END")
f:RegisterEvent("START_LOOT_ROLL")
f:RegisterEvent("ENCOUNTER_LOOT_RECEIVED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")

f:SetScript("OnEvent", function(self, event, ...)
    ----------------------------------------------------------------
    -- 进入副本/区域切换 → 更新副本信息
    ----------------------------------------------------------------
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        UpdateInstanceInfo()
        return
    end

    ----------------------------------------------------------------
    -- Boss战斗开始 → 记录当前Boss信息
    ----------------------------------------------------------------
    if event == "ENCOUNTER_START" then
        local encounterID, encounterName, difficultyID, groupSize = ...
        currentEncounter.id = encounterID
        currentEncounter.name = encounterName
        currentEncounter.difficultyID = difficultyID
        currentEncounter.groupSize = groupSize

        DKP.Print("Boss战斗开始: " .. encounterName)
        return
    end

    ----------------------------------------------------------------
    -- Boss战斗结束 → 标记击杀状态，准备记录掉落
    ----------------------------------------------------------------
    if event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...

        if success == 1 then
            -- 击杀成功
            lastEncounterID = encounterID
            lastEncounterName = encounterName

            local instanceName = UpdateInstanceInfo()
            if instanceName then
                -- 确保Boss存在于表格中
                DKP.AddBossToSheet(instanceName, encounterName, encounterID)
                -- 标记击杀
                DKP.MarkBossKilled(instanceName, encounterID)
            end
        else
            DKP.Print("Boss " .. encounterName .. " 团灭")
        end

        -- 重置当前战斗
        currentEncounter.id = nil
        currentEncounter.name = nil
        return
    end

    ----------------------------------------------------------------
    -- 拾取Roll开始 → 获取装备信息，记录到Boss表格
    ----------------------------------------------------------------
    if event == "START_LOOT_ROLL" then
        local rollID, rollTime, lootHandle = ...

        -- 获取物品信息
        local texture, name, count, quality, bop, canNeed, canGreed,
              canDisenchant, reasonNeed, reasonGreed, reasonDisenchant,
              devalue, isUpgradeItem = GetLootRollItemInfo(rollID)

        local itemLink = GetLootRollItemLink(rollID)

        if not itemLink then
            DKP.Print("无法获取Roll物品链接 (rollID=" .. rollID .. ")")
            return
        end

        -- 品质过滤
        if not ShouldTrackItem(quality) then
            return
        end

        -- 确定关联的Boss
        local instanceName = currentInstance.name or UpdateInstanceInfo()
        if not instanceName then
            -- 不在副本中（可能是世界Boss等）
            instanceName = "野外/其他"
        end

        -- 关联到最近击杀的Boss
        local encounterID = lastEncounterID
        local bossName = lastEncounterName

        if not encounterID then
            -- 如果没有Boss记录（可能是小怪或其他情况），用"未知Boss"
            encounterID = 0
            bossName = "未知来源"
        end

        -- 记录rollID和encounterID的映射
        rollEncounterMap[rollID] = encounterID

        -- 确保Boss存在
        DKP.AddBossToSheet(instanceName, bossName, encounterID)
        -- 添加物品
        local itemData = DKP.AddItemToBoss(instanceName, encounterID, itemLink, rollID)

        if itemData then
            DKP.Print("装备入表: " .. itemLink .. " (来自 " .. bossName .. ")")
        end

        -- 自动打开主界面（如果还没打开）
        if DKP.MainFrame and not DKP.MainFrame:IsShown() then
            DKP.MainFrame:Show()
            DKP.RefreshTableUI()
        end

        return
    end

    ----------------------------------------------------------------
    -- 玩家获得装备 → 记录获得者
    ----------------------------------------------------------------
    if event == "ENCOUNTER_LOOT_RECEIVED" then
        local encounterID, itemID, itemLink, quantity, playerName, className = ...

        if not itemLink or not playerName then return end

        -- 查找对应的物品记录并更新获得者
        local instanceName = currentInstance.name
        if not instanceName then return end

        local sheet = DKP.db.sheets[instanceName]
        if not sheet then return end

        for _, boss in ipairs(sheet.bosses) do
            if boss.encounterID == encounterID then
                for _, item in ipairs(boss.items) do
                    -- 通过物品ID匹配
                    local recordItemID = C_Item.GetItemInfoInstant(item.link)
                    if recordItemID == itemID and (item.winner == "" or item.winner == nil) then
                        item.winner = playerName
                        item.winnerClass = className
                        DKP.Print(playerName .. " 获得了 " .. itemLink)
                        DKP.RefreshTableUI()
                        return
                    end
                end
            end
        end
    end
end)

----------------------------------------------------------------------
-- 对外接口：手动添加物品到当前Boss（用于团长拾取模式）
----------------------------------------------------------------------
function DKP.ManualAddItem(itemLink)
    local instanceName = currentInstance.name or "手动记录"
    local encounterID = lastEncounterID or 0
    local bossName = lastEncounterName or "手动添加"

    DKP.AddBossToSheet(instanceName, bossName, encounterID)

    local manualRollID = -time()  -- 负数表示手动添加
    local itemData = DKP.AddItemToBoss(instanceName, encounterID, itemLink, manualRollID)

    if itemData then
        DKP.Print("手动添加装备: " .. itemLink)
    end
end
