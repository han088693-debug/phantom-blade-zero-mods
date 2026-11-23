-- Persistent screen-space text; short-lived world-space route points.
-- The 33 ms display loop never scans actors, queries paths, or traces physics.
local M = {}
local state, pawnAddress, worldAddress, previousHUD, timerId
local menuOpen, reportOnce, kismet
local uiRoot, uiText, viewportSubsystem, rootLibrary, lastLabel, lastFont, lastSize
local clearingUI, shutdownPending = false, false
local gold = {SpecifiedColor={R=1,G=0.82,B=0.44,A=1},ColorUseRule=0}
local blue = {R=115,G=220,B=255,A=255}
local transparent = {R=0,G=0,B=0,A=0}
local function valid(object) return object ~= nil and object:IsValid() end
local function report(key,err)
    if reportOnce then pcall(reportOnce,key,tostring(err)) end
end
local function clearText()
    if valid(previousHUD) then
        pcall(function() previousHUD:RemoveDebugText(previousHUD,false) end)
    end
    previousHUD=nil
    if valid(uiRoot) then
        clearingUI=true
        local ok,err=pcall(function()
            uiRoot:SetVisibility(1) -- Collapse immediately, even if removal needs a retry.
            assert(valid(viewportSubsystem),"Viewport unavailable during cleanup")
            viewportSubsystem:RemoveWidget(uiRoot)
            assert(not viewportSubsystem:IsWidgetAdded(uiRoot),"Screen UI still attached")
            assert(valid(rootLibrary),"Root release API unavailable")
            rootLibrary:RemoveFromRootSet(uiRoot)
            assert(not uiRoot:HasAnyInternalFlags(EInternalObjectFlags.RootSet),"Screen UI still rooted")
        end)
        if not ok then report("overlay_cleanup",err); return false end
    end
    -- Keep the cleanup handle on failure; never create a second rooted canvas.
    uiRoot,uiText,lastLabel,lastFont,lastSize=nil,nil,nil,nil,nil
    clearingUI=false
    return true
end
local function finishShutdown()
    if timerId~=nil then CancelDelayedAction(timerId); timerId=nil end
    shutdownPending=false
end
local function ensureUI()
    if not clearingUI and valid(uiRoot) and valid(uiText) and valid(viewportSubsystem)
        and viewportSubsystem:IsWidgetAdded(uiRoot) then return end
    assert(clearText(),"Screen UI cleanup pending")
    local library=StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
    viewportSubsystem=library:GetEngineSubsystem(StaticFindObject("/Script/UMG.GameViewportSubsystem"))
    rootLibrary=StaticFindObject("/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary")
    local instance=require("UEHelpers").GetGameInstance()
    assert(valid(viewportSubsystem) and valid(rootLibrary) and valid(instance),"Screen UI unavailable")
    -- GameInstance ownership avoids holding a departing world through a rooted outer.
    -- RF_Transient | RF_MarkAsRootSet; paired with RemoveFromRootSet in clearText.
    uiRoot=StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"),instance,0,0xC0)
    assert(valid(uiRoot),"Canvas creation failed")
    uiRoot:SetVisibility(3) -- HitTestInvisible: no mouse/keyboard focus or input capture.
    uiText=StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"),uiRoot,FName("PBZItemBeaconText"))
    assert(valid(uiText),"Text creation failed")
    uiText:SetVisibility(3)
    uiText:SetColorAndOpacity(gold)
    uiText:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
    uiText:SetShadowOffset({X=1,Y=1})
    local slot=uiRoot:AddChildToCanvas(uiText)
    slot:SetAnchors({Minimum={X=0.045,Y=0.25},Maximum={X=0.045,Y=0.25}})
    slot:SetPosition({X=0,Y=0})
    slot:SetAlignment({X=0,Y=0})
    slot:SetAutoSize(true)
    assert(viewportSubsystem:AddWidget(uiRoot,{
        Anchors={Minimum={X=0,Y=0},Maximum={X=1,Y=1}},
        Offsets={Left=0,Top=0,Right=0,Bottom=0},Alignment={X=0,Y=0},
        ZOrder=900,bAutoRemoveOnWorldRemoved=true}),"Screen UI attachment failed")
end
local function shorten(value,limit)
    local text=tostring(value or ""):gsub("[\r\n]"," ")
    local boundary=utf8.offset(text,limit+1)
    return boundary and text:sub(1,boundary-1).."…" or text
