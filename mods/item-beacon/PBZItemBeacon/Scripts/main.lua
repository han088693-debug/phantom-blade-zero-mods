-- PBZ Item Beacon 1.9.0
-- SDK basis: Steam build 26266538 / CL-301524_JKS-17219.
-- Read-only loot/navigation queries; only temporary overlay drawing is added.
local Config = require("config")
local UEHelpers = require("UEHelpers")
local Categories = require("categories")
local Bells = require("bells")
local ChineseFont = require("chinese_font")
local Navigation = require("navigation")
local Overlay = require("overlay")
local routeOn = Config.RouteEnabled == true
local hideOthers = Config.RouteOnlyTarget ~= false
local listOpen, listRefresh, listRows, listIndex = false, false, {}, 1
local listWaitingForNames = false
local settingsOpen, settingsIndex = false, 1
local target, elapsed = nil, 0
local enabled = Config.Enabled
local rangeIndex = Config.DefaultRangeIndex
local filterIndex = Config.DefaultFilterIndex or 1
local focusIndex = Config.DefaultFocusIndex or 1
local showHeight = Config.ShowHeightDifference == true
local showMemoryFlowers = Config.ShowMemoryFlowers ~= false
local filterNames = {"全部", "隐藏纯钱", "养成道具", "宝箱", "钱", "书籍收藏", "记忆之花", "碎片", "未激活铃铛"}
local focusNames = {"关闭", "最近3个", "最近1个"}
local focusLimits = {Config.MaxMarkers, 3, 1}
local statusPawn, statusText, statusTicks = nil, "", 0
local candidates, marked = {}, {}
local previousHUD, worldKey, pawnKey = nil, nil, nil
local ticks = 0
local reportedErrors = {}
local lastCount = -1
local subsystemLibrary, uiRouterClass

local types = {
    -- Scan the specialized subclass first so the shared flow scan cannot claim it.
    {class = "BP_FlowInteract_MemoryFlower_C", kind = "flower", label = "记忆之花"},
    {class = "BP_Rubbish_C", kind = "rubbish", label = "道具"},
    {class = "BP_Chest_C", kind = "chest", label = "宝箱"},
    {class = "BP_FlowInteractActor_C", kind = "flow", label = "道具"},
    {class = "PBZPickupActor", kind = "pickup", label = "道具"},
    {class = "MelodiousBell", kind = "bell", label = "未激活铃铛"},
}

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function reportOnce(key, message)
    if not reportedErrors[key] then
        reportedErrors[key] = true
        print("[PBZItemBeacon] " .. key .. ": " .. tostring(message) .. "\n")
    end
end

local function clearMarkers(keepOverlay)
    if not keepOverlay then Overlay.clear() end
    if valid(previousHUD) then
        for _, actor in pairs(marked) do
            if valid(actor) then
                pcall(function() previousHUD:RemoveDebugText(actor, false) end)
            end
        end
    end
    if valid(previousHUD) and valid(statusPawn) then
        pcall(function() previousHUD:RemoveDebugText(statusPawn, false) end)
    end
    marked, statusPawn, statusTicks = {}, nil, 0
end

local function modeChanged()
    listRefresh = true
    clearMarkers(true)
    ticks = 0
    statusText = "类型：" .. filterNames[filterIndex]
        .. " | 高差：" .. (showHeight and "开" or "关")
        .. " | 专注：" .. focusNames[focusIndex]
        .. " | 记忆之花：" .. (showMemoryFlowers and "开" or "关")
    statusTicks = 12
    print("[PBZItemBeacon] " .. statusText .. "\n")
end

local function menuOpen(pc)
    if not valid(subsystemLibrary) then
        subsystemLibrary = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
    end
    if not valid(uiRouterClass) then
        uiRouterClass = StaticFindObject("/Script/ProjectPBZ.PBZUIActionRouterBase")
    end
    if not valid(subsystemLibrary) or not valid(uiRouterClass) then return false end
    local router = subsystemLibrary:GetLocalPlayerSubSystemFromPlayerController(pc, uiRouterClass)
    return valid(router) and router:IsMenuInputModeUI() == true
