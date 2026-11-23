-- Read loaded bell state and names only. Never activate or interact with a bell.
local M = {}
local names, seenTables = {}, {}
local worldAddress, bellManager
local refreshCount = 0
local fallback = "未激活铃铛"

local function valid(value)
    local ok, result = pcall(function() return value and value:IsValid() end)
    return ok and result == true
end

local function name(value)
    if value == nil then return "" end
    if type(value) == "string" then return value end
    return value:ToString()
end

local function normalized(value)
    local id = name(value):lower()
    if id ~= "" and id ~= "none" then return id end
end

local function localized(value, manager)
    if value == nil then return nil end
    local function clean(text)
        text = name(text):gsub("[%c%s]+", " "):match("^%s*(.-)%s*$")
        if text == "" or text == "None" then return nil end
        local ok, key = pcall(function() return name(value.Key) end)
        if ok and key ~= "" and text == key then return nil end
        return text
    end
    local ok, text = pcall(function() return clean(value.ValueCache) end)
    if ok and text then return text end
    if manager then
        ok, text = pcall(function() return clean(manager:Conv_LocTextToString(value)) end)
        if ok then return text end
    end
end

function M.reset()
    names, seenTables = {}, {}
    worldAddress, bellManager = nil, nil
    refreshCount = 0
end

function M.id(actor)
    local ok, id = pcall(function()
        if valid(actor) then return normalized(actor.BellID) end
    end)
    if ok then return id end
end

function M.refresh(pawn)
    local ok, address = pcall(function()
        if not valid(pawn) then return nil end
        local level = pawn:GetLevel()
        if not valid(level) or not valid(level.OwningWorld) then return nil end
        return level.OwningWorld:GetAddress()
    end)
    if not ok or address == nil then M.reset(); return end
    if worldAddress ~= address then
        M.reset()
        worldAddress = address
    end
    -- Reacquire each scan: a failed read must not keep a previous manager alive.
    bellManager = nil
    pcall(function()
        local library = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
        local class = StaticFindObject("/Script/ProjectPBZ.BellManager")
        if valid(library) and valid(class) then
            local candidate = library:GetWorldSubsystem(pawn, class)
            if valid(candidate) then bellManager = candidate end
        end
    end)

    refreshCount = refreshCount + 1
    if (refreshCount - 1) % 5 ~= 0 then return end
    local manager
    pcall(function()
        local library = StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
        if valid(library) then
            local candidate = library:GetEventPipelineManagerWithoutWorld()
            if valid(candidate) then manager = candidate end
        end
    end)
    for _, dt in ipairs(FindAllOf("DataTable") or {}) do
        pcall(function()
            if not valid(dt) then return end
            local key = dt:GetFullName() .. ":" .. tostring(dt:GetAddress())
            if seenTables[key] then return end
            local schema = dt:GetRowStruct()
            if not valid(schema) then return end
            if name(schema:GetFName()) ~= "BellDataStruct" then return end
            local complete = true
            dt:ForEachRow(function(_, row)
                local rowOk, resolved = pcall(function()
                    local id = normalized(row.BellID)
                    if not id then return true end
                    local text = localized(row.BellName, manager)
                    if text then names[id] = text end
                    return text ~= nil
                end)
                if not rowOk or not resolved then complete = false end
            end)
            -- Keep only strings; unresolved localized names retry on later scans.
            seenTables[key] = complete
        end)
    end
end

function M.available(actor)
    local ok, result = pcall(function()
        if not valid(actor) or not valid(bellManager) then return false end
        if actor.BellType ~= 0 or actor.bActive ~= false then return false end
        local nativeId = actor.BellID
        if not normalized(nativeId) then return false end
        -- Verified native boolean result. Unknown or conflicting state stays hidden.
        return bellManager:IsBellActivated(nativeId) == false
    end)
    return ok and result == true
end

function M.describe(actor)
    local id = M.id(actor)
    local text = id and names[id]
    local label = text and fallback .. "·" .. text or fallback
    return {
        entries = {{key = "bell:" .. (id or "unknown"), family = "bell", id = id,
            name = label, kind = "铃铛", possible = false}},
        kinds = {["铃铛"] = true}, possible = false, label = label,
    }
end

return M
