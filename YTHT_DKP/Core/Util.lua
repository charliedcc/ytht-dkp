----------------------------------------------------------------------
-- YTHT DKP - Utility Functions
----------------------------------------------------------------------

local DKP = YTHT_DKP

-- 职业颜色
local CLASS_COLORS = {
    WARRIOR     = { r = 0.78, g = 0.61, b = 0.43 },
    PALADIN     = { r = 0.96, g = 0.55, b = 0.73 },
    HUNTER      = { r = 0.67, g = 0.83, b = 0.45 },
    ROGUE       = { r = 1.00, g = 0.96, b = 0.41 },
    PRIEST      = { r = 1.00, g = 1.00, b = 1.00 },
    DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 },
    SHAMAN      = { r = 0.00, g = 0.44, b = 0.87 },
    MAGE        = { r = 0.25, g = 0.78, b = 0.92 },
    WARLOCK     = { r = 0.53, g = 0.53, b = 0.93 },
    MONK        = { r = 0.00, g = 1.00, b = 0.60 },
    DRUID       = { r = 1.00, g = 0.49, b = 0.04 },
    DEMONHUNTER = { r = 0.64, g = 0.19, b = 0.79 },
    EVOKER      = { r = 0.20, g = 0.58, b = 0.50 },
}

-- 品质颜色
local QUALITY_COLORS = {
    [0] = { r = 0.62, g = 0.62, b = 0.62 },  -- 灰色 (Poor)
    [1] = { r = 1.00, g = 1.00, b = 1.00 },  -- 白色 (Common)
    [2] = { r = 0.12, g = 1.00, b = 0.00 },  -- 绿色 (Uncommon)
    [3] = { r = 0.00, g = 0.44, b = 0.87 },  -- 蓝色 (Rare)
    [4] = { r = 0.64, g = 0.21, b = 0.93 },  -- 紫色 (Epic)
    [5] = { r = 1.00, g = 0.50, b = 0.00 },  -- 橙色 (Legendary)
}

function DKP.GetClassColor(class)
    return CLASS_COLORS[class] or { r = 1, g = 1, b = 1 }
end

function DKP.GetQualityColor(quality)
    return QUALITY_COLORS[quality] or QUALITY_COLORS[1]
end

function DKP.ClassColorText(text, class)
    local c = DKP.GetClassColor(class)
    return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, text)
end

-- 打印函数
function DKP.Print(msg)
    print("|cff00BFFF[YTHT-DKP]|r " .. tostring(msg))
end

-- 获取物品品质颜色的十六进制
function DKP.QualityColorHex(quality)
    local c = DKP.GetQualityColor(quality)
    return string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end