end

local function available(actor, kind, pawn)
    if not valid(actor) or actor:IsActorBeingDestroyed() or actor.bHidden then
        return false
    end
    if kind == "bell" then
        return Bells.available(actor)
    elseif kind == "pickup" then
        return actor.bIsPickable == true
    elseif kind == "flower" then
        -- Flowers use their own completion state, not generic loot particles.
        if actor.HasDestory ~= false then return false end
    elseif kind == "rubbish" then
        if actor.bDestroyed ~= false or actor["Not Interact"] ~= false
            or actor.CurSwitchState ~= false then
            return false
        end
    elseif kind == "chest" then
        -- The completed/open state is true. Do not use bInteracted: it is an array.
        if actor.CurSwitchState ~= false then return false end
    elseif kind == "flow" then
        -- Flow actors also represent doors, conversations and mechanisms.
        -- Require a real loot ID and the game's own remaining loot effect.
        -- IsActive is intentionally not checked: the engine culls distant effects.
        if actor.LootItemID:ToString() == "None" or not valid(actor.Niagara)
            or not valid(actor.Niagara.Asset) then
            return false
        end
    end
    return actor:IsValidInteract(pawn) == true
end

local function scan(world, pawn)
    local ok, err = pcall(Categories.refresh)
    if not ok then reportOnce("categories", err) end
    ok, err = pcall(Bells.refresh, pawn)
    if not ok then reportOnce("bells", err) end
    ok, err = pcall(ChineseFont.refresh)
    if not ok then reportOnce("font", err) end
    local found, seen = {}, {}
    for _, definition in ipairs(types) do
        local actors = FindAllOf(definition.class) or {}
        for _, actor in ipairs(actors) do
            if valid(actor) then
                -- UE4SS GetWorld follows the outer chain; streamed cells have
                -- separate outer worlds. OwningWorld is the active play world.
                local level = actor:GetLevel()
                local actorWorld = valid(level) and level.OwningWorld or nil
                if valid(actorWorld) and actorWorld:GetAddress() == world then
                    local key = actor:GetFullName()
                    if not seen[key] and not key:find("Default__", 1, true) then
                        seen[key] = true
                        found[#found + 1] = {
                            actor = actor, key = key, address = actor:GetAddress(),
                            kind = definition.kind, label = definition.label,
                        }
                    end
                end
            end
        end
    end
    candidates = found
    -- A locked actor can resolve its loot after selection without changing identity.
    if target then target.description = nil end
end

local function describeCandidate(candidate)
    local revision = Categories.revision()
    if candidate.kind == "bell" or not candidate.description or candidate.descriptionRevision ~= revision then
        local reader = candidate.kind == "bell" and Bells.describe or Categories.describe
        local ok, description = pcall(reader, candidate.actor, candidate.kind)
        if ok then
            candidate.description = description
        else
            reportOnce("category", description)
            candidate.description = {label = "名称待识别", kinds = {["道具"] = true},
                entries = {}, possible = false}
        end
        candidate.descriptionRevision = revision
    end
    return candidate.description
end

local function isMemoryFlower(candidate)
    local kinds = describeCandidate(candidate).kinds
    return kinds["记忆之花"] == true or kinds["记忆花瓣"] == true
end

local function matchesFilter(candidate)
    if filterIndex == 9 then return candidate.kind == "bell" end
    if candidate.kind == "bell" then return filterIndex == 2 end
    if filterIndex == 8 then return describeCandidate(candidate).kinds["碎片"] == true end
    if filterIndex == 7 then return isMemoryFlower(candidate) end
    if filterIndex == 4 then return candidate.kind == "chest" end
    local description = describeCandidate(candidate)
    local kinds = description.kinds
    if filterIndex == 6 then
        return kinds["书籍"] == true or kinds["书页"] == true or kinds["信件"] == true
    end
    -- Keep unresolved/unknown drops visible rather than hiding possible loot.
    if description.possible or kinds["道具"] then return true end
    if filterIndex == 2 then
        if candidate.kind == "chest" or not kinds["钱"] then return true end
        for kind in pairs(kinds) do if kind ~= "钱" then return true end end
        return false
    end
    return kinds[filterIndex == 3 and "养成道具" or "钱"] == true
