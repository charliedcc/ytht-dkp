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

    if instanceType == "raid" then
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
local function ShouldTrackItem(quality)
    local minQ = (DKP.db and DKP.db.options and DKP.db.options.minItemQuality) or 2
    return quality and quality >= minQ
end

----------------------------------------------------------------------
-- 事件处理
----------------------------------------------------------------------
local f = CreateFrame("Frame")

f:RegisterEvent("ENCOUNTER_START")
f:RegisterEvent("ENCOUNTER_END")
f:RegisterEvent("START_LOOT_ROLL")
-- f:RegisterEvent("ENCOUNTER_LOOT_RECEIVED")  -- 移除: 防止 WoW 自动 roll 触发 0 DKP 分配
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

        -- 只在团本中处理（5人本不记录）
        if not IsInRaid() then return end

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

            -- Boss击杀加分（需确认）
            if DKP.db.session.active and DKP.IsOfficer and DKP.IsOfficer()
               and DKP.db.options.enableBossKillBonus then
                if not DKP.db.session.bossKills[encounterID] then
                    -- 计算基础分值（按难度配置，未配置则用全局默认值）
                    local diffPoints = DKP.db.options.bossKillPointsByDifficulty
                        and DKP.db.options.bossKillPointsByDifficulty[difficultyID]
                    local basePoints
                    if diffPoints ~= nil then
                        basePoints = diffPoints
                    else
                        basePoints = DKP.db.options.bossKillPoints or 5
                    end

                    if basePoints > 0 then
                        -- 计算额外加分
                        local bonusPoints = 0
                        local bonusReasons = {}

                        local progressionBonus = DKP.db.options.progressionBonusPoints or 0
                        if progressionBonus > 0 then
                            if not DKP.db.session.firstKills then DKP.db.session.firstKills = {} end
                            if not DKP.db.session.firstKills[encounterID] then
                                bonusPoints = bonusPoints + progressionBonus
                                table.insert(bonusReasons, "首杀+" .. progressionBonus)
                            end
                        end

                        local wipeBonus = DKP.db.options.wipeBonus or 0
                        if wipeBonus > 0 then
                            local wipes = (DKP.db.session.wipeCounts or {})[encounterID] or 0
                            if wipes > 0 then
                                local effectiveWipes = math.min(wipes, DKP.db.options.wipeBonusMax or 10)
                                local wipeTotal = effectiveWipes * wipeBonus
                                bonusPoints = bonusPoints + wipeTotal
                                table.insert(bonusReasons, wipes .. "次团灭+" .. wipeTotal)
                            end
                        end

                        local totalPoints = basePoints + bonusPoints
                        local reason = "Boss击杀: " .. encounterName
                        if #bonusReasons > 0 then
                            reason = reason .. " (" .. table.concat(bonusReasons, ", ") .. ")"
                        end

                        -- 弹出确认框，而非自动执行
                        local confirmText = encounterName .. " 击杀!\n全团 +" .. totalPoints .. " DKP"
                        if bonusPoints > 0 then
                            confirmText = confirmText .. "\n(基础" .. basePoints .. " + 额外" .. bonusPoints .. ")"
                        end
                        confirmText = confirmText .. "\n\n是否执行加分？"

                        -- 用自定义对话框（避免 StaticPopup 无效）
                        if not DKP._bossKillConfirmDialog then
                            local d = CreateFrame("Frame", "YTHTDKPBossKillConfirm", UIParent, "BackdropTemplate")
                            d:SetSize(320, 140)
                            d:SetPoint("CENTER", 0, 100)
                            d:SetFrameStrata("FULLSCREEN_DIALOG")
                            d:SetFrameLevel(250)
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
                            text:SetPoint("TOP", 0, -12)
                            text:SetWidth(290)
                            d.text = text
                            local yesBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
                            yesBtn:SetSize(80, 24)
                            yesBtn:SetPoint("BOTTOMLEFT", 20, 12)
                            yesBtn:SetText("确定加分")
                            d.yesBtn = yesBtn
                            local noBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
                            noBtn:SetSize(80, 24)
                            noBtn:SetPoint("BOTTOMRIGHT", -20, 12)
                            noBtn:SetText("跳过")
                            noBtn:SetScript("OnClick", function() d:Hide() end)
                            DKP._bossKillConfirmDialog = d
                        end

                        local d = DKP._bossKillConfirmDialog
                        d.text:SetText(confirmText)
                        d.yesBtn:SetScript("OnClick", function()
                            d:Hide()
                            if DKP.db.session.bossKills[encounterID] then return end
                            DKP.db.session.bossKills[encounterID] = true
                            if progressionBonus > 0 and DKP.db.session.firstKills
                               and not DKP.db.session.firstKills[encounterID] then
                                DKP.db.session.firstKills[encounterID] = true
                            end
                            local members = DKP.GetRaidMembers and DKP.GetRaidMembers() or {}
                            local names = {}
                            local charNames = {}
                            for _, m in ipairs(members) do
                                if m.playerName and m.online then
                                    table.insert(names, m.playerName)
                                    table.insert(charNames, m.shortName)
                                end
                            end
                            local cnt = DKP.BulkAdjustDKPBatch and DKP.BulkAdjustDKPBatch(names, totalPoints, reason, charNames) or 0
                            if cnt > 0 then
                                local msg = encounterName .. " 击杀! " .. cnt .. " 名玩家 +" .. totalPoints .. " DKP"
                                DKP.Print(msg)
                                local ch = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
                                if ch then SendChatMessage("[YTHT-DKP] " .. msg, ch) end
                                -- Boss 击杀后自动同步 DKP 给全团
                                C_Timer.After(2, function()
                                    if DKP.BroadcastDKPData then
                                        DKP.BroadcastDKPData()
                                        DKP.Print("已自动同步 DKP 数据")
                                    end
                                end)
                            end
                            if DKP.RefreshDKPUI then DKP.RefreshDKPUI() end
                        end)
                        d:Show()
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
        -- 只在团本中记录掉落（5人本不记录）
        if not IsInRaid() then return end

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
            -- 管理员自动广播掉落列表变化
            if DKP.IsOfficer and DKP.IsOfficer() and DKP.BroadcastSheets then
                DKP.BroadcastSheets()
            end
        end

        -- 刷新界面（如果已打开）
        if DKP.MainFrame and DKP.MainFrame:IsShown() then
            DKP.RefreshTableUI()
        end

        return
    end

    -- ENCOUNTER_LOOT_RECEIVED 已移除（防止 WoW roll 系统触发 0 DKP 自动分配）
    -- DKP 分配只通过拍卖/插装备操作
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
