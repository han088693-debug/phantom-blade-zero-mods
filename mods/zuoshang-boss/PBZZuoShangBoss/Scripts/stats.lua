-- Uses the original config with the replacement's initialized level/world.
-- Same-config output matched live NPC attributes. Cross-config DifficultyTag
-- handling is not yet verified; callers must gate unverified encounter configs.
local stats = {}
local names = { "Health_Max", "Health", "Attack" }
local fields = { "BaseValue", "CurrentValue" }

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function unwrap(value)
    if type(value) == "number" or type(value) == "string" then return value end
    local ok, inner = pcall(function() return value:get() end)
    return ok and inner or value
end

local function attributes(output)
    assert(type(output.OutDefaultAttributes) == "table", "missing OutDefaultAttributes")
    local defaults = {}
    for key, value in pairs(output.OutDefaultAttributes) do
        local name = unwrap(key).AttributeName
        if type(name) ~= "string" then name = name:ToString() end
        value = unwrap(value)
        assert(type(name) == "string" and name ~= "", "invalid attribute name")
        assert(finite(value), "invalid default attribute: " .. name)
        assert(defaults[name] == nil, "duplicate attribute name: " .. name)
        defaults[name] = value
    end
    assert(finite(defaults.Health_Max) and defaults.Health_Max > 0, "invalid default Health_Max")
    assert(finite(defaults.Attack) and defaults.Attack >= 0, "invalid default Attack")
    return defaults
end

local function prepare(actor, originalConfig)
    assert(actor:IsValid() and originalConfig:IsValid(), "invalid actor or original config")
    local set = actor.AttributeSetBase
    local refs, originals = {}, {}
    for _, name in ipairs(names) do
        refs[name], originals[name] = set[name], {}
        for _, field in ipairs(fields) do
            local value = refs[name][field]
            assert(finite(value), "invalid existing " .. name .. "." .. field)
            originals[name][field] = value
        end
    end
    assert(originals.Health_Max.CurrentValue > 0, "replacement is not initialized")
    assert(originals.Health.CurrentValue >= 0, "invalid existing health")
    local output = {}
    originalConfig:GetDefaultAttributes(actor, output)
    local defaults = attributes(output)
    local ratio = originals.Health.CurrentValue / originals.Health_Max.CurrentValue
    local health = defaults.Health_Max * ratio
    assert(finite(health), "invalid scaled health")
    return refs, {
        defaults = defaults,
        originals = originals,
        health_ratio = ratio,
        stats = { health = health, max_health = defaults.Health_Max, base_attack = defaults.Attack },
    }
end

local function near(actual, expected)
    return finite(actual) and math.abs(actual - expected) <= math.max(0.0001, math.abs(expected) * 0.000001)
end

function stats.apply(actor, originalConfig)
    local ok, refs, metadata = pcall(prepare, actor, originalConfig)
    if not ok then return nil, "read_failed: " .. tostring(refs) end
    local values = {
        Health_Max = metadata.stats.max_health,
        Health = metadata.stats.health,
        Attack = metadata.stats.base_attack,
    }
    local written, err = pcall(function()
        for _, name in ipairs(names) do
            for _, field in ipairs(fields) do
                refs[name][field] = values[name]
            end
        end
        for _, name in ipairs(names) do
            for _, field in ipairs(fields) do
                assert(near(refs[name][field], values[name]), "write did not persist: " .. name .. "." .. field)
            end
        end
    end)
    if not written then
        -- Attempt every field even if one setter fails; keep the full snapshot.
        for _, name in ipairs(names) do
            for _, field in ipairs(fields) do
                pcall(function() refs[name][field] = metadata.originals[name][field] end)
            end
        end
        metadata.rollback_ok = true
        for _, name in ipairs(names) do
            for _, field in ipairs(fields) do
                local readOK, value = pcall(function() return refs[name][field] end)
                if not readOK or value ~= metadata.originals[name][field] then
                    metadata.rollback_ok = false
                end
            end
        end
        return nil, "write_failed: " .. tostring(err), metadata
    end
    -- Report the values actually stored by the engine, including float rounding.
    metadata.stats.health = refs.Health.CurrentValue
    metadata.stats.max_health = refs.Health_Max.CurrentValue
    metadata.stats.base_attack = refs.Attack.CurrentValue
    return metadata
end

return stats
