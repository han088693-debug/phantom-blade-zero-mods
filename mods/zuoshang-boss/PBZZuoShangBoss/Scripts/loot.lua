-- Redirect only observed native calls for a registered, active replacement.
-- Native C++ calls that bypass UE4SS hooks remain outside this module's coverage.
local loot, installed = {}, nil
local ROOT = "/Script/ProjectPBZ.PBZCharacter_NPC:"
local specs = {
    {id = "owner", path = ROOT .. "GetCombatLootDataForOwner"},
    {id = "loot", path = ROOT .. "GetCombatLootData"},
    {id = "self", path = ROOT .. "GetCombatLootDataBySelf"},
}

local function valid(object)
    local ok, value = pcall(function() return object:IsValid() end)
    return ok and value == true
end

local function unwrap(value)
    local ok, result = pcall(function() return value:get() end)
    return ok and result or value
end

function loot.install(options)
    if installed and installed.status().registered > 0 then return installed end
    local hooks, entries, enabled = {}, {}, false
    local npc, kismet
    local function report(entry, message)
        entry.errors = entry.errors + 1
        entry.last_error = tostring(message)
        enabled = false
        if type(options.log) == "function" then
            pcall(options.log, "[PBZZuoShangBoss loot] " .. entry.id .. ": " .. entry.last_error)
        end
    end
    local function find(path)
        local ok, object = pcall(StaticFindObject, path)
        return ok and valid(object) and object or nil
    end
    npc = find("/Script/ProjectPBZ.PBZCharacter_NPC")
    kismet = find("/Script/Engine.Default__KismetSystemLibrary")

    local function actor_record(value)
        local actor = unwrap(value)
        if not valid(actor) or not actor:IsA(npc)
            or actor:GetFName():ToString():find("^Default__") then return nil end
        local record = options.lookup_actor(actor)
        return record and record.status == "active" and record or nil
    end

    local function soft_path(value)
        local path = kismet:Conv_SoftClassReferenceToString(value)
        if type(path) ~= "string" and path ~= nil then path = path:ToString() end
        assert(type(path) == "string", "cannot read soft class path")
        return path
    end

    local function redirect(entry, record, level, class)
        local old_level, old_path = level:get(), soft_path(class:get())
        local target_path = soft_path(record.original_soft_class)
        assert(target_path ~= "", "missing original soft class")
        assert(type(old_level) == "number" and type(record.loot_level) == "number"
            and record.loot_level >= 0 and record.loot_level <= 2147483647
            and record.loot_level % 1 == 0, "invalid loot level")
        -- get() may alias the argument's storage. Build a separate rollback value.
        local backup = kismet:Conv_SoftClassPathToSoftClassRef(kismet:MakeSoftClassPath(old_path))
        assert(backup ~= nil and soft_path(backup) == old_path, "cannot snapshot soft class")
        local ok, err = pcall(function()
            level:set(record.loot_level)
            class:set(record.original_soft_class)
            assert(level:get() == record.loot_level and soft_path(class:get()) == target_path,
                "loot parameter write did not persist")
        end)
        if not ok then
            entry.rollbacks = entry.rollbacks + 1
            -- Attempt both restores even if one fails.
            local class_ok, class_err = pcall(function()
                if soft_path(class:get()) ~= old_path then class:set(backup) end
                assert(soft_path(class:get()) == old_path, "class restore mismatch")
            end)
            local level_ok, level_err = pcall(function()
                if level:get() ~= old_level then level:set(old_level) end
                assert(level:get() == old_level, "level restore mismatch")
            end)
            if not class_ok or not level_ok then
                entry.rollback_errors = entry.rollback_errors + 1
                err = tostring(err) .. "; rollback failed: "
                    .. tostring(class_ok and level_err or class_err)
            end
            report(entry, err)
            return
        end
        entry.redirected = entry.redirected + 1
        entry.last_target_class = target_path
    end

    local function observe(entry, context, ...)
        entry.seen = entry.seen + 1
        local args, record = {...}, nil
        if entry.id == "owner" then
            record = actor_record(args[1])
        elseif entry.id == "loot" then
            local a, b = actor_record(context), actor_record(args[6])
            assert(not (a and b and a ~= b), "ambiguous replacement loot context")
            record = a or b
        else
            record = actor_record(context)
        end
        if not record then return end
        entry.matched = entry.matched + 1
        entry.last_origin = tostring(record.origin_key or "")
        if not enabled or entry.id == "self" then return end
        if entry.id == "owner" then
            redirect(entry, record, args[2], args[3])
        else
            redirect(entry, record, args[1], args[2])
        end
    end

    local handle = {}
    function handle.status()
        local result = {ready = enabled, registered = #hooks, coverage = "observed_hooks_only", entries = {}}
        for id, entry in pairs(entries) do
            local copy = {}
            for key, value in pairs(entry) do copy[key] = value end
            result.entries[id] = copy
        end
        return result
    end
    function handle.uninstall()
        enabled = false
        local remaining = {}
        for _, hook in ipairs(hooks) do
            local ok, err = pcall(UnregisterHook, hook.entry.path, hook.pre, hook.post)
            if ok and err ~= false then
                hook.entry.registered = false
            else
                remaining[#remaining + 1] = hook
                report(hook.entry, "unregister failed: " .. tostring(err))
            end
        end
        hooks = remaining
        return #hooks == 0
    end

    for _, spec in ipairs(specs) do
        local entry = {id = spec.id, path = spec.path, registered = false, seen = 0,
            matched = 0, redirected = 0, errors = 0, rollbacks = 0, rollback_errors = 0}
        entries[spec.id] = entry
        local fn = find(spec.path)
        local ok, flags = pcall(function() return fn:GetFunctionFlags() end)
        local native = ok and type(flags) == "number" and math.floor(flags / 0x400) % 2 == 1
        local delegate = ok and type(flags) == "number" and
            (math.floor(flags / 0x10000) % 2 == 1 or math.floor(flags / 0x100000) % 2 == 1)
        if not npc or not kismet or type(options.lookup_actor) ~= "function"
            or type(RegisterHook) ~= "function" or type(UnregisterHook) ~= "function" then
            report(entry, "missing required lookup, engine library or hook API")
        elseif not native or delegate then
            report(entry, not fn and "function not loaded" or delegate and "delegate rejected" or "not native")
        else
            local registered, pre, post = pcall(RegisterHook, spec.path, function(...)
                local success, err = pcall(observe, entry, ...)
                if not success then report(entry, err) end
                -- Nil preserves normal execution and the game's return value.
            end, function() end)
            if registered and type(pre) == "number" and type(post) == "number" then
                entry.registered = true
                hooks[#hooks + 1] = {entry = entry, pre = pre, post = post}
            else
                report(entry, registered and "registration returned no handles" or pre)
            end
        end
    end
    enabled = entries.owner.registered and entries.loot.registered
    installed = handle
    return handle
end

return loot
