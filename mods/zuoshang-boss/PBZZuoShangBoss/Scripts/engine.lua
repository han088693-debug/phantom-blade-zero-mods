-- Experimental original-spawner adapter. Run every method on the game thread.
-- resolve(spawner, originalSoftClass, originalPath) returns a state.lua plan.
-- It must identify actual stages; asset suffixes are not stage observations.
-- stats.apply(actor, originalConfig) writes/read backs original-config stats.
-- GetCombatLevel on the replacement supplies the native spawn-context level;
-- its equivalence to the original Boss's level requires encounter validation.
-- refresh(world) watches loaded spawners; reset(world) also handles same-map
-- retries. Neither method destroys actors or changes persistent spawner data.
-- Class loading and CDO/config reads occur only in refresh, outside hooks.
local engine, installed, serial = {}, nil, 0
local state = require("state")
local worlds = require("world")
local TARGETS = {
    "/PBZCombatAsset/ActorData/Mobs/054_ZuoShang/BP_Monster_ZuoShang_Ending.BP_Monster_ZuoShang_Ending_C",
    "/PBZCombatAsset/ActorData/Mobs/076_ZuoShang_P2/BP_Monster_ZuoShang_P2.BP_Monster_ZuoShang_P2_C",
}
local ASYNC = "/Script/SGameAI.AISpawner:BeginAsyncSpawn"
local FINISH = "/Script/SGameAI.AISpawner:NativeOnSpawnFinish"
local FLOW_SCRIPT = "/Game/PBZContent/AI/AIScript_SetFlowAsset.AIScript_SetFlowAsset_C"
local SCRIPT_PROFILES = {
    HuaQianXiao_Seq027 = {
        original = "/PBZCombatAsset/ActorData/Mobs/HuaQianXiao/BP_Monster_HuaQianXIao.BP_Monster_HuaQianXIao_C",
        classes = {FLOW_SCRIPT, "/PBZCombatAsset/ActorData/Mobs/Common/SGameAIExtension/AIScript_OverrideCombatSense.AIScript_OverrideCombatSense_C"},
        flow_index = 1,
        flow = "/Game/PBZContent/Blueprint/FlowGraph/QuestFlowGraph/FuJiZhiLin/BPF_JianChiChuChang.BPF_JianChiChuChang",
        sense = "HalfDefaultSight", label = "flower_entry_flow+HalfDefaultSight",
    },
    LuanShi_Seq030 = {
        original = "/PBZCombatAsset/ActorData/Mobs/Luanshi/BP_Monster_LuanShi.BP_Monster_LuanShi_C",
        classes = {FLOW_SCRIPT}, flow_index = 1,
        flow = "/Game/PBZContent/Blueprint/FlowGraph/QuestFlowGraph/FuJiZhiLin/BPF_QuanChiChuChang.BPF_QuanChiChuChang",
        label = "iron_entry_flow",
    },
    SanTouMoOu = {
        original = "/PBZCombatAsset/ActorData/Mobs/YuCong/BP_Monster_YuCong_P1.BP_Monster_YuCong_P1_C",
        classes = {"/PBZCombatAsset/ActorData/Mobs/Common/SGameAIExtension/AIScript_AddTagOnDead.AIScript_AddTagOnDead_C", FLOW_SCRIPT},
        flow_index = 2,
        flow = "/Game/PBZContent/Blueprint/FlowGraph/QuestFlowGraph/FuJiZhiLin/BPF_SanTouMoOuRuZhan.BPF_SanTouMoOuRuZhan",
        label = "puppet_entry_flow+death_tags",
    },
}

local function valid(value)
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end

local function unwrap(value)
    local ok, result = pcall(function() return value:get() end)
    return ok and result or value
end

local function path(object)
    return object:GetFullName():match("^%S+ (.+)$")
end

local function key(object)
    return tostring(object:GetAddress()) .. ":" .. object:GetFullName()
end

