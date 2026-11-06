-- Chillzone: перепись. Привет H1 в гильдию, выборы репортёра (один на гильдию),
-- отчёты через реле, запрос Q1 при входе и ответы на него из кэша.
-- Расписание и выборы — по образцу Olympus Comm.lua.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Census = {}
ns.Census = Census

local peers = {} -- [Key] = { t, z, r, name, version }: согильдийцы с аддоном
local lastSent, lastSentAt = nil, -1e9
local lastQ1Answer = -1e9
local trustCatchupPending = false

function Census.Peers()
	return peers
end

local function Live(now)
	local out = {}
	for k, p in pairs(peers) do
		if now - p.t <= C.PEER_WINDOW then out[k] = p end
	end
	return out
end

-- Сколько согильдийцев с аддоном на связи (вместе со мной).
function Census.Users()
	local n = 1
	for _ in pairs(Live(ns.Now())) do n = n + 1 end
	return n
end

-- Кандидат в репортёры: глава, офицер или связной по моему ростеру; пока
-- Config.TRUST_ANY_MEMBER — любой согильдиец из ростера.
local function Trusted(key)
	return ns.Roster.TrustOfKey(key) ~= nil
end

function Census.Reporter()
	if not ns.myKey then return nil end
	local now = ns.Now()
	local live = Live(now)
	local officers = ns.Roster.Fresh() and ns.Roster.IsOfficerRank(ns.Roster.RankOf(ns.me))
	for key in pairs(live) do
		if ns.Roster.IsOfficerRank(ns.Roster.byKey[key]) then officers = true end
	end
	local function eligible(key)
		if not Trusted(key) then return false end
		return not officers or ns.Roster.IsOfficerRank(ns.Roster.byKey[key])
	end
	return Codec.PickReporter(ns.myKey, ns.char and ns.char.shareZones or false, live, now, C.PEER_WINDOW, eligible)
end

function Census.IsReporter()
	if not ns.IsMember() or not ns.loginAt then return false end
	if ns.Now() - ns.loginAt < C.LOGIN_QUIET then return false end
	return Census.Reporter() == ns.myKey
end

-- Имя репортёра для показа.
function Census.ReporterName()
	local key = Census.Reporter()
	if not key then return nil end
	if key == ns.myKey then return U.Display(ns.me) end
	return peers[key] and U.Display(peers[key].name) or key
end

function Census.SendHello()
	if not ns.IsMember() then return end
	local R = ns.Relay
	local hello = Codec.EncodeHello(ns.VERSION, ns.char.shareZones, R and R.IAmRelay() or false)
	ns.Comm.Send("GUILD", hello, { key = "hello" })
end

ns.Comm.On("H1", function(msg, sender, dist)
	if dist ~= "GUILD" then return end
	local h = Codec.DecodeHello(msg)
	if not h then return end
	local key = U.Key(sender)
	local known = peers[key]
	peers[key] = { t = ns.Now(), z = h.zones, r = h.relay, name = sender, version = h.version }
	-- Новый согильдиец с аддоном: ответить своим приветом, чтобы выборы сошлись быстрее.
	if not known then ns.After(math.random(2, 6), "hello back", Census.SendHello) end
end)

---------------------------------------------------------------------------
-- Отчёты
---------------------------------------------------------------------------

function Census.MaybeReport(force)
	if not Census.IsReporter() then return end
	local r = ns.Roster.report
	if not r then return end
	local now = ns.Now()
	if not force and now - lastSentAt < C.REPORT_EVERY - 5 then return end
	r.users = Census.Users()
	local shareable = Codec.Shareable(r, ns.char.shareZones)
	local raw = Codec.EncodeReport(shareable)
	-- Время исключаем только из сравнения, не из отправляемого отчёта.
	-- Shareable вернул копию: время ростера и все поля (включая связных) сохраняются.
	shareable.st = 0
	local body = Codec.EncodeReport(shareable)
	if not force and body == lastSent and now - lastSentAt < C.REPORT_IDLE then return end
	lastSent, lastSentAt = body, now
	ns.Security.Seal(raw, function(wire)
		Census.lastRaw = wire
		ns.Relay.EnsureRegistered()
		ns.Relay.Out("L", wire)
	end)
	ns.Log("отчёт отправлен: %d/%d онлайн", r.online, r.total)
end

ns.On("ROSTER", function(r)
	if ns.IsMember() then ns.Data.SetLocal(r) end
end)

