-- Chillzone: общая очередь заявок офицеров своей гильдии. JQ запрашивает снимок,
-- JS передаёт заявку, JX — закрытие. Текст идёт только адресным шёпотом офицерам.
-- Это сообщения о наборе, не сертификаты и не право доступа к подписанной сети.
local ADDON, ns = ...

local R, U, Codec = ns.Recruit, ns.Util, ns.Codec
local Sync = {}
ns.RecruitSync = Sync

local owned, closed, outgoing, answered = {}, {}, {}, {}
local serial, epoch, peerCursor = 0, 0, 0
local session, activeGuild, wasOfficer
local lastQuery = -math.huge
local knownOfficers = {}

local function Field(s) return (Codec.Plain(s):gsub("[~]", "")) end
local function Member(name)
	return ns.IsMember() and ns.Roster.Fresh() and ns.Roster.RankOf(name) ~= nil
end
function Sync.IsOfficer(name)
	name = name or ns.me
	local rank
	if ns.IsMe(name) then rank = ns.Roster.MyRank() else rank = ns.Roster.RankOf(name) end
	return Member(name) and ns.Roster.IsOfficerRank(rank)
end
local function Online(name)
	for _, m in ipairs(ns.Roster.members) do
		if U.SameName(m.name, name) then return m.online end
	end
	return false
end
local function Officers(fn)
	if not ns.IsMember() or not ns.Roster.Fresh() then return end
	for _, m in ipairs(ns.Roster.members) do
		if m.online and not ns.IsMe(m.name) and Sync.IsOfficer(m.name) then fn(m.name) end
	end
end
local function Pending(req)
	local decision = closed[U.Key(req.name)]
	return not decision or req.created > decision.at
end
local function CanShare(req)
	if req.guild ~= ns.MyGuild() or not Pending(req) then return false end
	if ns.IsMe(req.origin) and owned[req.id] == req then return true end
	if not Sync.IsOfficer() then return false end
	for _, current in ipairs(R.requests) do if current == req then return true end end
	return false
end

function Sync.Pack(req)
	return table.concat({ "JS", "1", Field(req.guild), Field(req.origin), Field(req.id), tostring(req.created),
		tostring(req.rev), Field(req.name), tostring(req.level), Field(req.class), req.sharedText or "" }, "~")
end
local function PackClosed(item)
	return table.concat({ "JX", "1", Field(item.guild), Field(item.name), tostring(item.at) }, "~")
end

