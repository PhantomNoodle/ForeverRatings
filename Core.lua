local ADDON, ns = ...

local PR = {}
ns.PR = PR
_G.ForeverRatings = PR

PR.MAX_COMMENT = 120      -- bytes; keeps every network message under the 255 byte limit
PR.MAX_DUNGEON = 40
PR.MAX_NAME = 40
PR.RATE_WINDOW = 24 * 3600    -- the after-run window offers runs from the last 24 hours
PR.CHANGE_COOLDOWN = 7 * 86400 -- one vote per rater per player; it can be changed once a week
PR.MAX_SKEW = 3600            -- ratings dated more than an hour in the future are rejected
PR.STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
PR.MIN_LEVEL = 55         -- only ratings written by characters of this level or higher count

local DEFAULT_SETTINGS = {
    prompt = true,     -- open the rating window after a dungeon
    tooltip = true,    -- show ratings in tooltips
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Forever Ratings:|r " .. tostring(msg))
end
PR.Print = Print

local function secret(v) return issecretvalue and issecretvalue(v) or false end
PR.secret = secret

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
PR.trim = trim

local function TitleCase(s)
    return (s:gsub("(%S)(%S*)", function(a, b) return a:upper() .. b end))
end

-- Cut to maxBytes without leaving half a UTF-8 character at the end.
function PR.Truncate(s, maxBytes)
    if #s <= maxBytes then return s end
    s = s:sub(1, maxBytes)
    local i = #s
    while i > 0 do
        local b = s:byte(i)
        if b < 0x80 then break end
        if b >= 0xC0 then
            local need = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or 2
            if #s - i + 1 < need then s = s:sub(1, i - 1) end
            break
        end
        i = i - 1
    end
    return s
end

-- Text from the network or the user: no control characters, no UI escape codes.
function PR.Clean(s, maxBytes)
    s = tostring(s or ""):gsub("%c", " "):gsub("|", "/")
    s = trim(s:gsub("%s+", " "))
    return PR.Truncate(s, maxBytes or PR.MAX_COMMENT)
end

-- ---------------------------------------------------------------------------
-- Names (Forever has no realms and two-word names; realm servers use Name-Realm)
-- ---------------------------------------------------------------------------
function PR:MyRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then r = (GetRealmName() or ""):gsub("[%s%-]", "") end
    return r or ""
end

function PR:Normalize(name)
    if type(name) ~= "string" or secret(name) then return nil end
    name = trim(name):gsub("%s+", " ")
    if name == "" or #name > PR.MAX_NAME then return nil end
    local realm = self:MyRealm()
    if realm == "" then
        name = trim(name:gsub("%-$", ""))
        if name == "" then return nil end
        local full = TitleCase(name)
        return full:lower(), full
    end
    local n, r = name:match("^([^%-]+)%-(.+)$")
    if not n then n, r = name, realm end
    local full = n:sub(1, 1):upper() .. n:sub(2) .. "-" .. r:gsub("%s", "")
    return full:lower(), full
end

function PR:UnitKey(unit)
    if not unit or secret(unit) then return nil end
    local ok, isPlayer = pcall(UnitIsPlayer, unit)
    if not ok or not isPlayer or secret(isPlayer) then return nil end
    local name, realm = UnitFullName(unit)
    if not name or secret(name) then return nil end
    if realm and not secret(realm) and realm ~= "" then name = name .. "-" .. realm end
    local key, full = self:Normalize(name)
    if not key then return nil end
    local _, class = UnitClass(unit)
    if secret(class) then class = nil end
    return key, full, class
end

function PR:MyKey()
    if not self.myKey then self.myKey, self.myName = self:Normalize(UnitName("player")) end
    return self.myKey, self.myName
end

function PR:ShortName(full)
    local realm = self:MyRealm()
    if realm ~= "" then
        local n, r = full:match("^(.-)%-(.+)$")
        if n and r == realm then return n end
    end
    return full
end

function PR:ColoredName(name, class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local short = self:ShortName(name)
    if c and c.colorStr then return ("|c%s%s|r"):format(c.colorStr, short) end
    return short
end

-- ---------------------------------------------------------------------------
-- Saved data
-- ---------------------------------------------------------------------------
-- records[authorKey .. "\031" .. targetKey] = {
--   a = author, t = target, s = stars (0 = withdrawn), c = comment, d = dungeon,
--   ts = when the author wrote it, v = true when received straight from the author,
--   via = who relayed it (unverified only), rx = when we received it }
local function InitDB()
    ForeverRatingsDB = ForeverRatingsDB or {}
    local db = ForeverRatingsDB
    db.records = db.records or {}
    db.groups = db.groups or {}
    db.classes = db.classes or {}
    db.levels = db.levels or {}   -- [key] = { claimed = n, seen = n }
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    PR.db, PR.s = db, db.settings

    -- 1.1 stored one rating per role ("author\031target\031role"). Keep the newest per author and target.
    local merged = {}
    for k, r in pairs(db.records) do
        local a, t, role = k:match("^(.-)\031(.-)\031(.+)$")
        if role then
            db.records[k] = nil
            local nk = a .. "\031" .. t
            local cur = merged[nk] or db.records[nk]
            r.r = nil
            if not cur or (r.v and not cur.v) or ((r.v and true or false) == (cur.v and true or false) and r.ts > cur.ts) then
                merged[nk] = r
            end
        end
    end
    for nk, r in pairs(merged) do db.records[nk] = r end
end

-- ---------------------------------------------------------------------------
-- Rater levels
-- "claimed": what the author's addon says (sent with every message).
-- "seen": what the game itself showed us (group, guild, target, mouseover). Seen always wins.
-- ---------------------------------------------------------------------------
function PR:NoteLevel(key, level, seen)
    level = tonumber(level)
    if not key or not level or level < 1 or level > 200 or level % 1 ~= 0 then return end
    local l = self.db.levels[key] or {}
    self.db.levels[key] = l
    if seen then
        if (l.seen or 0) ~= level then
            l.seen = math.max(level, l.seen or 0)
            l.seenAt = time()
            self:Changed()
        end
    elseif (l.claimed or 0) ~= level then
        l.claimed = level
        self:Changed()
    end
end

function PR:NoteUnitLevel(unit)
    local key = self:UnitKey(unit)
    if not key then return end
    local lvl = UnitLevel(unit)
    if secret(lvl) or not lvl or lvl <= 0 then return end
    self:NoteLevel(key, lvl, true)
end

-- Best known level of a player, and where it came from ("seen" or "claimed").
function PR:LevelOf(key)
    if key == self:MyKey() then return UnitLevel("player"), "seen" end
    local l = self.db.levels[key]
    if not l then return nil end
    if l.seen then return l.seen, "seen" end
    return l.claimed, "claimed"
end

-- Does this rating count toward the score? Verified, not withdrawn, author 55+.
function PR:Counts(r)
    if not r.v or r.s <= 0 then return false end
    local lvl = self:LevelOf(self:Normalize(r.a))
    return (lvl or 0) >= PR.MIN_LEVEL
end

function PR:CanIRate()
    return (UnitLevel("player") or 0) >= PR.MIN_LEVEL
end

function PR:RecKey(aKey, tKey) return aKey .. "\031" .. tKey end

function PR:BuildIndex()
    local idx = {}
    for k, r in pairs(self.db.records) do
        local tKey = self:Normalize(r.t)
        if tKey then
            idx[tKey] = idx[tKey] or {}
            idx[tKey][k] = true
        end
    end
    self.byTarget = idx
end

function PR:Prune()
    local now, removed = time(), 0
    for k, r in pairs(self.db.records) do
        -- Unverified relays that were never confirmed by their author expire after 30 days.
        if not r.v and (now - (r.rx or 0)) > 30 * 86400 then
            self.db.records[k] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- Merge a rating. firstHand = it came straight from the author (the game server vouches for the sender).
-- Returns true if anything changed.
function PR:Merge(r, firstHand, via)
    local aKey, aName = self:Normalize(r.a)
    local tKey, tName = self:Normalize(r.t)
    if not aKey or not tKey or aKey == tKey then return false end   -- nobody rates themselves
    local s, ts = tonumber(r.s), tonumber(r.ts)
    if not s or s < 0 or s > 5 or s % 1 ~= 0 or not ts then return false end
    local now = time()
    if ts > now + PR.MAX_SKEW then return false end
    firstHand = firstHand and true or false

    local k = self:RecKey(aKey, tKey)
    local old = self.db.records[k]
    if old then
        local oldV = old.v and true or false
        if oldV and not firstHand then return false end                 -- a relay never replaces a verified rating
        if oldV == firstHand and ts <= (old.ts or 0) then return false end -- same trust level: newer wins
        -- One vote per rater: a new score replaces the old one only after the cooldown.
        -- Enforced by every receiving client, so a modified sender can't skip it.
        -- The clock starts at the later of the date the author put on the old vote and the moment
        -- WE received it, so backdating the first vote doesn't help either.
        -- (Withdrawing, 0 stars, is allowed any time; the next vote then waits from the withdrawal.)
        if oldV and firstHand and s > 0 then
            local anchor = math.max(old.ts or 0, old.rx or 0)
            if ts - anchor < PR.CHANGE_COOLDOWN or now - anchor < PR.CHANGE_COOLDOWN then return false end
        end
    end

    self.db.records[k] = {
        a = aName, t = tName, s = s, ts = ts,
        c = PR.Clean(r.c, PR.MAX_COMMENT),
        d = PR.Clean(r.d, PR.MAX_DUNGEON),
        v = firstHand or nil,
        via = (not firstHand and via) or nil,
        rx = now,
    }
    if self.byTarget then
        self.byTarget[tKey] = self.byTarget[tKey] or {}
        self.byTarget[tKey][k] = true
    end
    self:Changed()
    return true
end

-- Write or change your own rating, then publish it.
function PR:Rate(target, stars, comment, dungeon, class)
    local myKey, myName = self:MyKey()
    local tKey, tName = self:Normalize(target)
    if not tKey then return nil, "Unknown player." end
    if tKey == myKey then return nil, "You can't rate yourself." end
    if not self:CanIRate() then return nil, ("You need to be level %d to rate players."):format(PR.MIN_LEVEL) end
    stars = math.floor(tonumber(stars) or 0)
    if stars < 0 or stars > 5 then return nil, "Pick 1 to 5 stars." end
    local wait = self:ChangeWait(tKey)
    if stars > 0 and wait > 0 then
        return nil, ("You can change your rating of %s in %s."):format(tName, self:Duration(wait))
    end
    if class then self.db.classes[tKey] = class end
    local k = self:RecKey(myKey, tKey)
    local ts = time()
    local old = self.db.records[k]
    if old and old.ts and old.ts >= ts then ts = old.ts + 1 end
    self:Merge({ a = myName, t = tName, s = stars, c = comment, d = dungeon, ts = ts }, true)
    local saved = self.db.records[k]
    if saved then ns.Net:Publish(saved) end
    return saved
end

-- Take back your rating (sent as 0 stars so the change spreads like any other).
function PR:Withdraw(target)
    local myKey = self:MyKey()
    local tKey = self:Normalize(target)
    local old = tKey and self.db.records[self:RecKey(myKey, tKey)]
    if not old then return end
    return self:Rate(old.t, 0, "", old.d)
end

function PR:MyRating(tKey)
    return self.db.records[self:RecKey(self:MyKey(), tKey)]
end

-- Seconds until you may change your rating of this player (0 = now).
function PR:ChangeWait(tKey)
    local old = self:MyRating(tKey)
    if not old or not old.ts then return 0 end
    return math.max(0, PR.CHANGE_COOLDOWN - (time() - old.ts))
end

function PR:Duration(sec)
    if sec >= 86400 then
        local d = math.ceil(sec / 86400)
        return d .. (d == 1 and " day" or " days")
    end
    local h = math.max(1, math.ceil(sec / 3600))
    return h .. (h == 1 and " hour" or " hours")
end

-- Ratings about one player, newest first.
function PR:RatingsFor(tKey)
    local list = {}
    if not self.byTarget then self:BuildIndex() end
    for k in pairs(self.byTarget[tKey] or {}) do
        local r = self.db.records[k]
        if r and r.s > 0 then list[#list + 1] = r end
    end
    table.sort(list, function(x, y)
        if (x.v and 1 or 0) ~= (y.v and 1 or 0) then return x.v and true or false end
        return x.ts > y.ts
    end)
    return list
end

-- Overall score: average of the ratings that count (verified, author 55+).
-- Returns { avg = 3.2 or nil, n = counted, unverified = n, low = n (author under 55), latest = record with a comment }
function PR:Summary(tKey)
    local st = { sum = 0, n = 0, unverified = 0, low = 0 }
    for _, r in ipairs(self:RatingsFor(tKey)) do
        if self:Counts(r) then
            st.sum, st.n = st.sum + r.s, st.n + 1
            if r.c ~= "" and (not st.latest or r.ts > st.latest.ts) then st.latest = r end
        elseif r.v then
            st.low = st.low + 1
        else
            st.unverified = st.unverified + 1
        end
    end
    st.avg = st.n > 0 and (st.sum / st.n) or nil
    return st
end

function PR:ScoreColor(avg)
    if not avg then return "ffaaaaaa" end
    if avg >= 4 then return "ff40ff40" end
    if avg >= 3 then return "ffffd200" end
    if avg >= 2 then return "ffff9933" end
    return "ffff4040"
end

function PR:StarsText(n, size)
    size = size or 12
    local t = {}
    for i = 1, 5 do
        if i <= n then
            t[i] = ("|T%s:%d:%d|t"):format(PR.STAR, size, size)
        else
            t[i] = ("|T%s:%d:%d:0:0:64:64:0:64:0:64:90:90:90|t"):format(PR.STAR, size, size)
        end
    end
    return table.concat(t)
end

-- "Rating: 4.2 (220)", or "Rating: unrated" when no vote counts yet.
function PR:SummaryText(tKey)
    local st = self:Summary(tKey)
    local text
    if st.avg then
        text = ("|T%s:12:12|t Rating: |c%s%.1f|r |cffaaaaaa(%d)|r"):format(PR.STAR,
            self:ScoreColor(st.avg), st.avg, st.n)
    else
        text = ("|T%s:12:12|t Rating: |cffaaaaaaunrated|r"):format(PR.STAR)
    end
    if st.unverified > 0 then text = text .. ("  |cff888888+%d unverified|r"):format(st.unverified) end
    if st.low > 0 then text = text .. ("  |cff888888+%d under %d|r"):format(st.low, PR.MIN_LEVEL) end
    return text
end

-- Short form for lists: "3.2 (5)"
function PR:ShortSummary(tKey)
    local st = self:Summary(tKey)
    if not st.avg then return "|cff888888unrated|r" end
    return ("|c%s%.1f|r |cff888888(%d)|r"):format(self:ScoreColor(st.avg), st.avg, st.n)
end

-- UI refresh, batched so a big sync doesn't redraw hundreds of times.
function PR:Changed()
    if self.refreshPending then return end
    self.refreshPending = true
    C_Timer.After(0.5, function()
        self.refreshPending = false
        if ns.UI then ns.UI:Refresh() end
    end)
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function Help()
    Print("commands:")
    for _, l in ipairs({
        "/rate  rate your current or last group",
        "/rate <name>  rate any player (one vote each, changeable once a week)",
        "/ratings [name]  open the ratings viewer",
        "/ratings prompt  toggle the window after dungeons",
        "/ratings sync  ask the network for missed ratings",
        "/ratings status  network and storage info",
        "/ratings debug  show what the addon can see (for troubleshooting)",
    }) do DEFAULT_CHAT_FRAME:AddMessage("  " .. l) end
end

SLASH_PLAYERRATINGSRATE1 = "/rate"
SlashCmdList.PLAYERRATINGSRATE = function(msg)
    msg = trim(msg)
    if msg == "" then
        local members, dungeon = ns.Group:LastGroup()
        if not members or #members == 0 then Print("No recent run to rate. Use /rate <name> to rate anyone.") return end
        ns.UI:OpenRate(members, dungeon)
    else
        local key, name = PR:Normalize(msg)
        if not key then Print("Unknown player.") return end
        if not ns.Group:CanRate(key) then Print("You can't rate yourself.") return end
        ns.UI:OpenRate({ { key = key, name = name, class = PR.db.classes[key] } }, ns.Group:SeenWith(key))
    end
end

SLASH_PLAYERRATINGS1 = "/ratings"
SlashCmdList.PLAYERRATINGS = function(msg)
    msg = trim(msg)
    local cmd = msg:lower()
    if cmd == "" then
        ns.UI:ToggleViewer()
    elseif cmd == "prompt" then
        PR.s.prompt = not PR.s.prompt
        Print("rating window after dungeons: " .. (PR.s.prompt and "on" or "off"))
    elseif cmd == "sync" then
        ns.Net:RequestSync(true)
    elseif cmd == "status" then
        local total, verified, mine = 0, 0, 0
        local myKey = PR:MyKey()
        for _, r in pairs(PR.db.records) do
            total = total + 1
            if r.v then verified = verified + 1 end
            if PR:Normalize(r.a) == myKey then mine = mine + 1 end
        end
        Print(("%d ratings stored (%d verified, %d written by you). %s"):format(total, verified, mine, ns.Net:StatusText()))
    elseif cmd == "debug" then
        local myKey, myName = PR:MyKey()
        local out = {}
        local function line(s)
            -- Plain text for copying: strip color, texture and atlas codes.
            s = tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "*"):gsub("|A.-|a", "")
            out[#out + 1] = s
        end
        local function keysOf(t)
            local ks = {}
            if type(t) == "table" then
                for k, v in pairs(t) do
                    if type(k) == "string" and type(v) == "table" then ks[#ks + 1] = k end
                end
            end
            table.sort(ks)
            return table.concat(ks, ", ")
        end
        line("Forever Ratings debug, version " .. tostring(C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")))
        line("client: " .. tostring((select(1, GetBuildInfo()))) .. " / interface " .. tostring((select(4, GetBuildInfo()))))
        line(("me: %s (key %s), level %s, tooltips %s"):format(tostring(myName), tostring(myKey),
            tostring(UnitLevel("player")), PR.s.tooltip and "on" or "OFF"))
        line("my rating: " .. (myKey and PR:SummaryText(myKey) or "?"))
        line("unit tooltip hook: " .. tostring(ns.UI.tooltipHook or "NOT INSTALLED"))
        local loadedAddons = {}
        for _, a in ipairs({ "Blizzard_GroupFinder", "Blizzard_GroupFinder_VanillaStyle", "Blizzard_LookingForGroupUI" }) do
            local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(a)
            loadedAddons[#loadedAddons + 1] = a .. "=" .. tostring(isLoaded)
        end
        line("Blizzard UI: " .. table.concat(loadedAddons, ", "))
        line(("frames: LFGListFrame %s, LFGParentFrame %s, LFGBrowseFrame %s, LFGListingFrame %s"):format(
            tostring(LFGListFrame ~= nil), tostring(LFGParentFrame ~= nil), tostring(LFGBrowseFrame ~= nil), tostring(LFGListingFrame ~= nil)))
        ns.UI:TryHooks()
        local lf = LFGListFrame
        line(("ScrollUtil: %s, SearchPanel.ScrollBox: %s, ApplicationViewer.ScrollBox: %s"):format(
            tostring(ScrollUtil and ScrollUtil.AddInitializedFrameCallback ~= nil),
            tostring(lf and lf.SearchPanel and lf.SearchPanel.ScrollBox ~= nil),
            tostring(lf and lf.ApplicationViewer and lf.ApplicationViewer.ScrollBox ~= nil)))
        for _, name in ipairs(ns.UI.SCROLL_HOOKS) do
            line(name .. ": " .. (ns.UI.hooked[name] and "|cff66ff66attached|r" or "|cffff6666not attached|r"))
        end
        for _, fname in ipairs(ns.UI.HOOK_NAMES) do
            line(("%s: %s, %s"):format(fname, type(_G[fname]) == "function" and "exists" or "missing",
                ns.UI.hooked[fname] and "hooked" or "not hooked"))
        end
        -- Frame layout, in case this client builds the Group Finder differently.
        local bf = LFGBrowseFrame
        line("LFGBrowseFrame parts: " .. keysOf(bf))
        line("LFGListFrame parts: " .. keysOf(lf))
        local sb = (bf and (bf.ScrollBox or (bf.SearchResults and bf.SearchResults.ScrollBox)))
            or (lf and lf.SearchPanel and lf.SearchPanel.ScrollBox)
        if sb and sb.GetFrames then
            local frames = sb:GetFrames() or {}
            line(("search rows on screen: %d"):format(#frames))
            local row = frames[1]
            if row then
                line("first row parts: " .. keysOf(row))
                line("first row resultID: " .. tostring(row.resultID) .. ", our score text: " .. tostring(row.PRScore and row.PRScore:GetText()))
                local data = row.GetElementData and row:GetElementData()
                line("first row data: " .. (type(data) == "table" and ("table {" .. keysOf(data) .. "} resultID=" .. tostring(data.resultID) .. " id=" .. tostring(data.id)) or tostring(data)))
                local rid = row.resultID or (type(data) == "table" and (data.resultID or data.id)) or (type(data) == "number" and data)
                if rid and C_LFGList and C_LFGList.GetSearchResultInfo then
                    local info = C_LFGList.GetSearchResultInfo(rid)
                    line("first row leader: " .. tostring(info and info.leaderName) .. ", members: " .. tostring(info and info.numMembers))
                    if C_LFGList.GetSearchResultMemberInfo then
                        local res = { pcall(C_LFGList.GetSearchResultMemberInfo, rid, 1) }
                        local parts = {}
                        for i = 2, #res do parts[#parts + 1] = type(res[i]) == "table" and ("{" .. keysOf(res[i]) .. "}") or tostring(res[i]) end
                        line("first member info: " .. table.concat(parts, ", "))
                    end
                end
            end
        end
        -- What this client calls its Group Finder functions.
        local found = {}
        for k, v in pairs(_G) do
            if type(k) == "string" and type(v) == "function" and k:find("^LFG") and not k:find("^LFGListing") then
                found[#found + 1] = k
            end
        end
        table.sort(found)
        line(("LFG functions (%d): %s"):format(#found, table.concat(found, ", ")))
        local tkey = UnitExists("target") and PR:UnitKey("target")
        if tkey then line("target: " .. tkey .. " -> " .. PR:SummaryText(tkey)) end
        line(ns.Net:StatusText())
        ns.UI:ShowCopy("Forever Ratings debug", table.concat(out, "\n"))
    elseif cmd == "help" then
        Help()
    else
        ns.UI:OpenViewer(msg)
    end
end

function ForeverRatings_OnAddonCompartmentClick()
    ns.UI:ToggleViewer()
end

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then InitDB() end
        if PR.db and ns.UI then ns.UI:TryHooks() end
    elseif event == "PLAYER_LOGIN" then
        -- Record real levels whenever the game shows them to us.
        ev:RegisterEvent("GROUP_ROSTER_UPDATE")
        ev:RegisterEvent("PLAYER_TARGET_CHANGED")
        ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
        ev:RegisterEvent("GUILD_ROSTER_UPDATE")
        ev:RegisterEvent("UNIT_LEVEL")
        PR:Prune()
        PR:BuildIndex()
        ns.Net:Init()
        ns.Group:Init()
        ns.UI:Init()
        Print(("loaded (v%s). /ratings to open, /ratings debug if something doesn't show."):format(
            (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?"))
    elseif event == "PLAYER_TARGET_CHANGED" then
        PR:NoteUnitLevel("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        PR:NoteUnitLevel("mouseover")
    elseif event == "UNIT_LEVEL" then
        if arg1 and not PR.secret(arg1) then PR:NoteUnitLevel(arg1) end
    elseif event == "GROUP_ROSTER_UPDATE" then
        local raid = IsInRaid()
        local n = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, n do PR:NoteUnitLevel((raid and "raid" or "party") .. i) end
    elseif event == "GUILD_ROSTER_UPDATE" then
        if GetNumGuildMembers and GetGuildRosterInfo then
            for i = 1, GetNumGuildMembers() do
                local name, _, _, level = GetGuildRosterInfo(i)
                if name and not PR.secret(name) then PR:NoteLevel(PR:Normalize(name), level, true) end
            end
        end
    end
end)
