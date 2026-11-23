-- Streamed actors can have a cell outer world; the level owns the play world.
local world = {}

local function valid(object)
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

function world.of_actor(actor)
    if not valid(actor) then return nil end
    local ok, owning = pcall(function()
        local level = actor:GetLevel()
        return valid(level) and level.OwningWorld or nil
    end)
    if ok and valid(owning) then return owning end
    local fallbackOk, fallback = pcall(function() return actor:GetWorld() end)
    return fallbackOk and valid(fallback) and fallback or nil
end

return world