end

local function identity(candidate)
    return candidate.key .. "@" .. tostring(candidate.address)
end

local function listIdentity(candidate)
    local id = candidate.kind == "bell" and Bells.id(candidate.actor) or nil
    return id and ("bell:" .. id) or identity(candidate)
end

local function suspendNavigation(cancelTarget)
    settingsOpen, settingsIndex = false, 1
    listOpen, listRows, listIndex = false, {}, 1
    listWaitingForNames = false
    Navigation.clear()
    Overlay.clear()
    if cancelTarget then target = nil end
end

local function notice(text)
    statusText, statusTicks = text, 12
    print("[PBZItemBeacon] " .. text .. "\n")
end

local function measure(candidate, origin, pawn)
    local actor = candidate.actor
    if not valid(actor) or actor:GetAddress() ~= candidate.address
        or not available(actor, candidate.kind, pawn) then return nil end
    local p = actor:K2_GetActorLocation()
    return {candidate = candidate, position = {X=p.X,Y=p.Y,Z=p.Z},
        distance = math.sqrt((p.X-origin.X)^2+(p.Y-origin.Y)^2+(p.Z-origin.Z)^2)/100,
        height = (p.Z-origin.Z)/100}
end

local function itemText(item, height)
    local suffix = string.format(" %d m", math.floor(item.distance + 0.5))
    if height and math.abs(item.height) >= (Config.HeightDifferenceMinMeters or 2) then
        suffix = suffix .. string.format(" %s%d m", item.height > 0 and "↑" or "↓",
            math.floor(math.abs(item.height) + 0.5))
    end
    -- Reserve distance/height before shortening names, so overlay clipping cannot erase them.
    local budget = math.max(1, 31 - 2 - utf8.len(suffix))
    return "[" .. Categories.summary(describeCandidate(item.candidate), budget) .. "]" .. suffix
end

