-- Explicit phase selections. The remaining runtime codex bosses use phase 2.
-- Encounter completion is still experimental; this table does not certify it.
local rules = {}
local first = {
    BP_Monster_ChiLian = true,
    BP_Monster_MuXiaoKui = true,
    BP_Monster_GuiChai_Red = true,
    BP_Monster_ChangHong_Spear = true,
    BP_Monster_LionDancer = true,
    BP_Monster_LeiDang = true,
    BP_Monster_YuCong_P1 = true,
    BP_Monster_PowerMan = true,
    BP_Monster_ZuoShang_Ending = true,
}
-- This ID is recorded in PBZCoop; its full P1 class and combat are not yet verified.
local firstSpawners = {
    HookManP1_Seq022 = "World /Game/Maps/B02/PBZ_Xigu_WP.PBZ_Xigu_WP",
}
local finalPuppets = {
    BP_Monster_YuCong_WuLi = true,
    BP_Monster_YuCong_Bing = true,
    BP_Monster_YuCong_HunDun = true,
}

function rules.select(row, spawnId, classPath, worldPath)
    local firstSpawner = firstSpawners[spawnId] ~= nil and firstSpawners[spawnId] == worldPath
    if not row and not firstSpawner then return nil, "not a codex boss" end
    local phase = (first[row] or firstSpawner) and 1 or 2
    return {
        encounter_id = worldPath .. ":" .. (row or "HookMan"),
        phase_id = "phase_" .. phase,
        spawn_id = spawnId,
        original_class = classPath,
        target_phase = phase,
        -- Each native spawner keeps its own identity, including all three puppets.
        entity_count = finalPuppets[row] and 3 or 1,
    }
end

return rules
