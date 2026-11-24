local ADDON, ns = ...
local PR = ns.PR

-- Tracks dungeon runs and who was in them, so you can rate the group afterwards
-- (and only people you actually played with).
local G = {}
ns.Group = G

local MAX_GROUPS = 30

local function RunList(run)
    local list = {}
    for _, m in pairs(run.members) do list[#list + 1] = m end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function G:Roster()
    local list = {}
    local function add(unit)
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local key, name, class = PR:UnitKey(unit)
            if key then
                local near = UnitIsVisible(unit)
                if PR.secret(near) then near = true end
                list[#list + 1] = { key = key, name = name, class = class, near = near and true or false }
                if class then PR.db.classes[key] = class end
            end
        end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do add("raid" .. i) end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do add("party" .. i) end
    end
    return list
end

-- A groupmate joins the run once they've been seen near you inside the instance.
function G:UpdateRun()
    local run = self.run
    if not run then return end
    for _, m in ipairs(self:Roster()) do
        if m.near and not run.members[m.key] then
            m.near = nil
            run.members[m.key] = m
        end
    end
end

-- A run counts once a boss dies or it's finished; groupmates count once seen near you inside.
-- Finished runs open the rating window and are remembered for /rate.
function G:CheckZone()
    local inInstance, kind = IsInInstance()
    if inInstance and (kind == "party" or kind == "raid") and IsInGroup() then
        local name = GetInstanceInfo()
        if not self.run or self.run.dungeon ~= name then
            self.run = { dungeon = name or "Dungeon", bosses = 0, members = {}, started = time() }
        end
        self:UpdateRun()
    elseif self.run then
        local run = self.run
        self.run = nil
        if not run.prompted and (run.bosses > 0 or run.completed) then self:Finish(run) end
    end
end

function G:Finish(run)
    if run.prompted then return end
    run.prompted = true
    local list = RunList(run)
    if #list == 0 then return end
    table.insert(PR.db.groups, 1, { ts = time(), dungeon = run.dungeon, members = list })
    while #PR.db.groups > MAX_GROUPS do table.remove(PR.db.groups) end
    if PR.s.prompt and PR:CanIRate() then ns.UI:OpenRate(list, run.dungeon) end
end

-- The run you're in right now, otherwise the last finished run (if still within 24 hours).
function G:LastGroup()
    if self.run then
        local list = RunList(self.run)
        if #list > 0 then return list, self.run.dungeon end
    end
    local g = PR.db.groups[1]
    if g and time() - g.ts <= PR.RATE_WINDOW then return g.members, g.dungeon end
end

-- Anyone but yourself can be rated (one vote each, changeable once a week; see Core).
function G:CanRate(key)
    return key ~= nil and key ~= PR:MyKey()
end

-- Most recent dungeon you saw this player in.
function G:SeenWith(key)
    if self.run and self.run.members[key] then return self.run.dungeon end
    for _, g in ipairs(PR.db.groups) do
        for _, m in ipairs(g.members) do
            if m.key == key then return g.dungeon end
        end
    end
    return ""
end

function G:Init()
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("PLAYER_ROLES_ASSIGNED")
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("LFG_COMPLETION_REWARD")
    pcall(f.RegisterEvent, f, "CHALLENGE_MODE_COMPLETED")
    f:SetScript("OnEvent", function(_, event, ...)
        if event == "ENCOUNTER_END" then
            local success = select(5, ...)
            if G.run and not PR.secret(success) and success == 1 then
                G.run.bosses = G.run.bosses + 1
                G:UpdateRun()
            end
        elseif event == "LFG_COMPLETION_REWARD" or event == "CHALLENGE_MODE_COMPLETED" then
            local run = G.run
            if run then
                run.completed = true
                G:UpdateRun()
                C_Timer.After(4, function() G:Finish(run) end)
            end
        elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
            G:UpdateRun()
        else
            G:CheckZone()
        end
    end)
    G:CheckZone()
end