-- У каждого адресата — очередь ссылок, а не сотни готовых заданий Comm. Снимок
-- любого размера передаётся постепенно; обновление ещё не отправленной заявки заменяет её.
local function Enqueue(to, key, item)
	if ns.IsMe(to) then return end
	local pk = U.Key(to)
	local task = outgoing[pk]
	if not task then
		task = { to = to, guild = ns.MyGuild(), order = {}, urgent = {}, pending = {}, cursor = 1, urgentCursor = 1, count = 0 }
		outgoing[pk] = task
	end
	if not task.pending[key] then
		local order = item.decision and task.urgent or task.order
		order[#order + 1] = key
		task.count = task.count + 1
	end
	task.pending[key] = item
end
local function QueueRequest(to, req)
	Enqueue(to, req.id, { req = req })
end
local function QueueClosed(to, decision, allowMember)
	Enqueue(to, "closed:" .. U.Key(decision.name), { decision = decision, allowMember = allowMember })
end

function Sync.Publish(req)
	if not Member(ns.me) then return end
	if not req.id then
		serial = serial + 1
		session = session or (tostring(ns.ServerTime()) .. "-" .. tostring(U.Hash(tostring({}) .. ns.Now())))
		req.id = ns.myKey .. ":" .. session .. ":" .. serial
		req.origin, req.created, req.rev = ns.me, ns.ServerTime() - math.max(0, math.floor(ns.Now() - req.t)), 0
		req.syncText = req.sharedText
		for id, old in pairs(owned) do if U.SameName(old.name, req.name) then owned[id] = nil end end
	elseif req.sharedText ~= req.syncText then
		req.rev, req.syncText = req.rev + 1, req.sharedText
	end
	owned[req.id] = req
	Officers(function(to) QueueRequest(to, req) end)
end

local function ApplyClosed(name, at)
	local key = U.Key(name)
	if closed[key] and closed[key].at >= at then return false end
	closed[key] = { guild = ns.MyGuild(), name = name, at = at }
	for id, req in pairs(owned) do
		if U.SameName(req.name, name) and req.created <= at then owned[id] = nil end
	end
	R.RemoveShared(name, at)
	return true
end
function Sync.Closed(req)
	if not Sync.IsOfficer() then return end
	local at = math.max(ns.ServerTime(), req.created or 0)
	if not ApplyClosed(req.name, at) then return end
	local decision = closed[U.Key(req.name)]
	Officers(function(to) QueueClosed(to, decision) end)
	-- Первоначальный адресат мог быть рядовым. Он тоже забывает обработанную заявку.
	if req.origin and Member(req.origin) and not ns.IsMe(req.origin) then QueueClosed(req.origin, decision, true) end
end
function Sync.Joined(req)
	if req.id then owned[req.id] = nil end
	Sync.Closed(req)
end

function Sync.OnShared(msg, sender, dist, ctx)
	if dist ~= "WHISPER" or ctx or not Sync.IsOfficer() or not Member(sender) or #msg > 1200 then return false end
	local guild, origin, id, created, rev, name, level, class, text = msg:match(
		"^JS~1~([^~]+)~([^~]+)~([^~]+)~(%d+)~(%d+)~([^~]+)~(%d+)~([A-Z]*)~(.*)$")
	if not guild or U.GuildKey(guild) ~= U.GuildKey(ns.MyGuild()) then return false end
	if #origin > 120 or #id > 220 or #name > 120 or #text > 250 then return false end
	if id:sub(1, #(U.Key(origin) or "") + 1) ~= (U.Key(origin) or "") .. ":" then return false end
	if not U.SameName(sender, origin) and not Sync.IsOfficer(sender) then return false end
	created, rev, level = tonumber(created), tonumber(rev), tonumber(level)
	if not created or created > ns.ServerTime() + 300 or not rev or rev > 1000000 then return false end
	if not level or level < 1 or level > 255 or (class ~= "" and not ns.L.CLASS[class]) then return false end
	if ns.Roster.RankOf(name) ~= nil then return false end
	local req = { guild = ns.MyGuild(), origin = U.Normal(origin), id = id, created = created, rev = rev,
		name = U.Normal(name), level = level, class = class, text = text ~= "" and Codec.Plain(text) or nil,
		sharedText = text ~= "" and Codec.Plain(text) or nil,
		t = ns.Now() - math.max(0, ns.ServerTime() - created) }
	if not Pending(req) then return false end
	return R.AddShared(req)
end
ns.Comm.On("JS", Sync.OnShared)

function Sync.OnClosed(msg, sender, dist, ctx)
	if dist ~= "WHISPER" or ctx or not Sync.IsOfficer(sender) or #msg > 500 then return false end
	local guild, name, at = msg:match("^JX~1~([^~]+)~([^~]+)~(%d+)$")
	if not guild or U.GuildKey(guild) ~= U.GuildKey(ns.MyGuild()) or #name > 120 then return false end
	at = tonumber(at)
	if not at or at > ns.ServerTime() + 300 then return false end
	if not Sync.IsOfficer() then
		local mine = false
		for _, req in pairs(owned) do if U.SameName(req.name, name) then mine = true end end
		if not mine then return false end
	end
	return ApplyClosed(U.Normal(name), at)
end
ns.Comm.On("JX", Sync.OnClosed)

local function Snapshot(sender)
	local key = U.Key(sender)
	if outgoing[key] and outgoing[key].snapshot then return true end
	if Sync.IsOfficer() then
		for _, decision in pairs(closed) do QueueClosed(sender, decision) end
		for _, req in ipairs(R.Requests()) do if CanShare(req) then QueueRequest(sender, req) end end
	end
	for _, req in pairs(owned) do if CanShare(req) then QueueRequest(sender, req) end end
	if outgoing[key] then outgoing[key].snapshot = true end
	return true
end
function Sync.OnQuery(msg, sender, dist, ctx)
	if dist ~= "GUILD" or ctx or not Sync.IsOfficer(sender) then return false end
	if msg ~= "JQ~1~" .. Field(ns.MyGuild()) then return false end
	local key, now = U.Key(sender), ns.Now()
	if answered[key] and now - answered[key] < 30 then return false end
	answered[key] = now
	return Snapshot(sender)
end
ns.Comm.On("JQ", Sync.OnQuery)

function Sync.RequestSync()
	if not Sync.IsOfficer() or ns.Now() - lastQuery < 30 then return false end
	local guild = ns.MyGuild()
	local ok = ns.Comm.Send("GUILD", "JQ~1~" .. Field(guild), {
		key = "recruit query", guard = function() return guild == ns.MyGuild() and Sync.IsOfficer() end,
	})
	if ok then lastQuery = ns.Now() end
	return ok
end

local function Eligible(task, item)
	if task.guild ~= ns.MyGuild() or not Member(task.to) or not Online(task.to) then return false end
	if item.req then return Sync.IsOfficer(task.to) and CanShare(item.req) end
	return Sync.IsOfficer() and (Sync.IsOfficer(task.to) or item.allowMember)
end
function Sync.Pump()
	if not Member(ns.me) then return end
	for _ = 1, 4 do
		if ns.Comm.QueueSize() >= 24 then return end
		local peers = {}
		for key in pairs(outgoing) do peers[#peers + 1] = key end
		table.sort(peers)
		if #peers == 0 then return end
		peerCursor = peerCursor % #peers + 1
		local pk = peers[peerCursor]
		local task = outgoing[pk]
		-- Решения обходят снимок и здесь, и в очереди транспорта.
		local key = task.urgent[task.urgentCursor]
		if key then task.urgentCursor = task.urgentCursor + 1
		else key = task.order[task.cursor]; task.cursor = task.cursor + 1 end
		local item = task.pending[key]
		task.pending[key], task.count = nil, task.count - 1
		if task.count == 0 then outgoing[pk] = nil end
		if item and Eligible(task, item) then
			local token = epoch
			ns.Comm.Send("WHISPER", item.req and Sync.Pack(item.req) or PackClosed(item.decision), {
				target = task.to, logged = item.req ~= nil, prio = item.decision ~= nil,
				guard = function() return token == epoch and Eligible(task, item) end,
				done = function(ok)
					if not ok and token == epoch and Eligible(task, item) then Enqueue(task.to, key, item) end
				end,
			})
		end
	end
end

local function Reset()
	owned, closed, outgoing, answered = {}, {}, {}, {}
	knownOfficers = {}
	activeGuild, wasOfficer, lastQuery, epoch = nil, false, -math.huge, epoch + 1
end
ns.On("GUILD_CHANGED", Reset)
local function RefreshOfficers()
	local guild = ns.MyGuild()
	if activeGuild and activeGuild ~= guild then Reset() end
	activeGuild = guild
	if ns.Roster.Fresh() then
		for _, req in pairs(owned) do
			if ns.Roster.RankOf(req.name) ~= nil then Sync.Joined(req) end
		end
	end
	local officer = Sync.IsOfficer()
	if wasOfficer and not officer then
		closed, outgoing, epoch = {}, {}, epoch + 1
		R.KeepLocal()
	end
	if officer and not wasOfficer then lastQuery = -math.huge; Sync.RequestSync() end
	wasOfficer = officer
	local current = {}
	Officers(function(to)
		local key = U.Key(to)
		current[key] = true
		if not knownOfficers[key] then Snapshot(to) end
	end)
	knownOfficers = current
end
ns.On("ROSTER", RefreshOfficers)
ns.On("UNION", RefreshOfficers)
ns.On("LOGIN", function()
	ns.Every(1.2, "заявки: передача очереди", Sync.Pump, true)
	ns.Every(120, "заявки: сверка очереди", Sync.RequestSync)
end)
