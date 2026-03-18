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

            -- Boss击杀自动加分
            if DKP.db.session.active and DKP.IsOfficer and DKP.IsOfficer()
               and DKP.db.options.enableBossKillBonus then
                if not DKP.db.session.bossKills[encounterID] then
                    -- 计算基础分值（按难度配置，未配置则用全局默认值）
                    local diffPoints = DKP.db.options.bossKillPointsByDifficulty
                        and DKP.db.options.bossKillPointsByDifficulty[difficultyID]
                    local basePoints
                    if diffPoints ~= nil then
                        basePoints = diffPoints  -- 难度有明确配置（包括0=不加分）
                    else
                        basePoints = DKP.db.options.bossKillPoints or 5
                    end

                    if basePoints <= 0 then
                        DKP.Print(encounterName .. " 击杀! (难度" .. difficultyID .. " 不加DKP)")
                    else
                        -- 计算额外加分
                        local bonusPoints = 0
                        local bonusReasons = {}

                        -- 开荒首杀额外加分
                        local progressionBonus = DKP.db.options.progressionBonusPoints or 0
                        if progressionBonus > 0 then
                            if not DKP.db.session.firstKills then
                                DKP.db.session.firstKills = {}
                            end
                            if not DKP.db.session.firstKills[encounterID] then
                                DKP.db.session.firstKills[encounterID] = true
                                bonusPoints = bonusPoints + progressionBonus
                                table.insert(bonusReasons, "首杀+" .. progressionBonus)
                            end
                        end

                        -- 团灭加分（每次团灭额外加分，击杀时结算）
                        local wipeBonus = DKP.db.options.wipeBonus or 0
                        if wipeBonus > 0 then
                            local wipeCounts = DKP.db.session.wipeCounts or {}
                            local wipes = wipeCounts[encounterID] or 0
                            if wipes > 0 then
                                local maxWipes = DKP.db.options.wipeBonusMax or 10
                                local effectiveWipes = math.min(wipes, maxWipes)
                                local wipeTotal = effectiveWipes * wipeBonus
                                bonusPoints = bonusPoints + wipeTotal
                                table.insert(bonusReasons, wipes .. "次团灭+" .. wipeTotal)
                            end
                        end

                        local totalPoints = basePoints + bonusPoints
                        DKP.db.session.bossKills[encounterID] = true

                        -- 加分
                        local reason = "Boss击杀: " .. encounterName
                        if #bonusReasons > 0 then
                            reason = reason .. " (" .. table.concat(bonusReasons, ", ") .. ")"
                        end

                        local members = DKP.GetRaidMembers and DKP.GetRaidMembers() or {}
                        local cnt = 0
                        for _, m in ipairs(members) do
                            if m.playerName and m.online then
                                DKP.AdjustDKP(m.playerName, totalPoints, reason)
                                cnt = cnt + 1
                            end
                        end
                        if cnt > 0 then
                            local msg = encounterName .. " 击杀! " .. cnt .. " 名玩家 +" .. totalPoints .. " DKP"
                            if bonusPoints > 0 then
                                msg = msg .. " (基础" .. basePoints .. " + 额外" .. bonusPoints .. ")"
                            end
                            DKP.Print(msg)
                            local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
                            if channel then
                                SendChatMessage("[YTHT-DKP] " .. msg, channel)
                            end
                        end
                    end
                end
            end
        else
            -- 团灭 → 记录团灭次数
            if DKP.db.session.active then
                if not DKP.db.session.wipeCounts then
                    DKP.db.session.wipeCounts = {}
                end
                DKP.db.session.wipeCounts[encounterID] = (DKP.db.session.wipeCounts[encounterID] or 0) + 1
                local wipes = DKP.db.session.wipeCounts[encounterID]
                DKP.Print("Boss " .. encounterName .. " 团灭 (第" .. wipes .. "次)")
            else
                DKP.Print("Boss " .. encounterName .. " 团灭")
            end
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
