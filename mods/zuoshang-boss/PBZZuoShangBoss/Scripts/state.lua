-- Origins are spawn requests; there is no original Boss actor or hidden proxy.
-- Callers own UObject operations. Actor tokens are unique for the process lifetime.
local state = {}

local function text(value)
    return type(value) == "string" and value ~= ""
end

local function number(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function identity(actor)
    return type(actor) == "table" and number(actor.address) and actor.address > 0
        and text(actor.name) and text(actor.spawn_token)
end

local function copy(values)
    local result = {}
    for key, value in pairs(values) do
        result[key] = value
    end
    return result
end

local function slot(plan, spawner_instance_key)
    -- Length prefixes make arbitrary engine names unambiguous.
    local parts = {}
    for _, value in ipairs({ plan.encounter_id, plan.phase_id, plan.spawn_id, spawner_instance_key }) do
        parts[#parts + 1] = #value .. ":" .. value
    end
    return table.concat(parts)
end

function state.new()
    local self = {}
    local epoch, map_token = 0, nil
    local records, seen_origins, slots, actors, seen_actors, addresses = {}, {}, {}, {}, {}, {}

    local function current(record)
        return type(record) == "table" and record.epoch == epoch
            and records[record.origin_key] == record
            and (record.status == "pending" or record.status == "active")
    end

    function self:reset(next_map_token)
        local detached = {}
        for _, record in pairs(records) do
            if current(record) then
                detached[#detached + 1] = record
            end
        end
        -- Invalidate callbacks before the caller destroys any detached actors.
        epoch, map_token = epoch + 1, next_map_token
        records, seen_origins, slots, actors, seen_actors, addresses = {}, {}, {}, {}, {}, {}
        for _, record in ipairs(detached) do
            record.status = "retired"
        end
        return detached
    end

    function self:claim(plan, spawn_generation, spawner_instance_key)
        if not text(map_token) then
            return nil, "no_map"
        end
        if type(plan) ~= "table" or not text(plan.encounter_id) or not text(plan.phase_id)
            or not text(plan.spawn_id) or not text(plan.original_class)
            or (plan.target_phase ~= 1 and plan.target_phase ~= 2) then
            return nil, "invalid_plan"
        end
        if not number(spawn_generation) or spawn_generation < 1
            or spawn_generation % 1 ~= 0 then
            return nil, "invalid_spawn_generation"
        end
        if not text(spawner_instance_key) then
            return nil, "invalid_spawner_instance_key"
        end
        spawn_generation = math.floor(spawn_generation)
        local slot_key = slot(plan, spawner_instance_key)
        local key = epoch .. ":" .. #map_token .. ":" .. map_token
            .. slot_key .. ":" .. tostring(spawn_generation)
        if seen_origins[key] then
            return nil, "already_claimed_lifecycle"
        end
        if slots[slot_key] then
            return nil, "spawn_still_active"
        end
        local record = {
            epoch = epoch, map_token = map_token, status = "pending",
            origin_key = key, slot_key = slot_key,
            origin = { map_token = map_token, epoch = epoch,
                encounter_id = plan.encounter_id, phase_id = plan.phase_id,
                spawn_id = plan.spawn_id, spawn_generation = spawn_generation,
                spawner_instance_key = spawner_instance_key },
            plan = copy(plan),
            original_class = plan.original_class,
        }
        records[key], slots[slot_key], seen_origins[key] = record, record, true
        return record
    end

    function self:commit(record, replacement, metadata, reused_record)
        if not current(record) or record.status ~= "pending" then
            return false, "stale_or_committed_record"
        end
        if not identity(replacement) or seen_actors[replacement.spawn_token] then
            return false, "invalid_or_used_replacement_identity"
        end
        if reused_record ~= nil then
            if not current(reused_record) or reused_record.status ~= "active"
                or not reused_record.slot_released
                or reused_record.origin.spawner_instance_key ~= record.origin.spawner_instance_key
                or reused_record.original_class ~= record.original_class
                or reused_record.replacement.address ~= replacement.address
                or reused_record.replacement.name ~= replacement.name
                or addresses[replacement.address] ~= reused_record.replacement.spawn_token then
                return false, "invalid_reused_replacement"
            end
        elseif addresses[replacement.address] then
            return false, "invalid_or_used_replacement_identity"
        end
        local stats = type(metadata) == "table" and metadata.stats
        if type(stats) ~= "table" or not number(stats.health) or stats.health <= 0
            or not number(stats.max_health) or stats.max_health <= 0
            or not number(stats.base_attack) or stats.base_attack < 0
            or not number(metadata.loot_level) or metadata.loot_level < 0
            or (metadata.loot_id ~= nil and type(metadata.loot_id) ~= "string") then
            return false, "incomplete_original_metadata"
        end
        if reused_record and (metadata.loot_level ~= reused_record.loot_level
            or metadata.loot_id ~= reused_record.loot_id
            or metadata.difficulty ~= reused_record.difficulty
            or metadata.ng_cycle ~= reused_record.ng_cycle) then
            return false, "reused_reward_metadata_changed"
        end
        -- Validate everything before moving the pooled UObject to its new
        -- generation. Until this point its previous loot lookup stays active.
        local saved_stats, saved_identity = copy(stats), copy(replacement)
        if reused_record then self:finish(reused_record, "pooled_actor_reused") end
        record.loot_level, record.loot_id = metadata.loot_level, metadata.loot_id
        record.stats = saved_stats
        record.difficulty, record.ng_cycle = metadata.difficulty, metadata.ng_cycle
        record.replacement, record.status = saved_identity, "active"
        actors[replacement.spawn_token] = record
        addresses[replacement.address] = replacement.spawn_token
        seen_actors[replacement.spawn_token] = true
        return true
    end

    function self:release_slot(record)
        if not current(record) or record.status ~= "active" or slots[record.slot_key] ~= record then
            return false
        end
        slots[record.slot_key], record.slot_released = nil, true
        return true
    end

    function self:lookup(actor)
        if not identity(actor) then
            return nil
        end
        local found = actors[actor.spawn_token]
        if found and current(found) and found.replacement.address == actor.address
            and found.replacement.name == actor.name then
            return found
        end
    end

    function self:finish(record, reason)
        if not current(record) then
            return false
        end
        local actor = record.replacement
        if actor then
            actors[actor.spawn_token], addresses[actor.address] = nil, nil
        end
        if slots[record.slot_key] == record then slots[record.slot_key] = nil end
        record.status, record.finish_reason = "finished", reason
        -- Keep only the lifecycle tombstone, not old addresses.
        records[record.origin_key] = nil
        return true
    end

    return self
end

return state
