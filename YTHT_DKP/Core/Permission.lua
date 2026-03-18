----------------------------------------------------------------------
-- YTHT DKP - Permission System
--
-- 权限检查：优先检查 DKP 系统内 admins 列表，未配置时 fallback 到团队角色
-- DKP.IsOfficer() — 管理员（可加分/发起拍卖/修改DKP）
-- DKP.IsRaidLeader() — 仅团长（用于取消拍卖等严格操作）
----------------------------------------------------------------------

local DKP = YTHT_DKP

function DKP.IsOfficer()
    if DKP.db and DKP.db.admins and next(DKP.db.admins) then
        return DKP.db.admins[DKP.playerName] == true
    end
    -- 未配置时 fallback 到团队角色
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    elseif IsInGroup() then
        return UnitIsGroupLeader("player")
    else
        -- 单人模式允许管理（方便导入/编辑/测试）
        return true
    end
end

function DKP.IsRaidLeader()
    if DKP.db and DKP.db.admins and next(DKP.db.admins) then
        return DKP.db.admins[DKP.playerName] == true
    end
    if IsInRaid() then
        return UnitIsGroupLeader("player")
    elseif IsInGroup() then
        return UnitIsGroupLeader("player")
    else
        return true
    end
end
