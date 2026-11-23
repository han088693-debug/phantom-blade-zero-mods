-- Read existing loot and loaded data tables only. Never roll loot to identify it.
local M = {}
local catalog, aliases, lootRows, seenTables = {}, {}, {}, {}
local pageSlots = {}
local refreshCount, revision = 0, 0
local currencyName
-- Verified in game: these are fragments; Item_001 / Item_002 are different items.
local fragmentIds = {"item_piece_001", "item_piece_002"}
local schemas = {
    PBZItemDataStruct = {"item", "ItemName"},
    WeaponData = {"weapon", "WeaponName", "武器"},
    ShaqiWeaponData = {"weapon", "WeaponName", "武器"},
    PBZMedicineDataStruct = {"medicine", "Name", "药品"},
    AccessoryData = {"accessory", "AccessoryName", "饰品"},
}
local order = {"养成道具", "钱", "药品", "武器", "饰品", "剧情道具",
    "食材", "珍宝", "记忆之花", "记忆花瓣", "书籍", "书页", "信件", "道具"}
local kindOrder = {}
for index, kind in ipairs(order) do kindOrder[kind] = index end

local function name(value)
    if value == nil then return "" end
    if type(value) == "string" then return value end
    return value:ToString()
end

local function normalized(value)
    return name(value):lower()
end

local function present(id)
    return id ~= "" and id ~= "none"
end

local function valid(value)
    local ok, result = pcall(function() return value and value:IsValid() end)
    return ok and result == true
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

local function classify(row)
    local material, detail, kind = row.MaterialType, row.ItemDetailType, row.ItemType
    if kind == 4 then return "记忆之花" end
    if kind == 5 then return "记忆花瓣" end
    if (material >= 1 and material <= 7) or detail == 1 or detail == 5 or detail == 6 then
        return "养成道具"
    end
    if kind == 1 then return "书籍" end
    if kind == 2 then return "书页" end
    if kind == 3 then return "信件" end
    if detail == 2 then return "剧情道具" end
    if detail == 3 then return "食材" end
    if detail == 4 then return "珍宝" end
    return "道具"
end

local function saveRow(spec, rowName, row, manager)
    local family = spec[1]
    local rowId, id = normalized(rowName), normalized(row.ItemId)
    if not present(id) then id = rowId end
    if not present(id) then return true end
    catalog[family], aliases[family] = catalog[family] or {}, aliases[family] or {}
    local previous = catalog[family][id]
    local text = localized(row[spec[2]], manager)
    local retryPrimary = not text and family == "item" and (row.ItemType == 2 or row.ItemType == 5)
    if retryPrimary then
        text = localized(row.Subhead, manager)
    end
    local category = spec[3] or classify(row)
    local itemType = family == "item" and row.ItemType or nil
    local bookId = itemType == 2 and normalized(row.IntegrationItemID) or nil
    local pageIndex = itemType == 2 and row.SequentialIndex or nil
    if type(pageIndex) ~= "number" or pageIndex <= 0 or pageIndex % 1 ~= 0 then pageIndex = nil end
    if not text and previous then text = previous.name end
    if not previous or previous.name ~= text or previous.kind ~= category
        or previous.itemType ~= itemType or previous.bookId ~= bookId or previous.pageIndex ~= pageIndex then
        catalog[family][id] = {id = id, name = text, kind = category,
            itemType = itemType, bookId = bookId, pageIndex = pageIndex}
        revision = revision + 1
    end
    for _, alias in ipairs({id, rowId}) do
        if present(alias) and aliases[family][alias] ~= id then
            aliases[family][alias] = id
            revision = revision + 1
        end
    end
    -- Keep retrying the primary name after using a page or memory-petal title.
    return text ~= nil and not retryPrimary
end

