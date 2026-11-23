-- Reuse a runtime UFont already used by the game's Chinese text widgets.
-- A FontFace cannot be passed to AHUD:AddDebugText.
local M = {}
local cached, scans = nil, 0

local function valid(object)
    return object ~= nil and object:IsValid()
end

function M.refresh()
    if valid(cached) then return end
    scans = scans + 1
    if (scans - 1) % 5 ~= 0 then return end
    local votes = {}
    for _, widget in ipairs(FindAllOf("TextBlock") or {}) do
        pcall(function()
            if not valid(widget) then return end
            for _, cp in utf8.codes(widget:GetText():ToString()) do
                if cp >= 0x4E00 and cp <= 0x9FFF then
                    local font = widget.Font.FontObject
                    if valid(font) and font:IsA("/Script/Engine.Font")
                        and font.FontCacheType == 1 then
                        local key = font:GetFullName()
                        local entry = votes[key] or {font = font, count = 0}
                        entry.count = entry.count + 1
                        votes[key] = entry
                    end
                    break
                end
            end
        end)
    end
    local bestKey, bestCount = nil, 0
    for key, entry in pairs(votes) do
        if entry.count > bestCount or
            (entry.count == bestCount and (not bestKey or key < bestKey)) then
            bestKey, bestCount, cached = key, entry.count, entry.font
        end
    end
    if valid(cached) then print("[PBZItemBeacon] Chinese font: " .. bestKey .. "\n") end
end

function M.get()
    return valid(cached) and cached or nil
end

return M
