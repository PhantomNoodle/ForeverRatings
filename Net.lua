local ADDON, ns = ...
local PR = ns.PR

--[[
How ratings travel
------------------
Every copy of the addon joins a hidden chat channel and talks over addon messages.

  R  <target> <stars> <time> <dungeon> <comment> <sender level>
     A rating sent by its own author. The game server tells us who sent an
     addon message and it can't be faked, so this rating is "verified".
  F  <author> <target> <stars> <time> <dungeon> <comment>
     A rating passed along by someone else (catch-up for people who were offline).
     Stored as "unverified" and left out of the score until its author sends it themselves.
  Q  <since> <sender level>
     "I was away, send me what's new." A couple of online peers answer.

On login you send Q and re-send the ratings you wrote (at most every 6 hours),
so anyone who only had a relayed copy gets the verified one.
]]

local PREFIX = "PRATE2"       -- v2: one overall rating per player (v1 had per-role ratings)
local CHANNEL = "PlayerRatingsNet"
local SEND_RATE = 1          -- messages per second (the game throttles addon messages)
local BURST = 4
local MAX_SYNC_REPLY = 150   -- records per catch-up answer
local MAX_REPUBLISH = 200
local REPUBLISH_EVERY = 6 * 3600
local SENDER_LIMIT = 400     -- messages per sender per 10 minutes before we stop listening to them

local Net = { queue = {}, tokens = BURST, peers = {}, senders = {}, answered = {}, pauseUntil = 0 }
ns.Net = Net

local secret = PR.secret