local function lootEntries(array, family, idField, maxField)
    local result = {}
    array:ForEach(function(_, parameter)
        local row = parameter:get()
        local id = idField and normalized(row[idField]) or "dust"
        if row.Probability > 0 and (not maxField or row[maxField] > 0) and present(id) then
            result[#result + 1] = {family = family, id = id}
        end
    end)
    return result
end

local function snapshotLoot(row)
    local content = {}
    row.EntryDatas:ForEach(function(_, parameter)
        local level = parameter:get()
        local groups = {
            lootEntries(level.LootDusts, "currency", nil, "MaxDust"),
            lootEntries(level.LootItems, "item", "ItemId", "MaxAmount"),
            lootEntries(level.Weapons, "weapon", "WeaponID"),
            lootEntries(level.Medicines, "medicine", "MedicineID"),
            lootEntries(level.Accessories, "accessory", "AccessoryID"),
        }
        for _, group in ipairs(groups) do
            for _, entry in ipairs(group) do content[#content + 1] = entry end
        end
    end)
    return content
end

function M.reset()
    catalog, aliases, lootRows, seenTables = {}, {}, {}, {}
    pageSlots = {}
    currencyName = nil
    refreshCount = 0
    revision = revision + 1
end

function M.revision()
    return revision
end

function M.refresh()
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
            local kind, complete = name(schema:GetFName()), true
            local spec = schemas[kind]
            if spec then
                dt:ForEachRow(function(rowName, row)
                    local ok, resolved = pcall(saveRow, spec, rowName, row, manager)
                    if not ok or not resolved then complete = false end
                end)
            elseif kind == "LevelLootTableData" then
                dt:ForEachRow(function(rowName, row)
                    local data = snapshotLoot(row)
                    lootRows[normalized(rowName)] = data
                    local id = normalized(row.LootItemID)
                    if present(id) then lootRows[id] = data end
                    revision = revision + 1
                end)
            end
            -- Unresolved names retry; only plain Lua values survive this call.
            seenTables[key] = complete
        end)
    end
    -- A duplicate position cannot reliably name either page. Keep its original title.
    pageSlots = {}
    for id, row in pairs(catalog.item or {}) do
        if row.bookId and present(row.bookId) and row.pageIndex then
            local slots = pageSlots[row.bookId] or {}
            if slots[row.pageIndex] == nil then slots[row.pageIndex] = id
            else slots[row.pageIndex] = false end
            pageSlots[row.bookId] = slots
        end
    end
    if not currencyName then
        for _, data in ipairs(FindAllOf("InventoryData") or {}) do
            if valid(data) then
                local ok, text = pcall(function() return localized(data.DustText, manager) end)
                if ok and text then
                    currencyName = text
                    revision = revision + 1
                    break
                end
            end
        end
    end
end

local defaultKinds = {item = "道具", weapon = "武器", medicine = "药品",
    accessory = "饰品", currency = "钱", flower = "记忆之花"}

local function add(found, family, value, forcedKind)
    local id = normalized(value)
    if not present(id) then return end
    id = aliases[family] and aliases[family][id] or id
    local key = family .. ":" .. id
    if found[key] then return end
    local row = catalog[family] and catalog[family][id]
    local text, bookName, pageIndex = row and row.name
    if family == "item" and row and row.itemType == 2 and row.pageIndex then
        local book = catalog.item[row.bookId]
        local slots = pageSlots[row.bookId]
        if book and book.itemType == 1 and book.name and slots and slots[row.pageIndex] == id then
            bookName, pageIndex = book.name, row.pageIndex
            text = "《" .. bookName .. "》第" .. string.format("%d", pageIndex) .. "页"
        end
    end
    found[key] = {key = key, family = family, id = id,
        name = family == "currency" and currencyName or text, bookName = bookName, pageIndex = pageIndex,
        kind = forcedKind or row and row.kind or defaultKinds[family], possible = false}
end

local function resolvedLoot(actor, kind)
    local found = {}
    if kind == "flower" then
        local id = normalized(actor.FlowerItem)
        if present(id) then
            add(found, "item", id, "记忆之花")
        else
            add(found, "flower", "unknown", "记忆之花")
        end
    elseif kind == "pickup" then
        add(found, "item", actor.ItemId)
    elseif kind == "rubbish" or kind == "chest" then
        if actor["Get Dust"] > 0 then add(found, "currency", "dust") end
        actor[kind == "chest" and "PickupMaps" or "PickupMap"]:ForEach(function(k, v)
            if v:get() > 0 then add(found, "item", k:get()) end
        end)
        -- Table-mode containers can retain obsolete editor Pickups after resolving loot.
        if actor.UseLegacyType ~= false or not next(found) then
            actor.Pickups:ForEach(function(_, value)
                local pickup = value:get()
                if pickup.Amount_5_93BDB8B545F957E43232B49EA76A6DFE > 0 then
                    add(found, "item", pickup.ItemID_3_AA0CF7F84C2C8B7CDA8E3D8BF2772009)
                end
            end)
        end
        actor.GetWeapons:ForEach(function(k) add(found, "weapon", k:get()) end)
        actor.Medicines:ForEach(function(value) add(found, "medicine", value:get()) end)
        actor.Accessories:ForEach(function(value) add(found, "accessory", value:get()) end)
        if not next(found) and kind == "rubbish" and actor.UseLegacyType then
            add(found, "item", actor["Item ID"])
        end
    end
    return found
end

function M.fragmentReady()
    for _, id in ipairs(fragmentIds) do
        local row = catalog.item and catalog.item[id]
        if not row or not row.name then return false end
    end
    return true
end

local function fragmentRank(entry)
    for rank, id in ipairs(fragmentIds) do
        if entry.key == "item:" .. id then return rank end
    end
    return 3
end

local function clip(text, limit)
    if limit <= 0 then return "" end
    if utf8.len(text) <= limit then return text end
    if limit == 1 then return "…" end
    return text:sub(1, utf8.offset(text, limit) - 1) .. "…"
end

local function entryText(entry, limit)
    if entry.bookName then
        local page = "第" .. string.format("%d", entry.pageIndex) .. "页"
        local titleLimit = limit - utf8.len(page) - 2
        if titleLimit >= 1 then return "《" .. clip(entry.bookName, titleLimit) .. "》" .. page end
        if utf8.len(page) <= limit then return page end
        page = string.format("%d页", entry.pageIndex)
        if utf8.len(page) <= limit then return page end
        return clip("…", limit)
    end
    return clip(entry.name or "名称待识别", limit)
end

function M.summary(description, maxChars)
    local limit = math.max(0, math.floor(maxChars or 24))
    local entries = description.entries or {}
    local prefix = ""
    if description.possible then prefix = prefix .. "可能：" end
    if #entries == 0 then return clip(prefix .. "名称待识别", limit) end
    local suffix = #entries > 2 and ("+另" .. tostring(#entries - 2) .. "种") or ""
    local budget = limit - utf8.len(prefix) - utf8.len(suffix)
    local first = entries[1].name or "名称待识别"
    local body
    if #entries > 1 and budget >= 3 then
        local second = entries[2].name or "名称待识别"
        local firstLimit = math.min(utf8.len(first), math.max(1, math.ceil((budget - 1) / 2)))
        local secondLimit = budget - firstLimit - 1
        if utf8.len(second) < secondLimit then
            firstLimit = math.min(utf8.len(first), budget - 1 - utf8.len(second))
            secondLimit = budget - firstLimit - 1
        end
        local firstMinimum = entries[1].bookName and utf8.len(string.format("第%d页", entries[1].pageIndex)) or 1
        local secondMinimum = entries[2].bookName and utf8.len(string.format("第%d页", entries[2].pageIndex)) or 1
        if budget - 1 >= firstMinimum + secondMinimum then
            firstLimit = math.max(firstMinimum, math.min(firstLimit, budget - 1 - secondMinimum))
            secondLimit = budget - firstLimit - 1
        end
        body = entryText(entries[1], firstLimit) .. "+" .. entryText(entries[2], secondLimit)
    else
        body = entryText(entries[1], math.max(0, budget))
    end
    return clip(prefix .. body .. suffix, limit)
end

function M.describe(actor, kind)
    local found = resolvedLoot(actor, kind)
    local possible = false
    if not next(found) and kind ~= "pickup" and kind ~= "flower" then
        local id = normalized(kind == "flow" and actor.LootItemID or actor["Loot Item ID"])
        local content = lootRows[id]
        if content then
            -- The union is only possible loot; do not predict a level or roll.
            for _, entry in ipairs(content) do add(found, entry.family, entry.id) end
            possible = next(found) ~= nil
        end
    end
    local description = {entries = {}, kinds = {}, possible = possible, chest = kind == "chest"}
    for _, entry in pairs(found) do
        entry.possible = possible
        description.entries[#description.entries + 1] = entry
        description.kinds[entry.kind] = true
        if fragmentRank(entry) < 3 then description.kinds["碎片"] = true end
    end
    table.sort(description.entries, function(a, b)
        local ar, br = fragmentRank(a), fragmentRank(b)
        if ar ~= br then return ar < br end
        ar, br = kindOrder[a.kind] or 99, kindOrder[b.kind] or 99
        if ar ~= br then return ar < br end
        return a.key < b.key
    end)
    if not next(description.kinds) then description.kinds["道具"] = true end
    description.label = M.summary(description)
    return description
end

function M.label(actor, kind)
    return M.describe(actor, kind).label
end

return M
