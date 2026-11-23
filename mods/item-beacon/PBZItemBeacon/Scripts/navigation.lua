-- Short, read-only navigation for one explicitly selected target.
-- Cache copied coordinates only; never retain a UNavigationPath or its array.
local M = {}
local state
local MAX_NODES, MAX_POINTS = 128, 16
local PREVIEW_CM, SPACING_CM, EPSILON = 2000, 150, 0.001
local EXTENT = {X = 150, Y = 150, Z = 100}

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function point(value)
    local x, y, z = value.X, value.Y, value.Z
    if not finite(x) or not finite(y) or not finite(z) then
        error("invalid navigation coordinate")
    end
    return {X = x, Y = y, Z = z}
end

local function distance(a, b)
    local length = math.sqrt((a.X-b.X)^2 + (a.Y-b.Y)^2 + (a.Z-b.Z)^2)
    if not finite(length) then error("invalid navigation distance") end
    return length
end

local function interpolate(a, b, t)
    return {X = a.X + (b.X-a.X)*t, Y = a.Y + (b.Y-a.Y)*t, Z = a.Z + (b.Z-a.Z)*t}
end

local function nearbyProjection(a, b)
    return (a.X-b.X)^2 + (a.Y-b.Y)^2 <= 150^2 and math.abs(a.Z-b.Z) <= 100
end

local function valid(object)
    return object ~= nil and object:IsValid()
end

local function identity(value)
    return type(value) == "string" or finite(value)
end

local function failedRoute(message)
    return {nodes = {}, status = message, partial = false, failed = true}
end

local function emptyResult(message)
    return {points = {}, status = message, partial = false}
end

local function query(world, pawn, start, goal)
    local library = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    local pathIsValid = StaticFindObject("/Script/NavigationSystem.NavigationPath:IsValid")
    if not valid(library) or not valid(pathIsValid) then
        return failedRoute("路线暂不可用")
    end
    local projected = {X = 0, Y = 0, Z = 0}
    if library:K2_ProjectPointToNavigation(world, goal, projected, nil, nil, EXTENT) ~= true then
        return failedRoute("目标附近无可用路线")
    end
    projected = point(projected)
    if not nearbyProjection(goal, projected) then
        return failedRoute("目标附近无可用路线")
    end
    local path = library:FindPathToLocationSynchronously(world, start, projected, pawn, nil)
    -- UObject:IsValid shadows the navigation UFunction of the same name.
    if not valid(path) or pathIsValid(path) ~= true then
        return failedRoute("暂无可用路线")
    end
    local partial = path:IsPartial()
    if type(partial) ~= "boolean" then error("invalid partial-path response") end
    local nodes, count, overflow = {}, 0, false
    path.PathPoints:ForEach(function(_, parameter)
        count = count + 1
        if count > MAX_NODES then overflow = true; return true end
        local value = point(parameter:get())
        if #nodes == 0 or distance(nodes[#nodes], value) > EPSILON then
            nodes[#nodes + 1] = value
        end
    end)
    if overflow then return failedRoute("路线节点过多") end
    if #nodes < 2 then return failedRoute("暂无可用路线") end
    if not nearbyProjection(start, nodes[1]) then
        return failedRoute("当前位置无可用路线")
    end
    if distance(nodes[#nodes], projected) > 200 then partial = true end
    return {
        nodes = nodes, partial = partial, failed = false,
        status = partial and "后续路线未确认" or "前方参考路线",
    }
end

local function preview(route, start)
    local nodes = route.nodes
    if #nodes < 2 then return emptyResult(route.status) end
    local closest, segment, closestDistance
    for index = 1, #nodes - 1 do
        local a, b = nodes[index], nodes[index + 1]
        local x, y, z = b.X-a.X, b.Y-a.Y, b.Z-a.Z
        local squared = x*x + y*y + z*z
        local t = ((start.X-a.X)*x + (start.Y-a.Y)*y + (start.Z-a.Z)*z) / squared
        local candidate = interpolate(a, b, math.max(0, math.min(1, t)))
        local d = distance(start, candidate)
        if not closestDistance or d < closestDistance then
            closest, segment, closestDistance = candidate, index, d
        end
    end
    if not nearbyProjection(start, closest) then
        return {points = {}, status = "路线更新中", partial = route.partial}
    end
    local remaining = distance(closest, nodes[segment + 1])
    for index = segment + 1, #nodes - 1 do
        remaining = remaining + distance(nodes[index], nodes[index + 1])
    end
    local points, position, budget = {point(closest)}, closest, PREVIEW_CM
    for index = segment + 1, #nodes do
        local destination = nodes[index]
        while budget > EPSILON and #points < MAX_POINTS do
            local length = distance(position, destination)
            if length <= EPSILON then break end
            local step = math.min(length, budget, SPACING_CM)
            position = interpolate(position, destination, step / length)
            points[#points + 1] = point(position)
            budget = budget - step
            if step >= length - EPSILON then break end
        end
        -- Keep bends, even when that means showing less than twenty meters.
        if budget <= EPSILON or #points >= MAX_POINTS then break end
    end
    return {
        points = points, status = route.status, partial = route.partial,
        remainingMeters = not route.partial and remaining / 100 or nil,
    }
end

function M.clear()
    state = nil
end

local function update(world, pawn, goalVector, targetIdentity, nowSeconds)
    if not finite(nowSeconds) or not identity(targetIdentity)
        or not valid(world) or not valid(pawn) then
        M.clear()
        return emptyResult("路线暂不可用")
    end
    local worldKey, pawnKey = world:GetAddress(), pawn:GetAddress()
    if not identity(worldKey) or not identity(pawnKey) then
        M.clear()
        return emptyResult("路线暂不可用")
    end
    local start, goal = point(pawn:GetNavAgentLocation()), point(goalVector)
    if not state or state.world ~= worldKey or state.pawn ~= pawnKey
        or state.target ~= targetIdentity or nowSeconds < state.lastQuery then
        state = {
            world = worldKey, pawn = pawnKey, target = targetIdentity,
            lastQuery = -math.huge,
        }
    end
    local due = not state.route
    if state.route then
        local elapsed = nowSeconds - state.lastQuery
        if state.route.failed or state.route.partial then
            due = elapsed >= 3
        else
            due = elapsed >= 1 and (distance(start, state.start) >= 200
                or distance(goal, state.goal) >= 50 or elapsed >= 10)
        end
    end
    if due then
        state.lastQuery, state.start, state.goal = nowSeconds, point(start), point(goal)
        local ok, route = pcall(query, world, pawn, start, goal)
        state.route = ok and route or failedRoute("路线暂不可用")
    end
    return preview(state.route, start)
end

function M.update(world, pawn, goalVector, targetIdentity, nowSeconds)
    local ok, result = pcall(update, world, pawn, goalVector, targetIdentity, nowSeconds)
    if ok then return result end
    M.clear()
    return emptyResult("路线暂不可用")
end

return M
