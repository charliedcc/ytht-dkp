----------------------------------------------------------------------
-- YTHT DKP - Permission System
--
-- 权限检查：基于团队职位（团长/助理）
-- DKP.IsOfficer() — 团长或助理（可加分/发起拍卖/修改DKP）
-- DKP.IsRaidLeader() — 仅团长（用于取消拍卖等严格操作）
----------------------------------------------------------------------

local DKP = YTHT_DKP

function DKP.IsOfficer()
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
    if IsInRaid() then
        return UnitIsGroupLeader("player")
    elseif IsInGroup() then
        return UnitIsGroupLeader("player")
    else
        return true
    end
end
