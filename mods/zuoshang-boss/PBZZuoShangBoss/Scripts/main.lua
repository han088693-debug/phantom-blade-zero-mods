local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local scripts = assert(source:match("^(.*)/[^/]+$"), "mod script directory unavailable")
package.path = scripts .. "/?.lua;" .. package.path
local rules = require("rules")
local world = require("world")
local adapter, lootHooks, bossPaths, lastReport, disabledReason
local function log(message) print("[PBZZuoShangBoss 0.1.3-preview] " .. message .. "\n") end
local function disable(reason)
    if disabledReason then return end
    disabledReason = "disabled: " .. tostring(reason)
    if adapter then adapter.disable(disabledReason) else log(disabledReason) end
end
local function valid(object)
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end
local function text(value)
    if type(value) == "string" then return value end
    return value:ToString()
end
local function find(path)
    local object = StaticFindObject(path)
    return valid(object) and object or nil
end
local function currentWorld()
    local pc = require("UEHelpers").GetPlayerController()
    if not valid(pc) or not valid(pc.Pawn) then return nil end
    return world.of_actor(pc.Pawn)
end
local function indexBosses()
    local codex = find("/Game/PBZContent/DataTable/DT_CodexEnemyDataTable.DT_CodexEnemyDataTable")
    local kismet = find("/Script/Engine.Default__KismetSystemLibrary")
    if not codex or not kismet then return nil end
    local paths, count = {}, 0
    codex:ForEachRow(function(rowName, row)
        if not row.bIsBoss then return end
        local id = text(rowName)
        local function add(reference)
            local path = text(kismet:Conv_SoftClassReferenceToString(reference))
            if path ~= "" then paths[path] = id end
        end
        add(row.EnemyClass)
        row.AliasEnemyClasses:ForEach(function(_, value) add(value:get()) end)
        count = count + 1
    end)
    log("indexed " .. count .. " boss rows; three YuCong split actors each select dragon ZuoShang")
    return paths
end
local function resolve(spawner, _, classPath)
    local id = spawner.SpawnerID:ToString()
    if id == "" or id == "None" then id = spawner:GetFName():ToString() end
    local spawnWorld = world.of_actor(spawner)
    if not spawnWorld then return nil, "spawner world unavailable" end
    return rules.select(bossPaths[classPath], id, classPath, spawnWorld:GetFullName())
end
local function tick()
    local world = currentWorld()
    if not world then return end
    if not adapter then
        if disabledReason then return end
        if not bossPaths then bossPaths = indexBosses(); if not bossPaths then return end end
        adapter = require("engine").install({resolve = resolve, log = log})
    end
    if not disabledReason then
        if not lootHooks then
            lootHooks = require("loot").install({lookup_actor = adapter.lookup_actor, log = log})
        end
        if not lootHooks.status().ready then
            disable("original-loot hooks unavailable; stopping new replacements")
        end
    end
    -- Disabled adapters still finish pending spawns and retain live loot mappings.
    adapter.refresh(world)
    local status = adapter.status()
    local report = tostring(status.ready) .. ":" .. status.committed .. ":" .. status.errors .. ":" .. status.skipped
    if report ~= lastReport then
        lastReport = report
        log("ready=" .. tostring(status.ready) .. " active=" .. status.active
            .. " committed=" .. status.committed .. " skipped=" .. status.skipped
            .. " errors=" .. status.errors .. (status.last_skip and " last_skip=" .. status.last_skip or ""))
    end
end
if type(LoopInGameThreadWithDelay) ~= "function" then
    log("disabled: compatible UE4SS game-thread scheduler unavailable")
else
    LoopInGameThreadWithDelay(500, function()
        local ok, err = pcall(tick)
        if not ok then disable(err) end
        return false
    end)
    log("experimental boss replacement loaded; original spawners and groups retained")
end