local function split(msg)
    local t = {}
    for f in (msg .. "\t"):gmatch("(.-)\t") do t[#t + 1] = f end
    return t
end

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end

-- ---------------------------------------------------------------------------
-- Channel
-- ---------------------------------------------------------------------------
function Net:ChannelId()
    local id = GetChannelName(CHANNEL)
    if type(id) == "number" and id > 0 then return id end
end

function Net:HideChannel()
    local remove = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
    if not remove then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local f = _G["ChatFrame" .. i]
        if f then pcall(remove, f, CHANNEL) end
    end
end

function Net:Join()
    if not self:ChannelId() then
        pcall(JoinTemporaryChannel, CHANNEL)
    end
    C_Timer.After(2, function() Net:HideChannel() end)
end

-- ---------------------------------------------------------------------------
-- Sending (throttled queue)
-- ---------------------------------------------------------------------------
function Net:Enqueue(msg, chatType, target)
    if #msg > 255 then return end
    self.queue[#self.queue + 1] = { msg = msg, type = chatType or "CHANNEL", target = target, tries = 0 }
end

function Net:Pump()
    self.tokens = math.min(BURST, self.tokens + SEND_RATE * 0.25)
    if GetTime() < self.pauseUntil then return end
    while self.tokens >= 1 and #self.queue > 0 do
        local m = self.queue[1]
        local target = m.target
        if m.type == "CHANNEL" then
            target = self:ChannelId()
            if not target then return end
        end
        local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, m.msg, m.type, target)
        if ok and (res == nil or res == true or res == 0) then
            table.remove(self.queue, 1)
            self.tokens = self.tokens - 1
        else
            -- Throttled, or chat is locked (boss fight, keystone): wait and retry.
            m.tries = m.tries + 1
            if m.tries >= 30 then table.remove(self.queue, 1) end
            self.pauseUntil = GetTime() + 5
            return
        end
    end
end

local function Field(s, maxBytes) return PR.Clean(s, maxBytes) end

local function MyLevel() return UnitLevel("player") or 0 end

-- The last field is the sender's level (checked against what the game shows us when we can).
function Net:EncodeR(r)
    return table.concat({ "R", r.t, r.s, r.ts,
        Field(r.d, PR.MAX_DUNGEON), Field(r.c, PR.MAX_COMMENT), MyLevel() }, "\t")
end

function Net:EncodeF(r)
    return table.concat({ "F", r.a, r.t, r.s, r.ts,
        Field(r.d, PR.MAX_DUNGEON), Field(r.c, PR.MAX_COMMENT) }, "\t")
end

-- Send a rating you wrote.
function Net:Publish(r)
    self:Enqueue(self:EncodeR(r))
end

function Net:IsMine(r)
    return PR:Normalize(r.a) == PR:MyKey()
end

function Net:Republish(force)
    local db = PR.db
    if not force and time() - (db.lastRepublish or 0) < REPUBLISH_EVERY then return end
    db.lastRepublish = time()
    local mine = {}
    for _, r in pairs(db.records) do
        if self:IsMine(r) then mine[#mine + 1] = r end
    end
    table.sort(mine, function(a, b) return a.ts > b.ts end)
    for i = 1, math.min(#mine, MAX_REPUBLISH) do self:Publish(mine[i]) end
end

function Net:RequestSync(verbose)
    local since = math.max(0, (PR.db.lastActive or 0) - 2 * 86400)
    self:Enqueue("Q\t" .. since .. "\t" .. MyLevel())
    if verbose then PR.Print("asked the network for ratings since " .. (since > 0 and date("%Y-%m-%d", since) or "the beginning") .. ".") end
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------
function Net:PeerCount()
    local n, now = 0, GetTime()
    for _, t in pairs(self.peers) do
        if now - t < 3600 then n = n + 1 end
    end
    return n
end

function Net:AllowSender(key)
    local now = GetTime()
    local s = self.senders[key]
    if not s or now - s.start > 600 then
        s = { start = now, n = 0 }
        self.senders[key] = s
    end
    s.n = s.n + 1
    return s.n <= SENDER_LIMIT
end

function Net:OnQuery(fromKey, since)
    local now = GetTime()
    if self.answered[fromKey] and now - self.answered[fromKey] < 600 then return end
    -- Spread the work: about two online peers answer each request.
    local peers = math.max(1, self:PeerCount())
    if hash(PR:MyKey() .. fromKey .. since) % peers >= 2 then return end
    self.answered[fromKey] = now

    local list = {}
    for _, r in pairs(PR.db.records) do
        if r.v and r.ts > since then list[#list + 1] = r end   -- only pass on what we verified ourselves
    end
    table.sort(list, function(a, b) return a.ts > b.ts end)
    for i = 1, math.min(#list, MAX_SYNC_REPLY) do
        local r = list[i]
        if self:IsMine(r) then self:Enqueue(self:EncodeR(r)) else self:Enqueue(self:EncodeF(r)) end
    end
end

function Net:OnMessage(prefix, msg, chatType, sender)
    if prefix ~= PREFIX then return end
    if secret(msg) or secret(sender) or type(msg) ~= "string" then return end
    local sKey, sName = PR:Normalize(sender)
    if not sKey or sKey == PR:MyKey() then return end
    if not self:AllowSender(sKey) then return end
    self.peers[sKey] = GetTime()
    PR.db.lastActive = time()

    local f = split(msg)
    local kind = f[1]
    if kind == "R" then
        PR:NoteLevel(sKey, f[7], false)
        PR:Merge({ a = sName, t = f[2], s = f[3], ts = f[4], d = f[5], c = f[6] }, true)
    elseif kind == "F" then
        -- A relay of the sender's own rating is as good as first-hand.
        local fromAuthor = PR:Normalize(f[2]) == sKey
        PR:Merge({ a = f[2], t = f[3], s = f[4], ts = f[5], d = f[6], c = f[7] }, fromAuthor, sName)
    elseif kind == "Q" then
        PR:NoteLevel(sKey, f[3], false)
        self:OnQuery(sKey, tonumber(f[2]) or 0)
    end
end

function Net:StatusText()
    local id = self:ChannelId()
    return ("Network: %s, %d peers seen in the last hour, %d messages waiting."):format(
        id and ("joined (channel " .. id .. ")") or "|cffff6666not joined|r", self:PeerCount(), #self.queue)
end

function Net:Init()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:RegisterEvent("CHANNEL_UI_UPDATE")
    f:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            Net:OnMessage(...)
        else
            Net:HideChannel()
        end
    end)
    C_Timer.NewTicker(0.25, function() Net:Pump() end)
    C_Timer.After(8, function() Net:Join() end)
    C_Timer.After(20, function()
        Net:RequestSync(false)
        Net:Republish(false)
    end)
end
