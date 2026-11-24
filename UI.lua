local ADDON, ns = ...
local PR = ns.PR

local UI = { search = "" }
ns.UI = UI

local secret = PR.secret

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 90, h or 22)
    b:SetText(text)
    return b
end

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

local function Window(name, w, h, title)
    local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, name)
    if f.TitleText then f.TitleText:SetText(title) end
    return f
end

-- ---------------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------------
function UI:AddTooltip(tt, key, spacer)
    if not PR.s.tooltip or not key then return end
    local text = PR:SummaryText(key)
    if not text then return end
    if spacer then tt:AddLine(" ") end
    tt:AddLine(text)
    local latest = PR:Summary(key).latest
    if latest then
        tt:AddLine(("\"%s\" |cff888888(%s)|r"):format(latest.c, PR:ShortName(latest.a)), 0.8, 0.8, 0.8, true)
    end
end

local function OnUnitTooltip(tt)
    if not tt or not tt.GetUnit then return end
    local ok, _, unit = pcall(tt.GetUnit, tt)
    if not ok or not unit then return end
    UI:AddTooltip(tt, (PR:UnitKey(unit)))
end

local function LeaderName(resultID)
    if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return nil end
    local info = C_LFGList.GetSearchResultInfo(resultID)
    local name = info and info.leaderName
    if name and not secret(name) then return name end
end

local function ApplicantName(applicantID, idx)
    if not (C_LFGList and C_LFGList.GetApplicantMemberInfo) then return nil end
    local name = C_LFGList.GetApplicantMemberInfo(applicantID, idx)
    if name and not secret(name) then return name end
end

local hooked = {}
UI.hooked = hooked
UI.HOOK_NAMES = { "LFGBrowseSearchEntry_Update", "LFGListSearchEntry_Update", "LFGListUtil_SetSearchEntryTooltip",
    "LFGListApplicationViewer_UpdateApplicantMember", "LFGListApplicantMember_OnEnter" }
UI.SCROLL_HOOKS = { "LFGBrowseFrame.ScrollBox", "SearchPanel.ScrollBox", "ApplicationViewer.ScrollBox" }
local function Hook(fname, fn)
    if hooked[fname] or type(_G[fname]) ~= "function" then return end
    hooksecurefunc(fname, fn)
    hooked[fname] = true
end

-- Small score text on a Group Finder row, created once and reused as rows are recycled.
local function RowScore(frame)
    if not frame.PRScore then
        frame.PRScore = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        frame.PRScore:SetJustifyH("LEFT")
    end
    return frame.PRScore
end

local function ScoreText(key, prefix)
    return ("%s|T%s:11:11|t %s"):format(prefix or "", PR.STAR, PR:ShortSummary(key))
end

-- Search result row: the group leader's rating.
local function UpdateSearchRow(row, resultID)
    if not row then return end
    resultID = resultID or row.resultID or row.PRResultID
    local fs = RowScore(row)
    local key = resultID and PR.s.tooltip and PR:Normalize(LeaderName(resultID))
    if not key then fs:Hide() return end
    fs:ClearAllPoints()
    if row.DataDisplay then
        fs:SetPoint("RIGHT", row.DataDisplay, "LEFT", -8, 0)
    else
        fs:SetPoint("RIGHT", row, "RIGHT", -160, 0)
    end
    fs:SetText(ScoreText(key, "|cffaaaaaaLeader|r "))
    fs:Show()
end

-- Applicant member row: that player's rating, right after their name.
local function UpdateMemberRow(member, applicantID, memberIdx)
    if not member then return end
    local fs = RowScore(member)
    local key = applicantID and memberIdx and PR.s.tooltip and PR:Normalize(ApplicantName(applicantID, memberIdx))
    if not key then fs:Hide() return end
    fs:ClearAllPoints()
    if member.Name then
        local nameWidth = math.min(member.Name:GetStringWidth() or 0, member.Name:GetWidth() or 0)
        fs:SetPoint("LEFT", member.Name, "LEFT", nameWidth + 4, 0)
    else
        fs:SetPoint("LEFT", member, "LEFT", 120, 0)
    end
    fs:SetText(ScoreText(key))
    fs:Show()
end

local function TooltipLeader(row)
    local key = PR:Normalize(LeaderName(row.resultID or row.PRResultID))
    if key then
        UI:AddTooltip(GameTooltip, key, true)
        GameTooltip:Show()
    end