function engine.install(options)
    if installed and installed.status().registered > 0 then return installed end
    assert(type(options.resolve) == "function", "resolve callback required")
    local stats = require("stats")
    assert(type(stats.apply) == "function", "stats.apply required")
    local kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pbz = StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    assert(valid(kismet) and valid(pbz), "required engine libraries unavailable")
    local store, hooks, pending, actors, waiting, blocked, retired = state.new(), {}, {}, {}, {}, {}, {}
    local active_spawns = {}
    local resources, candidates, skip_messages = {}, {}, {}
    local world_key, enabled, getter_count, hook_depth, warming = nil, true, 0, 0, false
    local report = {experimental = true, errors = 0, skipped = 0, rewrites = 0,
        committed = 0, seen_getter = 0, seen_async = 0, seen_finish = 0, seen_ready = 0, seen_poll = 0,
        seen_despawn = 0, released = 0, reused = 0, isolated_loot = 0,
        unmanaged_replacements = 0, rollback_errors = 0, cache_misses = 0, prewarm_errors = 0}
    local handle = {}

    local function log(message)
        if type(options.log) == "function" then
            pcall(options.log, "[PBZZuoShangBoss engine] " .. message)
        end
    end
    local function fault(message)
        enabled = false
        report.errors, report.last_error = report.errors + 1, tostring(message)
        log(report.last_error)
    end
    local function context(spawner, requested, original)
        local id = spawner.SpawnerID:ToString()
        if id == "" or id == "None" then id = spawner:GetFName():ToString() end
        return "spawner=" .. id .. " requested=" .. tostring(requested)
            .. " original=" .. tostring(original)
    end
    local function skip(reason, spawner, requested, original)
        local message = tostring(reason)
        if spawner then
            message = message .. " " .. context(spawner, requested, original)
            local spawner_key = key(spawner)
            if skip_messages[spawner_key] == message then return end
            skip_messages[spawner_key] = message
            log("skipped: " .. message)
        end
        report.skipped, report.last_skip = report.skipped + 1, message
    end
    local function soft_path(value)
        local result = kismet:Conv_SoftClassReferenceToString(value)
        if type(result) ~= "string" and result ~= nil then result = result:ToString() end
        assert(type(result) == "string", "soft class path unavailable; input="
            .. type(value) .. "/" .. tostring(value) .. "; result=" .. type(result) .. "/" .. tostring(result))
        return result
    end
    local function soft_copy(class_path)
        local result = kismet:Conv_SoftClassPathToSoftClassRef(kismet:MakeSoftClassPath(class_path))
        assert(result ~= nil and soft_path(result) == class_path, "cannot copy soft class")
        return result
    end
    local function cached(class_path)
        local item = resources[class_path]
        return item and valid(item.class) and valid(item.config) and item or nil
    end
    local function warm(class_path)
        assert(hook_depth == 0, "class prewarming cannot run inside a hook")
        local item = cached(class_path)
        if item then return item end
        resources[class_path] = nil
        log("prewarm start: " .. class_path)
        local ok, result = pcall(function()
            local reference = soft_copy(class_path)
            local class = kismet:LoadClassAsset_Blocking(reference)
            assert(valid(class), "class unavailable")
            local defaults = class:GetCDO()
            assert(valid(defaults) and valid(defaults["Actor Config"]), "actor config unavailable")
            return {class = class, config = defaults["Actor Config"], soft = reference}
        end)
        if not ok then
            report.prewarm_errors = report.prewarm_errors + 1
            report.last_prewarm_error = class_path .. ": " .. tostring(result)
            log("prewarm failed: " .. report.last_prewarm_error)
            return nil
        end
        resources[class_path] = result
        log("prewarm end: " .. class_path)
        return result
    end
    local function same_world(object)
        if not valid(object) or object:GetFName():ToString():find("^Default__") then return false end
        local owner = worlds.of_actor(object)
        return valid(owner) and key(owner) == world_key
    end
    local function actor_identity(actor, token)
        return {address = actor:GetAddress(), name = actor:GetFullName(), spawn_token = token}
    end
    local function clean_overrides(spawner, original_class)
        local info = spawner.SpawnInfo
        for _, field in ipairs({"DefaultBehaviorTree", "CombatStateMachineOverride",
            "StrategyOverride", "AbilityPoolOverride"}) do
            if valid(info[field]) then return false, "original AI override: " .. field end
        end
        for _, field in ipairs({"AdditionalDecisionTrees", "DecisionTreeOverride", "ActivityBehaviorOverride"}) do
            local any = false
            local ok = pcall(function() info[field]:ForEach(function() any = true end) end)
            if not ok then return false, "cannot inspect original AI override: " .. field end
            if any then return false, "original AI override: " .. field end
        end
        local scripts, count = {}, 0
        local readable = pcall(function()
            info.ExtraScripts:ForEach(function(_, value)
                count = count + 1
                scripts[count] = unwrap(value)
            end)
        end)
        if not readable then return false, "cannot inspect original AI override: ExtraScripts" end
        if count == 0 then return true end
        -- Only these observed script combinations are retained. Never clear
        -- the original flow, death tags, sight settings or script instances.
        local ok, preserved = pcall(function()
            local profile = SCRIPT_PROFILES[spawner.SpawnerID:ToString()]
            if not profile or original_class ~= profile.original
                or path(worlds.of_actor(spawner)) ~= "/Game/Maps/B03/PBZ_Fujizhilin_WP.PBZ_Fujizhilin_WP"
                or spawner.RandomSpawn ~= false or count ~= #profile.classes then return nil end
            local random_classes = false
            spawner.RandomSpawnClasses:ForEach(function() random_classes = true end)
            if random_classes then return nil end
            for index, class_path in ipairs(profile.classes) do
                if not valid(scripts[index]) or path(scripts[index]:GetClass()) ~= class_path then return nil end
            end
            local flow = scripts[profile.flow_index].RootFlow
            if not valid(flow) or path(flow) ~= profile.flow or not valid(flow.ExpectedOwnerClass)
                or path(flow.ExpectedOwnerClass) ~= "/Script/Flow.FlowComponent" then return nil end
            if profile.sense then
                local sense = scripts[2]["Sense Name"]
                if type(sense) ~= "string" then sense = sense:ToString() end
                if sense ~= profile.sense then return nil end
            end
            return profile.label
        end)
        if not ok or not preserved then return false, "original AI override: ExtraScripts" end
        return true, nil, preserved
    end

    local function prepare(spawner, requested)
        local requested_path, spawner_key = soft_path(requested), key(spawner)
        if blocked[spawner_key] then
            skip("previous spawn has no confirmed completion after same-map reset",
                spawner, requested_path, blocked[spawner_key].original_class)
            return
        end
        local old = pending[spawner_key]
        if old then
            assert(requested_path == old.original_class or requested_path == old.target_path,
                "different class requested while replacement spawn is pending")
            return old
        end
        local candidate = candidates[spawner_key]
        local plan = candidate and candidate.plan
        if not plan or candidate.original_class ~= requested_path then
            -- Classification is only for diagnostics; it cannot bypass the
            -- existing candidate/resource checks or load anything in this hook.
            if candidate or resources[requested_path]
                or options.resolve(spawner, requested, requested_path) then
                report.cache_misses = report.cache_misses + 1
                skip("requested class was not selected and prewarmed for this spawner",
                    spawner, requested_path, candidate and candidate.original_class or soft_path(spawner.Class))
            end
            return
        end
        assert(plan.original_class == requested_path, "resolver original class mismatch")
        local target_path = TARGETS[plan.target_phase]
        assert(target_path, "resolver target phase must be 1 or 2")
        if target_path == requested_path then
            skip("already requested target", spawner, requested_path, plan.original_class)
            return
        end
        local id = spawner.SpawnerID:ToString()
        if id == "None" or id == "" then id = spawner:GetFName():ToString() end
        assert(plan.spawn_id == id, "resolver original spawn id mismatch")
        local clean, why, preserved_scripts = clean_overrides(spawner, plan.original_class)
        if not clean then skip(why, spawner, requested_path, plan.original_class); return end
        local original, target = cached(requested_path), cached(target_path)
        if not original or not target then
            report.cache_misses = report.cache_misses + 1
            skip("spawn class or original config cache is unavailable; wait for refresh",
                spawner, requested_path, plan.original_class)
            return
        end
        serial = serial + 1
        local record, failure = store:claim(plan, serial, spawner_key)
        if not record then skip(failure, spawner, requested_path, plan.original_class); return end
        record.original_soft_class, record.original_config = original.soft, original.config
        record.preserved_scripts = preserved_scripts
        record.target_path, record.target_soft_class = target_path, target.soft
        record.spawner_key, record.spawner = spawner_key, spawner
        record.declared_spawner_class = soft_path(spawner.Class)
        record.original_group_key = valid(spawner.MobGroup) and key(spawner.MobGroup) or nil
        record.prior_pawn_key = valid(spawner.SpawnedAI) and key(spawner.SpawnedAI) or nil
        pending[spawner_key] = record
        return record
    end

    local function replace(spawner, parameter)
        if not same_world(spawner) then return end
        if warming and not pending[key(spawner)] then
            local requested = parameter:get()
            local requested_path = soft_path(requested)
            if candidates[key(spawner)] or resources[requested_path]
                or options.resolve(spawner, requested, requested_path) then
                skip("resource prewarming is in progress", spawner, requested_path, soft_path(spawner.Class))
            end
            return
        end
        if not enabled and not pending[key(spawner)] then return end
        local before = soft_path(parameter:get())
        local record = prepare(spawner, parameter:get())
        if not record then return end
        if before == record.target_path then return end
        local backup = record.original_soft_class -- Independent cached value, not get() storage.
        local ok, err = pcall(function()
            parameter:set(record.target_soft_class)
            assert(soft_path(parameter:get()) == record.target_path, "spawn class write mismatch")
        end)
        if not ok then
            local restored, restore_error = pcall(function()
                parameter:set(backup)
                assert(soft_path(parameter:get()) == before, "spawn class restore mismatch")
            end)
            if not restored then
                report.rollback_errors = report.rollback_errors + 1
                err = tostring(err) .. "; rollback failed: " .. tostring(restore_error)
            end
            pending[record.spawner_key] = nil
            store:finish(record, "class_write_failed")
            fault(err)
            return
        end
        report.rewrites = report.rewrites + 1
        if not record.selection_logged then
            record.selection_logged = true
            skip_messages[record.spawner_key] = nil
            log("selected: " .. context(spawner, before, record.original_class)
                .. " target=" .. record.target_path
                .. (record.preserved_scripts and " preserved_scripts=" .. record.preserved_scripts or ""))
        end
    end

    local function confirmed_binding(spawner, pawn)
        if not valid(spawner) or not valid(pawn) then return false end
        local controller = pawn:GetController()
        return spawner.IsSpawning == false and valid(spawner.SpawnedAI)
            and key(spawner.SpawnedAI) == key(pawn) and valid(pawn.Spawner)
            and key(pawn.Spawner) == key(spawner) and valid(controller)
            and valid(controller.Pawn) and key(controller.Pawn) == key(pawn)
    end

    local function isolate_rebound(entry, pawn, record)
        if entry and not entry.loot_isolated and record and record ~= entry.record
            and record.prior_pawn_key ~= key(pawn)
            and entry.record.replacement.name == pawn:GetFullName()
            and confirmed_binding(record.spawner, pawn) then
            entry.loot_isolated = true
            report.isolated_loot = report.isolated_loot + 1
            log("loot isolated after confirmed new binding: "
                .. context(record.spawner, record.original_class, entry.record.original_class)
                .. " actor=" .. pawn:GetFullName())
        end
    end

    local function rebound(record, pawn, previous)
        if not previous.slot_released or previous.spawner_key ~= record.spawner_key
            or previous.original_class ~= record.original_class or record.prior_pawn_key ~= nil
            or previous.replacement.address ~= pawn:GetAddress()
            or previous.replacement.name ~= pawn:GetFullName() then return false end
        return confirmed_binding(record.spawner, pawn)
    end

    local function initialize(record)
        if warming then return end
        local pawn, spawner = record.waiting_pawn, record.spawner
        if not same_world(pawn) then
            waiting[record.spawner_key] = nil
            store:finish(record, "pawn_unloaded_before_initialization")
            return
        end
        local ready, initialized, level = pcall(function()
            isolate_rebound(actors[pawn:GetAddress()], pawn, record)
            if record.reused_record and not rebound(record, pawn, record.reused_record) then return false end
            local controller = pawn:GetController()
            if not valid(controller) or not valid(controller.SGameAIComponent)
                or not controller.SGameAIComponent.bInitialized
                or pawn.AttributeSetBase.Health_Max.CurrentValue <= 0
                or pawn.AttributeSetBase.Health.CurrentValue <= 0 then return false end
            if record.original_group_key and (not valid(pawn.MobGroup)
                or key(pawn.MobGroup) ~= record.original_group_key) then return false end
            local combat_level, attribute_level = pawn:GetCombatLevel(), pawn.AttributeSetBase.Level.CurrentValue
            if type(combat_level) ~= "number" or type(attribute_level) ~= "number"
                or type(pawn.Level) ~= "number" or attribute_level < 0
                or attribute_level > 2147483647 or attribute_level ~= attribute_level
                or combat_level ~= combat_level or pawn.Level ~= pawn.Level
                or math.abs(combat_level - attribute_level) > 0.00001
                or math.abs(pawn.Level - attribute_level) > 0.00001 then return false end
            return true, math.floor(attribute_level + 0.5)
        end)
        if not ready or not initialized then
            report.last_wait = "controller, health, original group or natural level initialization: "
                .. record.origin_key
            return
        end
        waiting[record.spawner_key] = nil
        local ok, err = pcall(function()
            assert(soft_path(spawner.Class) == record.declared_spawner_class,
                "persistent original spawner class changed")
            local difficulty, cycle = pbz:GetDifficulty(pawn), pbz:GetGameCycle(pawn)
            local metadata, why = stats.apply(pawn, record.original_config)
            assert(type(metadata) == "table", why or "original stats unavailable")
            metadata.loot_level, metadata.difficulty, metadata.ng_cycle = level, difficulty, cycle
            serial = serial + 1
            local identity = actor_identity(pawn, "replacement:" .. serial)
            local committed, failure = store:commit(record, identity, metadata, record.reused_record)
            assert(committed, failure)
            actors[identity.address] = {actor = pawn, record = record}
            active_spawns[record.spawner_key] = record
            if record.reused_record then
                report.reused = report.reused + 1
                record.reused_record = nil
            end
            report.committed = report.committed + 1
            log("committed: " .. context(spawner, record.original_class, record.original_class)
                .. " target=" .. record.target_path .. " actor=" .. identity.name
                .. " level=" .. tostring(level)
                .. (record.preserved_scripts and " preserved_scripts=" .. record.preserved_scripts or ""))
        end)
        if not ok then
            store:finish(record, "initialization_failed")
            report.unmanaged_replacements = report.unmanaged_replacements + 1
            fault("replacement already spawned; initialization failed: " .. tostring(err))
        end
    end

    local function finish(_, spawner_argument, pawn_argument, source)
        local spawner, pawn = unwrap(spawner_argument), unwrap(pawn_argument)
        if not same_world(spawner) then return end
        if valid(pawn) and retired[key(pawn)] then
            skip("duplicate completion from a retired replacement actor",
                spawner, path(pawn:GetClass()), soft_path(spawner.Class))
            return
        end
        local spawner_key = key(spawner)
        if blocked[spawner_key] then
            if same_world(pawn) and path(pawn:GetClass()) == blocked[spawner_key].target_path then
                local original_class = blocked[spawner_key].original_class
                blocked[spawner_key] = nil
                skip("discarded completion from the retired spawn request",
                    spawner, path(pawn:GetClass()), original_class)
            end
            return
        end
        local record = pending[spawner_key]
        if not record then return end -- Includes duplicate finish notifications.
        if not valid(pawn) then
            skip("ignored invalid spawn completion", spawner, "<invalid>", record.original_class)
            return
        end
        if key(pawn) == record.prior_pawn_key then
            skip("existing pawn is not the new replacement spawn",
                spawner, path(pawn:GetClass()), record.original_class)
            return
        end
        assert(same_world(pawn) and path(pawn:GetClass()) == record.target_path,
            "finished pawn does not match the requested replacement")
        local entry = actors[pawn:GetAddress()]
        if entry then
            isolate_rebound(entry, pawn, record)
            if not rebound(record, pawn, entry.record) then
                skip(entry.loot_isolated and "confirmed pooled rebinding is unsupported; old loot mapping isolated"
                    or "existing pooled actor has no confirmed new spawner binding",
                    spawner, path(pawn:GetClass()), record.original_class)
                return
            end
            record.reused_record = entry.record
        end
        pending[spawner_key] = nil
        record.waiting_pawn = pawn
        record.completion_source, report.last_completion_source = source, source
        waiting[spawner_key] = record
        initialize(record)
    end

    local function despawn(context_argument)
        local spawner = unwrap(context_argument)
        if not same_world(spawner) then return end
        local spawner_key = key(spawner)
        local record = active_spawns[spawner_key]
        if not record then return end
        if pending[spawner_key] or waiting[spawner_key] or blocked[spawner_key]
            or valid(spawner.SpawnedAI) or spawner.IsSpawning ~= false then return end
        if store:release_slot(record) then
            active_spawns[spawner_key] = nil
            report.released = report.released + 1
            log("despawn released: " .. context(spawner, record.original_class, record.original_class)
                .. " actor=" .. record.replacement.name)
        end
    end

    local function guarded(callback)
        return function(...)
            hook_depth = hook_depth + 1
            local ok, err = pcall(callback, ...)
            hook_depth = hook_depth - 1
            if not ok then fault(err) end
            -- Nil leaves the engine's original function and return value intact.
        end
    end
    local function register(function_path, callback, native, after)
        if hooks[function_path] then return true end
        local ok, pre, post = pcall(function()
            local fn = StaticFindObject(function_path)
            assert(valid(fn), "hook function not loaded: " .. function_path)
            local flags = fn:GetFunctionFlags()
            assert(math.floor(flags / 0x10000) % 2 == 0
                and math.floor(flags / 0x100000) % 2 == 0, "delegate hook rejected")
            if native then
                assert(math.floor(flags / 0x400) % 2 == 1, "native hook required")
                if after then return RegisterHook(function_path, function() end, guarded(callback)) end
                return RegisterHook(function_path, guarded(callback), function() end)
            end
            if math.floor(flags / 0x400) % 2 == 1 then
                return RegisterHook(function_path, function() end, guarded(callback))
            end
            -- A single callback is UE4SS's post hook for the Blueprint getter.
            return RegisterHook(function_path, guarded(callback))
        end)
        if not ok or type(pre) ~= "number" or type(post) ~= "number" then
            fault("hook registration failed " .. function_path .. ": " .. tostring(pre))
            return false
        end
        hooks[function_path] = {pre = pre, post = post}
        return true
    end

    function handle.reset(world)
        local next_world = valid(world) and key(world) or nil
        if next_world ~= nil and next_world == world_key then
            -- Native completion has no request token. Do not let an old async
            -- completion claim a new request from the same surviving spawner.
            for spawner_key, record in pairs(pending) do blocked[spawner_key] = record end
            for _, entry in pairs(actors) do
                if valid(entry.actor) then retired[key(entry.actor)] = entry.actor end
            end
            for _, record in pairs(waiting) do
                if valid(record.waiting_pawn) then retired[key(record.waiting_pawn)] = record.waiting_pawn end
            end
        else
            blocked, retired, candidates = {}, {}, {}
        end
        world_key = next_world
        skip_messages = {}
        local detached = store:reset(world_key)
        pending, actors, waiting, active_spawns = {}, {}, {}, {}
        return detached
    end
    function handle.refresh(world)
        if hook_depth > 0 then skip("refresh requested inside a hook"); return end
        local next_world = valid(world) and key(world) or nil
        if next_world ~= world_key then handle.reset(world) end
        if not world_key then return end
        for address, entry in pairs(actors) do
            if not valid(entry.actor) or entry.actor:GetFullName() ~= entry.record.replacement.name then
                store:finish(entry.record, "actor_unloaded")
                if active_spawns[entry.record.spawner_key] == entry.record then
                    active_spawns[entry.record.spawner_key] = nil
                end
                actors[address] = nil
            end
        end
        for spawner_key, record in pairs(pending) do
            if not valid(record.spawner) or key(record.spawner) ~= spawner_key then
                store:finish(record, "spawner_unloaded")
                pending[spawner_key] = nil
            else
                local pawn = record.spawner.SpawnedAI
                if same_world(pawn) and key(pawn) ~= record.prior_pawn_key
                    and not retired[key(pawn)] and path(pawn:GetClass()) == record.target_path then
                    report.seen_poll = report.seen_poll + 1
                    finish(nil, record.spawner, pawn, "spawner_pawn_poll")
                end
            end
        end
        for _, record in pairs(waiting) do initialize(record) end
        for spawner_key, record in pairs(blocked) do
            if not valid(record.spawner) or key(record.spawner) ~= spawner_key then
                blocked[spawner_key] = nil
            end
        end
        for actor_key, actor in pairs(retired) do
            if not valid(actor) or key(actor) ~= actor_key then retired[actor_key] = nil end
        end
        local spawners = FindAllOf("AISpawner") or {}
        if enabled then
            warming = true
            local ok, err = pcall(function()
                local selected = {}
                for _, spawner in ipairs(spawners) do
                    if same_world(spawner) then
                        local reference = spawner.Class
                        local original_path = soft_path(reference)
                        local plan = options.resolve(spawner, reference, original_path)
                        if plan then
                            selected[key(spawner)] = {original_class = original_path, plan = plan}
                        end
                    end
                end
                warm(TARGETS[1])
                warm(TARGETS[2])
                for _, candidate in pairs(selected) do warm(candidate.original_class) end
                candidates = selected
            end)
            warming = false
            if not ok then fault("resource prewarming failed: " .. tostring(err)) end
        end
        for _, spawner in ipairs(spawners) do
            if same_world(spawner) then
                local function find_method(method)
                    local class = spawner:GetClass()
                    while valid(class) do
                        local candidate = path(class) .. ":" .. method
                        if valid(StaticFindObject(candidate)) then return candidate end
                        class = class:GetSuperStruct()
                    end
                end
                local getter = find_method("GetClassLoadConfigAndPolicy")
                if getter and not hooks[getter] and register(getter, function(context, _, output)
                    report.seen_getter = report.seen_getter + 1
                    replace(unwrap(context), output)
                end, false) then getter_count = getter_count + 1 end
                local ready = find_method("K2_OnAISpawnReady")
                if ready and not hooks[ready] then
                    register(ready, function(context, pawn)
                        report.seen_ready = report.seen_ready + 1
                        finish(context, context, pawn, "blueprint_ready_post")
                    end, false)
                end
                local despawn_path = find_method("Despawn")
                if despawn_path and not hooks[despawn_path] then
                    register(despawn_path, function(context)
                        report.seen_despawn = report.seen_despawn + 1
                        despawn(context)
                    end, false)
                end
            end
        end
    end
    function handle.lookup_actor(actor)
        if not valid(actor) then return end
        local entry = actors[actor:GetAddress()]
        if not entry then return end
        local spawner = actor.Spawner
        if valid(spawner) then
            local spawner_key = key(spawner)
            isolate_rebound(entry, actor, pending[spawner_key] or waiting[spawner_key])
        end
        if entry.loot_isolated then return end
        return store:lookup(actor_identity(actor, entry.record.replacement.spawn_token))
    end
    function handle.status()
        local result = {}
        for name, value in pairs(report) do result[name] = value end
        result.registered, result.pending, result.active, result.waiting, result.blocked = 0, 0, 0, 0, 0
        for _ in pairs(hooks) do result.registered = result.registered + 1 end
        for _ in pairs(pending) do result.pending = result.pending + 1 end
        for _ in pairs(actors) do result.active = result.active + 1 end
        for _ in pairs(waiting) do result.waiting = result.waiting + 1 end
        for _ in pairs(blocked) do result.blocked = result.blocked + 1 end
        result.prewarmed_classes = 0
        for class_path in pairs(resources) do
            if cached(class_path) then result.prewarmed_classes = result.prewarmed_classes + 1 end
        end
        result.ready = enabled and world_key ~= nil and getter_count > 0
        result.coverage = "observed_original_spawner_paths_only"
        return result
    end
    function handle.disable(reason)
        enabled = false
        report.disabled_reason = tostring(reason or "disabled")
        log(report.disabled_reason)
    end
    function handle.uninstall()
        enabled = false
        handle.reset(nil)
        for function_path, hook in pairs(hooks) do
            local ok, err = pcall(UnregisterHook, function_path, hook.pre, hook.post)
            if ok and err ~= false then hooks[function_path] = nil
            else fault("unregister failed " .. function_path .. ": " .. tostring(err)) end
        end
        return next(hooks) == nil
    end

    register(ASYNC, function(context, requested)
        report.seen_async = report.seen_async + 1
        replace(unwrap(context), requested)
    end, true)
    register(FINISH, function(context, spawner, pawn)
        report.seen_finish = report.seen_finish + 1
        finish(context, spawner, pawn, "native_finish_post")
    end, true, true)
    installed = handle
    return handle
end

return engine