-- Чужой отчёт приходит только внутри конверта реле.
ns.Comm.On("R1", function(msg, sender, dist, ctx)
	if dist ~= "RELAY" or not ctx or not ctx.authenticated then return end
	local r = Codec.DecodeReport(msg)
	if not r then return end
	local ok, why = ns.Data.Take(r, msg, sender, nil, ctx)
	if not ok and why ~= "повтор" then ns.Log("отчёт %s от %s не принят: %s", r.guild, U.Display(sender), tostring(why)) end
end)

---------------------------------------------------------------------------
-- Q1: вошедший просит у репортёра своей гильдии всё, что тот знает.
---------------------------------------------------------------------------
ns.Comm.On("Q1", function(_, sender, dist)
	if dist ~= "GUILD" or not Census.IsReporter() then return end
	local now = ns.Now()
	if now - lastQ1Answer < C.Q1_GAP then return end
	if #ns.Data.Cached() == 0 then return end
	lastQ1Answer = now
	ns.Security.ShareTrust() -- native officer policy and reporter identity precede the cached envelopes
	for _, c in ipairs(ns.Data.Cached()) do
		ns.Comm.Send("GUILD", Codec.EncodeRM("RG", "L", c.origin, c.raw), { key = "q1:" .. c.key })
	end
end)

-- Reports received before a new root was approved were correctly rejected.
-- Recover them once from the local reporter, after its normal Q1 cooldown.
-- Several roots arriving together share one request; no author is contacted.
ns.On("AUTH_ROOT", function()
	if trustCatchupPending then return end
	trustCatchupPending = true
	ns.After(C.Q1_GAP + math.random(5, 15), "census after trust bootstrap", function()
		trustCatchupPending = false
		if not ns.IsMember() then return end
		for _, root in pairs(ns.Security.Roots()) do
			local row = ns.Data.Row(root.guild)
			if not row or not row.r then
				ns.Comm.Send("GUILD", "Q1~", { key = "census-request" })
				return
			end
		end
	end)
end)

---------------------------------------------------------------------------
-- Расписание
---------------------------------------------------------------------------
ns.On("LOGIN", function()
	ns.After(3, "first hello", Census.SendHello)
	ns.After(15, "census ask", function()
		if ns.IsMember() then ns.Comm.Send("GUILD", "Q1~") end
	end)
	ns.After(35, "census ask after trust bootstrap", function()
		if ns.IsMember() then ns.Comm.Send("GUILD", "Q1~", { key = "census-request" }) end
	end)
	ns.Every(C.HELLO_EVERY, "hello", Census.SendHello)
	ns.Every(10, "report check", function() Census.MaybeReport(false) end)
	ns.Every(300, "prune", function() ns.Data.Prune() end)
end)

ns.On("GUILD_CHANGED", function()
	wipe(peers)
	lastSent, lastSentAt = nil, -1e9
	ns.After(3, "hello after guild change", Census.SendHello)
end)

ns.Command("zones", function(arg)
	arg = U.Fold(U.Trim(arg))
	if arg == "on" or arg == "вкл" then
		ns.char.shareZones = true
	elseif arg == "off" or arg == "выкл" then
		ns.char.shareZones = false
	else
		ns.Print(ns.char.shareZones and L.ZONES_IS_ON or L.ZONES_IS_OFF)
		return
	end
	ns.Print(ns.char.shareZones and L.ZONES_ON or L.ZONES_OFF)
	Census.SendHello()
	lastSent = nil
	ns.Fire("DATA")
end, L.HELP_ZONES)

ns.Status(function()
	local n = 0
	for _ in pairs(Live(ns.Now())) do n = n + 1 end
	return L.STATUS_CENSUS:format(Census.ReporterName() or "—", Census.IsReporter() and L.YES or L.NO, n, ns.char.shareZones and L.YES or L.NO)
end)

ns.Status(function()
	if not ns.IsMember() then return nil end
	if C.TRUST_ANY_MEMBER then return L.STATUS_TRUST_ANY end
	if not Census.Reporter() then return L.STATUS_NO_REPORTER:format(C.RELAY_RANK) end
	local role = ns.MyTrust()
	local me = role == "leader" and L.TRUST_LEADER or role == "officer" and L.TRUST_OFFICER or role == "rank" and L.TRUST_RANK or L.TRUST_NONE
	return L.STATUS_TRUST:format(me, C.RELAY_RANK)
end)