end

local function TooltipMember(member)
    local key = PR:Normalize(ApplicantName(member.PRApplicantID, member.PRIdx))
    if key then
        UI:AddTooltip(GameTooltip, key, true)
        GameTooltip:Show()
    end
end

-- Row data can be the id itself or a table holding it.
local function IdFrom(elementData, ...)
    if type(elementData) == "number" then return elementData end
    if type(elementData) == "table" then
        for _, field in ipairs({ ... }) do
            if type(elementData[field]) == "number" then return elementData[field] end
        end
    end
end

local function OnSearchRow(_, row, elementData)
    row.PRResultID = row.resultID or IdFrom(elementData, "resultID", "id")
    UpdateSearchRow(row, row.PRResultID)
    if not row.PRHooked then
        row.PRHooked = true
        row:HookScript("OnEnter", TooltipLeader)
    end
end

local function OnApplicantRow(_, row, elementData)
    local applicantID = row.applicantID or IdFrom(elementData, "applicantID", "id")
    if not applicantID then return end
    local members = row.Members or {}
    for i, member in ipairs(members) do
        member.PRApplicantID, member.PRIdx = applicantID, member.memberIdx or i
        if member:IsShown() then
            UpdateMemberRow(member, applicantID, member.PRIdx)
        elseif member.PRScore then
            member.PRScore:Hide()
        end
        if not member.PRHooked then
            member.PRHooked = true
            member:HookScript("OnEnter", TooltipMember)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Classic "Looking For Group" browse tool (what Forever uses): LFGBrowseFrame
-- ---------------------------------------------------------------------------
local ROLE_WORDS = { TANK = true, HEALER = true, DAMAGER = true, NONE = true }