local function refreshList(nearby)
    if listWaitingForNames and Categories.fragmentReady() then
        if #listRows == 0 then listRefresh = true end
        listWaitingForNames = false
    end
    local selected = listRows[listIndex]
    local key = selected and listIdentity(selected.candidate)
    if listRefresh then
        listRows, listRefresh = nearby, false
        key = target and listIdentity(target)
        listIndex = #listRows > 0 and 1 or 0
    else
        local current, kept = {}, {}
        for _, item in ipairs(nearby) do current[listIdentity(item.candidate)] = item end
        for _, item in ipairs(listRows) do
            local fresh = current[listIdentity(item.candidate)]
            if fresh then kept[#kept+1] = fresh end
        end
        listRows = kept
    end
    listIndex = math.max(0, math.min(listIndex, #listRows))
    for i, item in ipairs(listRows) do
        if listIdentity(item.candidate) == key then listIndex = i; break end
    end
end

local function settingsRows()
    local function onOff(value) return value and "开" or "关" end
    return {
        {id="items", text=enabled and "选择物品" or "选择物品（提示已关）"},
        {id="route", text="地面路线：" .. onOff(routeOn)},
        {id="cancel", text=target and "取消当前目标" or "取消当前目标（无）"},
        {id="enabled", text="全部提示：" .. onOff(enabled)},
        {id="filter", text="物品类型：" .. filterNames[filterIndex]},
        {id="range", text="提示范围：" .. Config.RangesMeters[rangeIndex] .. " 米"},
        {id="focus", text="显示数量：" .. (focusIndex == 1 and "最多" .. Config.MaxMarkers .. "个" or focusNames[focusIndex])},
        {id="height", text="高差提示：" .. onOff(showHeight)},
        {id="flowers", text="记忆之花：" .. onOff(showMemoryFlowers)},
        {id="onlyTarget", text="导航时只显示目标：" .. onOff(hideOthers)},
    }
end

local function settingIndex(id)
    for index, row in ipairs(settingsRows()) do
        if row.id == id then return index end
    end
end

local function emptyListMessage()
    if filterIndex == 8 and not Categories.fragmentReady() then
        return "名称数据尚未就绪，请稍后再试"
    end
    return "当前已加载范围内未发现符合筛选的目标"
end

Overlay.init(menuOpen, reportOnce)

local function update()
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) then clearMarkers(); suspendNavigation(true); return end
    local pawn, hud, world = pc.Pawn, pc:GetHUD(), pc:GetWorld()
    if not valid(pawn) or not valid(hud) or not valid(world) then
        clearMarkers()
        candidates, worldKey, pawnKey = {}, nil, nil
        suspendNavigation(true)
        return
    end
    local newWorld = world:GetAddress()
    if newWorld ~= worldKey or pawn:GetAddress() ~= pawnKey or not valid(previousHUD)
        or previousHUD:GetAddress() ~= hud:GetAddress() then
        clearMarkers()
        candidates, worldKey, pawnKey, previousHUD, ticks = {}, newWorld, pawn:GetAddress(), hud, 0
        Categories.reset()
        Bells.reset()
        suspendNavigation(true)
    end
    -- Engine-thread timers still run while the game is paused; clear the text
    -- explicitly because a paused HUD does not age duration-based text.
    -- Bell travel opens a menu without pausing or hiding AHUD. Read the current
    -- local player's UI mode; cached map widgets can remain alive after closing.
    if pc:IsPaused() or not hud.bShowHUD or menuOpen(pc) then
        clearMarkers(); suspendNavigation(false); return
    end
    if not enabled then
        -- The settings panel stays open; do not erase it between display ticks.
        clearMarkers(true)
        target, listOpen, listRows = nil, false, {}
        Navigation.clear()
        Overlay.set({hud=hud, pc=pc, font=ChineseFont.get(), listOpen=settingsOpen,
            title="道具助手", rows=settingsRows(), cursor=settingsIndex, routeOn=false})
        return
    end
    if ticks % 4 == 0 then scan(newWorld, pawn) end
    ticks = ticks + 1
    local origin = pawn:K2_GetActorLocation()
    local nearby = {}
    local maxDistance = Config.RangesMeters[rangeIndex]
    for _, candidate in ipairs(candidates) do
        local ok, item = pcall(measure, candidate, origin, pawn)
        if not ok then
            reportOnce(candidate.kind, item)
        elseif item and item.distance <= maxDistance
            and (showMemoryFlowers or not isMemoryFlower(candidate))
            and (filterIndex == 1 or matchesFilter(candidate)) then
            nearby[#nearby + 1] = item
        end
    end
    table.sort(nearby, function(a, b)
        if a.distance == b.distance then return a.candidate.key < b.candidate.key end
        return a.distance < b.distance
    end)
    -- Streamed instances can share a bell ID. Keep its nearest eligible instance.
    local unique, bellIds = {}, {}
    for _, item in ipairs(nearby) do
        local id = item.candidate.kind == "bell" and Bells.id(item.candidate.actor) or nil
        if not id or not bellIds[id] then
            unique[#unique + 1] = item
            if id then bellIds[id] = true end
        end
    end
    nearby = unique
    local targetItem
    if target then
        local ok, item = pcall(measure, target, origin, pawn)
        if ok then targetItem = item end
        if not targetItem then
            local wasBell = target.kind == "bell"
            target = nil
            Navigation.clear()
            notice(wasBell and "铃铛已激活或目标已失效" or "目标已失效或已收集")
        end
    end
    if listOpen then refreshList(nearby) end
    local preview = listOpen and listRows[listIndex] or nil
    local route = {points = {}, status = "路线已关闭 · F5 面板开启"}
    if targetItem and routeOn then
        route = Navigation.update(world, pawn, targetItem.position, identity(target), elapsed)
    end
    local rows = {{text = "返回设置"}}
    for _, item in ipairs(listRows) do rows[#rows+1] = {text = itemText(item, true)} end
    Overlay.set({hud=hud, pc=pc, font=ChineseFont.get(), listOpen=settingsOpen or listOpen,
        title=settingsOpen and "道具助手" or "选择物品",
        rows=settingsOpen and settingsRows() or rows,
        cursor=settingsOpen and settingsIndex or listIndex+1,
        emptyMessage=listOpen and #listRows==0 and emptyListMessage() or nil,
        routeOn=routeOn,
        targetText=targetItem and itemText(targetItem, true) or nil,
        status=route.status,
        points=routeOn and Overlay.visiblePoints(pc,pawn,route.points) or {}})
    local shown, seen = {}, {}
    local function addItem(item)
        if not item then return end
        local bellId = item.candidate.kind == "bell" and Bells.id(item.candidate.actor) or nil
        local key = bellId and ("bell:" .. bellId) or identity(item.candidate)
        if not seen[key] and #shown < Config.MaxMarkers then
            seen[key] = true
            shown[#shown+1] = item
        end
    end
    -- Keep world labels from covering the panel; the item page retains one preview.
    if listOpen then
        addItem(preview)
    elseif not settingsOpen then
        addItem(targetItem)
        if not (routeOn and targetItem and hideOthers) then
            for i=1,math.min(#nearby, Config.MaxMarkers, focusLimits[focusIndex]) do addItem(nearby[i]) end
        end
    end
    local nextMarked = {}
    local count = #shown
    local offset = {X = 0, Y = 0, Z = Config.HeightOffsetCm}
    for _, item in ipairs(shown) do
        local candidate = item.candidate
        local text = itemText(item, showHeight)
        local color = candidate.kind == "chest" and Config.ChestColor or Config.ItemColor
        if preview and identity(candidate) == identity(preview.candidate) then
            text = "【选择】" .. text
            color = {R=120,G=255,B=255,A=255}
        elseif target and identity(candidate) == identity(target) then
            text = "【目标】" .. text
            color = {R=255,G=255,B=160,A=255}
        end
        hud:AddDebugText(text, candidate.actor, 0.75, offset, offset, color,
            false, false, true, ChineseFont.get(), Config.FontScale, true)
        nextMarked[candidate.key] = candidate.actor
    end
    for key, actor in pairs(marked) do
        if not nextMarked[key] and valid(actor) then hud:RemoveDebugText(actor, false) end
    end
    marked = nextMarked
    if statusTicks > 0 then
        if valid(statusPawn) and statusPawn:GetAddress() ~= pawn:GetAddress() then
            hud:RemoveDebugText(statusPawn, false)
        end
        local statusOffset = {X = 0, Y = 0, Z = 130}
        hud:AddDebugText(statusText, pawn, 0.75, statusOffset, statusOffset,
            {R = 255, G = 255, B = 255, A = 255}, false, false, true,
            ChineseFont.get(), 1.1, true)
        statusPawn = pawn
        statusTicks = statusTicks - 1
    elseif valid(statusPawn) then
        hud:RemoveDebugText(statusPawn, false)
        statusPawn = nil
    end
    if count ~= lastCount then
        print(string.format("[PBZItemBeacon] markers=%d range=%d m\n", count, Config.RangesMeters[rangeIndex]))
        lastCount = count
    end
end

local function interaction(callback)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc = UEHelpers.GetPlayerController()
            if not valid(pc) or not valid(pc.Pawn) or not valid(pc:GetHUD())
                or pc:IsPaused() or not pc:GetHUD().bShowHUD or menuOpen(pc) then return end
            -- Synchronize lifecycle before opening a panel, including when labels are disabled.
            update()
            callback()
            update()
        end)
        if not ok then clearMarkers(); suspendNavigation(false); reportOnce("selection", err) end
    end)
end

RegisterKeyBind(Key.F5, function()
    interaction(function()
        if settingsOpen or listOpen then
            settingsOpen, listOpen = false, false
        else
            settingsOpen, settingsIndex = true, 1
            local ok, err = pcall(ChineseFont.refresh)
            if not ok then reportOnce("font", err) end
        end
    end)
end)
RegisterKeyBind(Key.PAGE_UP, function()
    if not settingsOpen and not listOpen then return end
    interaction(function()
        if settingsOpen then
            settingsIndex = (settingsIndex-2) % #settingsRows() + 1
        elseif listOpen then
            listIndex = (listIndex-1) % (#listRows+1)
        end
    end)
end)
RegisterKeyBind(Key.PAGE_DOWN, function()
    if not settingsOpen and not listOpen then return end
    interaction(function()
        if settingsOpen then
            settingsIndex = settingsIndex % #settingsRows() + 1
        elseif listOpen then
            listIndex = (listIndex+1) % (#listRows+1)
        end
    end)
end)
RegisterKeyBind(Key.RETURN, function()
    if not settingsOpen and not listOpen then return end
    -- Keep the identity at keypress time; refresh may remove the highlighted row.
    local chosen = listOpen and listRows[listIndex] or nil
    local goBack = listOpen and listIndex == 0
    interaction(function()
        if listOpen then
            if goBack then
                listOpen, settingsOpen, settingsIndex = false, true, 1
                return
            end
            if chosen then
                for _, item in ipairs(listRows) do
                    if identity(item.candidate) == identity(chosen.candidate) then
                        target, listOpen = item.candidate, false
                        Navigation.clear()
                        notice(routeOn and "目标已锁定" or "目标已锁定 · F5 面板开启路线")
                        return
                    end
                end
                notice("物品已失效，请重新选择")
            end
            return
        end
        if not settingsOpen then return end
        local action = settingsRows()[settingsIndex].id
        if action == "items" then
            if not enabled then settingsIndex = settingIndex("enabled"); return end
            settingsOpen, listOpen, listRefresh, listIndex = false, true, true, 1
            listWaitingForNames = filterIndex == 8 and not Categories.fragmentReady()
        elseif action == "route" then
            routeOn = not routeOn
            Navigation.clear()
            notice(routeOn and (target and "路线已开启" or "路线已开启 · 请选择物品") or "路线已关闭")
        elseif action == "cancel" then
            target = nil
            Navigation.clear()
            notice("已取消目标")
        elseif action == "enabled" then
            enabled = not enabled
            ticks = 0
            if not enabled then
                clearMarkers(true)
                target, listRows = nil, {}
                Navigation.clear()
            end
            print("[PBZItemBeacon] " .. (enabled and "ON" or "OFF") .. "\n")
        elseif action == "filter" then
            filterIndex = filterIndex % #filterNames + 1
            modeChanged()
        elseif action == "range" then
            rangeIndex = rangeIndex % #Config.RangesMeters + 1
            listRefresh, ticks = true, 0
            clearMarkers(true)
        elseif action == "focus" then
            focusIndex = focusIndex % #focusNames + 1
            modeChanged()
        elseif action == "height" then
            showHeight = not showHeight
            modeChanged()
        elseif action == "flowers" then
            showMemoryFlowers = not showMemoryFlowers
            modeChanged()
        elseif action == "onlyTarget" then
            hideOthers = not hideOthers
        end
    end)
end)

LoopInGameThreadWithDelay(250, function()
    elapsed = elapsed + 0.25
    local ok, err = pcall(update)
    if not ok then
        clearMarkers()
        suspendNavigation(false)
        reportOnce("update", err)
    end
    return false
end)

print("[PBZItemBeacon] 1.9.0 loaded | F5 panel | PgUp/PgDn select | Enter confirm\n")