end
local function listText(current)
    local rows=current.rows or {}
    local cursor=math.max(1,math.min(#rows,current.cursor or 1))
    local first=math.max(1,math.min(cursor-3,#rows-6))
    local title=current.title or "物品选择"
    local lines={#rows>0 and string.format("%s   %d / %d",title,cursor,#rows) or title .. "   0 / 0"}
    if current.emptyMessage then lines[#lines+1]=current.emptyMessage end
    if #rows==0 then
        lines[#lines+1]="当前已加载范围内未发现符合筛选的目标"
    else
        for index=first,math.min(first+6,#rows) do
            lines[#lines+1]=(index==cursor and "› " or "  ")..shorten(rows[index].text,31)
        end
    end
    lines[#lines+1]="PgUp/PgDn 选择   Enter 确认   F5 关闭"
    return table.concat(lines,"\n")
end
local function draw()
    local current=state
    if not current then
        if clearText() and shutdownPending then finishShutdown() end
        return
    end
    local ok,err=pcall(function()
        local hud,pc=current.hud,current.pc
        if not valid(hud) or not valid(pc) or not valid(pc.Pawn)
            or pc.Pawn:GetAddress()~=pawnAddress then clearText(); return end
        local world,activeHUD=pc:GetWorld(),pc:GetHUD()
        if not valid(world) or world:GetAddress()~=worldAddress or not valid(activeHUD)
            or activeHUD:GetAddress()~=hud:GetAddress() then clearText(); return end
        if not hud.bShowHUD or pc:IsPaused() or not menuOpen or menuOpen(pc) then clearText(); return end
        if valid(previousHUD) and previousHUD:GetAddress()~=hud:GetAddress() then clearText() end
        previousHUD=hud
        hud:RemoveDebugText(hud,false)
        local outX,outY={},{}
        pc:GetViewportSize(outX,outY)
        local width,height=outX.SizeX,outY.SizeY
        if type(width)~="number" or type(height)~="number" or not (width>0 and height>0) then clearText(); return end
        local scale=math.max(0.65,math.min(1.5,height/1600))
        local font=valid(current.font) and current.font or nil
        local label,size
        if current.listOpen then
            label,size=listText(current),15
        else
            label=shorten(current.targetText,32).."\n"..shorten(current.status,37).."\nF5 打开道具面板"
            size=13
        end
        ensureUI()
        -- Reuse the same Slate widget between render frames, including camera movement.
        if label~=lastLabel then uiText:SetText(FText(label)); lastLabel=label end
        local fontAddress=font and font:GetAddress() or 0
        if size~=lastSize or fontAddress~=lastFont then
            local info=uiText.Font
            if font then info.FontObject=font end
            info.Size=size
            info.OutlineSettings.OutlineSize=1
            uiText:SetFont(info)
            lastSize,lastFont=size,fontAddress
        end
        previousHUD=hud
        if current.routeOn then
            for index=1,math.min(16,#(current.points or {})) do
                local point=current.points[index]
                local screen={X=0,Y=0}
                if pc:ProjectWorldLocationToScreen(point,screen,false)==true and screen.X>=0 and screen.X<width
                    and screen.Y>=0 and screen.Y<height then
                    hud:AddDebugText("●",hud,0.15,point,point,blue,true,true,false,font,1.15*scale,true)
                end
            end
        end
    end)
    if not ok then
        state,pawnAddress,worldAddress=nil,nil,nil
        clearText()
        report("overlay_draw",err)
    end
end
function M.init(isMenuOpen,onError)
    menuOpen,reportOnce=isMenuOpen,onError
    shutdownPending=false
    if timerId~=nil then return true end
    local ok,result=pcall(LoopInGameThreadWithDelay,33,draw)
    if ok then timerId=result else report("overlay_init",result) end
    return ok
end
function M.clear()
    state,pawnAddress,worldAddress=nil,nil,nil
    return clearText()
end
function M.set(nextState)
    if not nextState or (not nextState.listOpen and (not nextState.targetText or nextState.targetText=="")) then M.clear(); return end
    local ok,err=pcall(function()
        local pc=nextState.pc
        if not valid(pc) or not valid(pc.Pawn) or not valid(nextState.hud) then M.clear(); return end
        local world=pc:GetWorld()
        if not valid(world) then M.clear(); return end
        if valid(previousHUD) and previousHUD:GetAddress()~=nextState.hud:GetAddress() then clearText() end
        state,pawnAddress,worldAddress=nextState,pc.Pawn:GetAddress(),world:GetAddress()
    end)
    if not ok then M.clear(); report("overlay_state",err) end
end
function M.shutdown()
    shutdownPending=true
    if M.clear() then finishShutdown() end
end
function M.visiblePoints(pc,pawn,points)
    local visible={}
    local ok,err=pcall(function()
        if not valid(pc) or not valid(pawn) or not valid(pc.Pawn)
            or pc.Pawn:GetAddress()~=pawn:GetAddress() then return end
        if pc:IsPaused() or not menuOpen or menuOpen(pc) then return end
        local camera=pc.PlayerCameraManager
        if not valid(camera) then return end
        if not valid(kismet) then kismet=StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
        if not valid(kismet) then return end
        local origin=camera:GetCameraLocation()
        for index=1,math.min(16,#(points or {})) do
            local point=points[index]
            local endpoint={X=point.X,Y=point.Y,Z=point.Z+15}
            local hit={}
            local blocked=kismet:LineTraceSingle(pawn,origin,endpoint,0,false,{pawn},0,hit,true,transparent,transparent,0)
            if blocked==false then visible[#visible+1]=endpoint end
        end
    end)
    if not ok then report("overlay_visibility",err); return {} end
    return visible
end
return M