-- Leader first, then the other members whose names the game gives us.
local function ListingMembers(resultID)
    local out = {}
    if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return out end
    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info then return out end
    local leader = info.leaderName
    if leader and not secret(leader) then out[1] = { name = leader, leader = true } end
    if C_LFGList.GetSearchResultMemberInfo then
        for i = 1, (info.numMembers or 0) do
            local ok, a = pcall(C_LFGList.GetSearchResultMemberInfo, resultID, i)
            local name
            if ok then
                if type(a) == "table" then name = a.name
                elseif type(a) == "string" and not ROLE_WORDS[a] then name = a end
            end
            if name and not secret(name) and name ~= leader then out[#out + 1] = { name = name } end
        end
    end
    return out
end

local function UpdateBrowseRow(row, resultID)
    if not row then return end
    resultID = resultID or row.resultID or row.PRResultID
    local fs = RowScore(row)
    local key = resultID and PR.s.tooltip and PR:Normalize(LeaderName(resultID))
    if not key then fs:Hide() return end
    -- Listings are either a group (show "Leader") or a single player (just their rating).
    local info = C_LFGList.GetSearchResultInfo(resultID)
    local isGroup = info and (info.numMembers or 1) > 1
    fs:ClearAllPoints()
    fs:SetPoint("TOPRIGHT", row, "TOPRIGHT", -14, -10)
    fs:SetText(ScoreText(key, isGroup and "|cffaaaaaaLeader|r " or nil))
    fs:Show()
end

-- Our own small tooltip, placed under the game's tooltip so the two don't fight.
function UI:GroupTip()
    if not self.groupTip then
        self.groupTip = CreateFrame("GameTooltip", "ForeverRatingsGroupTip", UIParent, "GameTooltipTemplate")
    end
    return self.groupTip
end

local function ShowGroupTip(row)
    local rid = row.resultID or row.PRResultID
    if not rid or not PR.s.tooltip then return end
    local members = ListingMembers(rid)
    if #members == 0 then return end
    local tip = UI:GroupTip()
    tip:SetOwner(row, "ANCHOR_NONE")
    tip:ClearAllPoints()
    local blizz
    if GameTooltip:IsShown() and GameTooltip:GetOwner() == row then blizz = GameTooltip end
    if not blizz and LFGBrowseSearchEntryTooltip and LFGBrowseSearchEntryTooltip:IsShown() then blizz = LFGBrowseSearchEntryTooltip end
    if blizz then tip:SetPoint("TOPLEFT", blizz, "BOTTOMLEFT", 0, -2)
    else tip:SetPoint("TOPLEFT", row, "TOPRIGHT", 6, 0) end
    tip:AddLine("Forever Ratings", 1, 0.82, 0)
    local isGroup = #members > 1
    for _, m in ipairs(members) do
        local key = PR:Normalize(m.name)
        if key then
            tip:AddDoubleLine((isGroup and m.leader and "|cffaaaaaaLeader|r " or "") .. PR:ColoredName(m.name, PR.db.classes[key]),
                ("|T%s:11:11|t %s"):format(PR.STAR, PR:ShortSummary(key)), 1, 1, 1, 1, 1, 1)
        end
    end
    tip:Show()
end

local function HideGroupTip()
    if UI.groupTip then UI.groupTip:Hide() end
end

local function OnBrowseRow(_, row, elementData)
    row.PRResultID = row.resultID or IdFrom(elementData, "resultID", "id")
    UpdateBrowseRow(row, row.PRResultID)
    if not row.PRHooked then
        row.PRHooked = true
        row:HookScript("OnEnter", ShowGroupTip)
        row:HookScript("OnLeave", HideGroupTip)
    end
end

function UI:AttachBrowse()
    local bf = LFGBrowseFrame
    if not bf or self.browseAttached or not (ScrollUtil and ScrollUtil.AddInitializedFrameCallback) then return end
    local sb = bf.ScrollBox or (bf.SearchResults and bf.SearchResults.ScrollBox)
    if sb then
        ScrollUtil.AddInitializedFrameCallback(sb, OnBrowseRow, UI, true)
        self.browseAttached = true
        hooked["LFGBrowseFrame.ScrollBox"] = true
    end
end

-- Attach to the Group Finder's scrolling lists directly. This doesn't depend on Blizzard's
-- function names, which differ between client versions.
function UI:AttachScrollBoxes()
    self:AttachBrowse()
    local lf = LFGListFrame
    if not lf or not ScrollUtil or not ScrollUtil.AddInitializedFrameCallback then return end
    local search = lf.SearchPanel and lf.SearchPanel.ScrollBox
    if search and not self.searchAttached then
        ScrollUtil.AddInitializedFrameCallback(search, OnSearchRow, UI, true)
        self.searchAttached = true
        hooked["SearchPanel.ScrollBox"] = true
    end
    local apps = lf.ApplicationViewer and lf.ApplicationViewer.ScrollBox
    if apps and not self.appsAttached then
        ScrollUtil.AddInitializedFrameCallback(apps, OnApplicantRow, UI, true)
        self.appsAttached = true
        hooked["ApplicationViewer.ScrollBox"] = true
    end
end

-- Group Finder code can load late, so this runs again on every ADDON_LOADED.
function UI:TryHooks()
    self:AttachScrollBoxes()
    if PVEFrame and not self.pveHooked then
        self.pveHooked = true
        PVEFrame:HookScript("OnShow", function() UI:AttachScrollBoxes() end)
    end
    if LFGParentFrame and not self.lfgParentHooked then
        self.lfgParentHooked = true
        LFGParentFrame:HookScript("OnShow", function() UI:AttachScrollBoxes() end)
    end
    -- Named functions, if this client has them.
    Hook("LFGBrowseSearchEntry_Update", function(row) UpdateBrowseRow(row) end)
    Hook("LFGListSearchEntry_Update", function(row) UpdateSearchRow(row) end)
    Hook("LFGListApplicationViewer_UpdateApplicantMember", function(member, applicantID, memberIdx)
        UpdateMemberRow(member, applicantID, memberIdx)
    end)
    Hook("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
        local key = PR:Normalize(LeaderName(resultID))
        if key and PR:SummaryText(key) then
            UI:AddTooltip(tooltip, key, true)
            tooltip:Show()
        end
    end)
    Hook("LFGListApplicantMember_OnEnter", function(member)
        local parent = member and member:GetParent()
        if not parent or not parent.applicantID or not member.memberIdx then return end
        local key = PR:Normalize(ApplicantName(parent.applicantID, member.memberIdx))
        if key and PR:SummaryText(key) then
            UI:AddTooltip(GameTooltip, key, true)
            GameTooltip:Show()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Right-click menus
-- ---------------------------------------------------------------------------
local MENU_TAGS = {
    "MENU_UNIT_PLAYER", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_RAID", "MENU_UNIT_FRIEND", "MENU_UNIT_FRIEND_OFFLINE", "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS", "MENU_UNIT_CHAT_ROSTER", "MENU_UNIT_GUILD", "MENU_UNIT_GUILD_OFFLINE",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_COMMUNITIES_MEMBER", "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
    "MENU_LFG_FRAME_SEARCH_ENTRY", "MENU_LFG_FRAME_MEMBER_APPLY",
}

local function WhoFromMenu(owner, ctx)
    local name, class
    if ctx then
        if ctx.unit then
            local key, full, cls = PR:UnitKey(ctx.unit)
            if key then return key, full, cls end
        end
        if not ctx.bnetIDAccount and type(ctx.name) == "string" and not secret(ctx.name) then
            name = ctx.name
            if ctx.server and ctx.server ~= "" and not secret(ctx.server) then name = name .. "-" .. ctx.server end
        end
    end
    if not name and owner then
        if owner.resultID then
            name = LeaderName(owner.resultID)
        elseif owner.memberIdx then
            local parent = owner:GetParent()
            if parent and parent.applicantID then name = ApplicantName(parent.applicantID, owner.memberIdx) end
        end
    end
    local key, full = PR:Normalize(name)
    if key then return key, full, class end
end

function UI:HookMenus()
    if not (Menu and Menu.ModifyMenu) then return end
    for _, tag in ipairs(MENU_TAGS) do
        Menu.ModifyMenu(tag, function(owner, root, ctx)
            local ok, err = pcall(function()
                local key, full, class = WhoFromMenu(owner, ctx)
                if not key or key == PR:MyKey() then return end
                root:CreateDivider()
                root:CreateTitle("Forever Ratings")
                root:CreateButton("View ratings", function() UI:OpenViewer(full) end)
                if ns.Group:CanRate(key) and PR:CanIRate() then
                    root:CreateButton("Rate player...", function()
                        UI:OpenRate({ { key = key, name = full, class = class or PR.db.classes[key] } }, ns.Group:SeenWith(key))
                    end)
                end
            end)
            if not ok and err then geterrorhandler()(err) end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Rating window
-- ---------------------------------------------------------------------------
local MAX_ROWS = 8
local ROW_H = 58

local function RowRating(row)
    local r = PR:MyRating(row.member.key)
    row.stars = r and r.s or 0
    row.original = row.stars
    row.wait = (r and r.s > 0) and PR:ChangeWait(row.member.key) or 0
    row.comment:SetText(r and r.c or "")
    row.comment:SetEnabled(row.wait == 0)
end

local function PaintStars(row, hover)
    if row.wait > 0 then hover = nil end
    local n = hover or row.stars
    for i, b in ipairs(row.starBtns) do
        b.tex:SetDesaturated(i > n)
        if i <= n then b.tex:SetVertexColor(1, 1, 1) else b.tex:SetVertexColor(0.45, 0.45, 0.45) end
    end
    local words = { "Very low", "Low", "Okay", "Good", "Very high" }
    if row.wait > 0 then
        row.starText:SetText("|cff888888your vote, can change in " .. PR:Duration(row.wait) .. "|r")
    else
        row.starText:SetText(n > 0 and words[n] or "|cff888888not rated|r")
    end
end


function UI:RateFrame()
    if self.rate then return self.rate end
    local f = Window("ForeverRatingsRate", 600, 140, "Rate your group")
    self.rate = f
    f.header = Label(f, "", "GameFontHighlight")
    f.header:SetPoint("TOPLEFT", 16, -32)
    f.header:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.hint = Label(f, "1 star is very low, 5 is very high. You get one vote per player and can change it once a week. Ratings are public to everyone with the addon.", "GameFontDisableSmall")
    f.hint:SetPoint("TOPLEFT", f.header, "BOTTOMLEFT", 0, -4)
    f.hint:SetPoint("RIGHT", f, "RIGHT", -16, 0)

    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(570, ROW_H)
        row:SetPoint("TOPLEFT", 14, -70 - (i - 1) * ROW_H)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)

        row.name = Label(row, "", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", 4, -6)
        row.name:SetWidth(200)
        row.name:SetWordWrap(false)

        row.starBtns = {}
        for s = 1, 5 do
            local b = CreateFrame("Button", nil, row)
            b:SetSize(22, 22)
            b:SetPoint("TOPLEFT", 220 + (s - 1) * 24, -2)
            b.tex = b:CreateTexture(nil, "ARTWORK")
            b.tex:SetAllPoints()
            b.tex:SetTexture(PR.STAR)
            b:SetScript("OnClick", function()
                if row.wait > 0 then return end
                row.stars = (row.stars == s) and 0 or s
                PaintStars(row)
            end)
            b:SetScript("OnEnter", function() PaintStars(row, s) end)
            b:SetScript("OnLeave", function() PaintStars(row) end)
            row.starBtns[s] = b
        end
        row.starText = Label(row, "", "GameFontHighlightSmall")
        row.starText:SetPoint("LEFT", row.starBtns[5], "RIGHT", 8, 0)

        row.comment = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.comment:SetSize(540, 20)
        row.comment:SetPoint("TOPLEFT", 10, -30)
        row.comment:SetAutoFocus(false)
        row.comment:SetMaxBytes(PR.MAX_COMMENT)
        row.comment:SetScript("OnEscapePressed", row.comment.ClearFocus)
        row.comment:SetScript("OnEnterPressed", row.comment.ClearFocus)
        row.commentHint = Label(row.comment, "Comment (optional)", "GameFontDisableSmall")
        row.commentHint:SetPoint("LEFT", 2, 0)
        row.comment:SetScript("OnTextChanged", function(eb) row.commentHint:SetShown(eb:GetText() == "") end)
        f.rows[i] = row
    end

    f.submit = Button(f, "Submit", 100)
    f.submit:SetPoint("BOTTOMRIGHT", -14, 14)
    f.submit:SetScript("OnClick", function() UI:SubmitRatings() end)
    f.later = Button(f, "Not now", 100)
    f.later:SetPoint("RIGHT", f.submit, "LEFT", -6, 0)
    f.later:SetScript("OnClick", function() f:Hide() end)
    f.note = Label(f, "Reopen any time with /rate", "GameFontDisableSmall")
    f.note:SetPoint("BOTTOMLEFT", 16, 20)
    return f
end

-- members: list of { key, name, class }
function UI:OpenRate(members, dungeon)
    if not PR:CanIRate() then
        PR.Print(("you need to be level %d to rate players."):format(PR.MIN_LEVEL))
        return
    end
    local f = self:RateFrame()
    f.dungeon = dungeon or ""
    f.header:SetText(f.dungeon ~= "" and ("How was " .. f.dungeon .. "?") or "How did they do?")
    local shown = 0
    for i, row in ipairs(f.rows) do
        local m = members[i]
        if m and i <= MAX_ROWS and m.key ~= PR:MyKey() then
            shown = shown + 1
            row.member = m
            row.name:SetText(PR:ColoredName(m.name, m.class or PR.db.classes[m.key]))
            RowRating(row)
            PaintStars(row)
            row:Show()
        else
            row.member = nil
            row:Hide()
        end
    end
    if shown == 0 then PR.Print("Nobody to rate.") return end
    f:SetHeight(70 + shown * ROW_H + 50)
    f:Show()
end

function UI:SubmitRatings()
    local f = self.rate
    local count = 0
    for _, row in ipairs(f.rows) do
        local changed = row.stars ~= row.original or row.comment:GetText() ~= ((PR:MyRating(row.member and row.member.key or "") or {}).c or "")
        if row:IsShown() and row.member and row.stars > 0 and row.wait == 0 and changed then
            local ok, err = PR:Rate(row.member.name, row.stars, row.comment:GetText(), f.dungeon, row.member.class)
            if ok then count = count + 1 else PR.Print(err) end
        end
    end
    if count > 0 then
        PR.Print(("rated %d %s. Thanks!"):format(count, count == 1 and "player" or "players"))
    end
    f:Hide()
end

-- ---------------------------------------------------------------------------
-- Viewer
-- ---------------------------------------------------------------------------
local LIST_ROW_H = 20

function UI:Viewer()
    if self.viewer then return self.viewer end
    local f = Window("ForeverRatingsViewer", 760, 480, "Forever Ratings")
    self.viewer = f

    f.search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.search:SetSize(220, 22)
    f.search:SetPoint("TOPLEFT", 20, -32)
    f.search:SetAutoFocus(false)
    f.search:SetScript("OnEscapePressed", f.search.ClearFocus)
    f.search:SetScript("OnEnterPressed", function(eb)
        eb:ClearFocus()
        local key, name = PR:Normalize(eb:GetText())
        if key then UI:ShowPlayer(key, name) end
    end)
    f.search:SetScript("OnTextChanged", function(eb)
        UI.search = eb:GetText():lower()
        f.searchHint:SetShown(eb:GetText() == "")
        UI:RefreshList()
    end)
    f.searchHint = Label(f.search, "Search players", "GameFontDisableSmall")
    f.searchHint:SetPoint("LEFT", 4, 0)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -60)
    scroll:SetSize(236, 370)
    f.listContent = CreateFrame("Frame", nil, scroll)
    f.listContent:SetSize(236, 10)
    scroll:SetScrollChild(f.listContent)
    f.rows = {}

    -- Detail panel
    local X = 276
    f.title = Label(f, "", "GameFontHighlightLarge")
    f.title:SetPoint("TOPLEFT", X, -34)
    f.title:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.summary = Label(f, "", "GameFontHighlight")
    f.summary:SetPoint("TOPLEFT", X, -60)
    f.summary:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.summary:SetSpacing(3)

    local ds = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    ds:SetPoint("TOPLEFT", X, -130)
    ds:SetPoint("BOTTOMRIGHT", -34, 46)
    f.detailContent = CreateFrame("Frame", nil, ds)
    f.detailContent:SetSize(440, 10)
    ds:SetScrollChild(f.detailContent)
    f.detail = Label(f.detailContent, "", "GameFontHighlightSmall")
    f.detail:SetPoint("TOPLEFT", 0, 0)
    f.detail:SetWidth(440)
    f.detail:SetSpacing(3)

    f.rateBtn = Button(f, "Rate", 90)
    f.rateBtn:SetPoint("BOTTOMLEFT", X, 14)
    f.rateBtn:SetScript("OnClick", function()
        local key, name = UI.selKey, UI.selName
        UI:OpenRate({ { key = key, name = name, class = PR.db.classes[key] } }, ns.Group:SeenWith(key))
    end)
    f.withdrawBtn = Button(f, "Withdraw my rating", 150)
    f.withdrawBtn:SetPoint("LEFT", f.rateBtn, "RIGHT", 6, 0)
    f.withdrawBtn:SetScript("OnClick", function() PR:Withdraw(UI.selName) end)

    f.status = Label(f, "", "GameFontDisableSmall")
    f.status:SetPoint("BOTTOMLEFT", 16, 20)
    f.status:SetWidth(240)

    f:SetScript("OnShow", function() UI:Refresh() end)
    return f
end

function UI:RatedPlayers()
    if not PR.byTarget then PR:BuildIndex() end
    local list = {}
    for tKey, recs in pairs(PR.byTarget) do
        local name, n = nil, 0
        for k in pairs(recs) do
            local r = PR.db.records[k]
            if r and r.s > 0 then name = name or r.t; n = n + 1 end
        end
        if n > 0 and (UI.search == "" or tKey:find(UI.search, 1, true)) then
            list[#list + 1] = { key = tKey, name = name, n = n }
        end
    end
    table.sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.key < b.key
    end)
    return list
end

function UI:RefreshList()
    local f = self.viewer
    if not f or not f:IsShown() then return end
    local list = self:RatedPlayers()
    for i, p in ipairs(list) do
        local row = f.rows[i]
        if not row then
            row = CreateFrame("Button", nil, f.listContent)
            row:SetSize(232, LIST_ROW_H)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * LIST_ROW_H)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints()
            row.sel:SetColorTexture(1, 0.82, 0, 0.18)
            row.name = Label(row, "", "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", 4, 0)
            row.name:SetWidth(110)
            row.name:SetWordWrap(false)
            row.score = Label(row, "", "GameFontHighlightSmall")
            row.score:SetPoint("RIGHT", -4, 0)
            row.score:SetJustifyH("RIGHT")
            row:SetScript("OnClick", function(b) UI:ShowPlayer(b.key, b.pname) end)
            f.rows[i] = row
        end
        row.key, row.pname = p.key, p.name
        row.name:SetText(PR:ColoredName(p.name, PR.db.classes[p.key]))
        row.score:SetText(PR:ShortSummary(p.key))
        row.sel:SetShown(p.key == self.selKey)
        row:Show()
    end
    for i = #list + 1, #f.rows do f.rows[i]:Hide() end
    f.listContent:SetHeight(math.max(10, #list * LIST_ROW_H))
    f.status:SetText(#list .. " rated players. " .. (ns.Net:ChannelId() and "Connected." or "Not connected yet."))
end

function UI:ShowPlayer(key, name)
    local f = self:Viewer()
    self.selKey, self.selName = key, name
    if not key then
        f.title:SetText("Pick a player")
        f.summary:SetText("")
        f.detail:SetText("")
        f.rateBtn:Hide()
        f.withdrawBtn:Hide()
        return
    end
    f.title:SetText(PR:ColoredName(name, PR.db.classes[key]))
    f.summary:SetText(PR:SummaryText(key))

    local out = {}
    for _, r in ipairs(PR:RatingsFor(key)) do
        local head = ("%s  %s  |cff888888%s%s|r"):format(PR:StarsText(r.s, 12),
            PR:ShortName(r.a), date("%Y-%m-%d", r.ts), r.d ~= "" and ("  " .. r.d) or "")
        if not r.v then
            head = head .. "  |cffff9933unverified|r" .. (r.via and ("|cff888888, passed on by " .. PR:ShortName(r.via) .. "|r") or "")
        elseif not PR:Counts(r) then
            local lvl, src = PR:LevelOf(PR:Normalize(r.a))
            head = head .. ("  |cff888888not counted: rater %s|r"):format(
                lvl and ("is level " .. lvl .. (src == "claimed" and " (their claim)" or "")) or "level unknown")
        end
        out[#out + 1] = head
        if r.c ~= "" then out[#out + 1] = "    |cffdddddd" .. r.c .. "|r" end
        out[#out + 1] = " "
    end
    f.detail:SetText(#out > 0 and table.concat(out, "\n") or "")
    f.detailContent:SetHeight(math.max(10, f.detail:GetStringHeight() + 10))

    f.rateBtn:SetShown(ns.Group:CanRate(key) and PR:CanIRate())
    local mine = PR:MyRating(key)
    f.withdrawBtn:SetShown(mine and mine.s > 0 or false)
    self:RefreshList()
end

function UI:Refresh()
    if self.viewer and self.viewer:IsShown() then
        self:RefreshList()
        -- Nothing picked: show your own score.
        if self.selKey then self:ShowPlayer(self.selKey, self.selName) else self:ShowPlayer(PR:MyKey()) end
    end
end

function UI:OpenViewer(name)
    local f = self:Viewer()
    f:Show()
    local key, full = PR:Normalize(name)
    if key then self:ShowPlayer(key, full) end
end

function UI:ToggleViewer()
    local f = self:Viewer()
    f:SetShown(not f:IsShown())
end

-- Popup with selectable text (Ctrl+A is done for you, then Ctrl+C to copy).
function UI:ShowCopy(title, text)
    local f = self.copy
    if not f then
        f = Window("ForeverRatingsCopy", 620, 420, title)
        f:SetFrameStrata("DIALOG")
        self.copy = f
        local hint = Label(f, "Press Ctrl+C to copy, then paste it into your message.", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", 16, -32)
        local area = CreateFrame("Frame", nil, f, "BackdropTemplate")
        area:SetPoint("TOPLEFT", 12, -50)
        area:SetPoint("BOTTOMRIGHT", -12, 44)
        area:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        area:SetBackdropColor(0, 0, 0, 0.6)
        local sf = CreateFrame("ScrollFrame", nil, area, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 8, -8)
        sf:SetPoint("BOTTOMRIGHT", -28, 8)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(540)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        -- Keep the text as-is if someone types into it.
        eb:SetScript("OnTextChanged", function(self, user)
            if user and f.text then self:SetText(f.text); self:HighlightText() end
        end)
        sf:SetScrollChild(eb)
        area:EnableMouse(true)
        area:SetScript("OnMouseDown", function() eb:SetFocus(); eb:HighlightText() end)
        f.edit = eb
        local selectAll = Button(f, "Select all", 100)
        selectAll:SetPoint("BOTTOMLEFT", 14, 14)
        selectAll:SetScript("OnClick", function() eb:SetFocus(); eb:HighlightText() end)
        local close = Button(f, "Close", 100)
        close:SetPoint("BOTTOMRIGHT", -14, 14)
        close:SetScript("OnClick", function() f:Hide() end)
    end
    if f.TitleText then f.TitleText:SetText(title) end
    f.text = text
    f.edit:SetText(text)
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
end

function UI:Init()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
        self.tooltipHook = "TooltipDataProcessor"
    else
        GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
        self.tooltipHook = "OnTooltipSetUnit"
    end
    self:HookMenus()
    self:TryHooks()
end
