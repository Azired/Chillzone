-- Chillzone: вступление через адресный шёпот. Адаптация Olympus Recruit.lua (MIT),
-- коммит c1064682a74396be4904040b6ee709187019861a. J1/J2 — подсказка маршрута,
-- J3 — просьба офицеру гильдии. Они не дают прав в подписанной сети.
-- В отличие от Olympus, просьба уходит только главе или офицеру: рядового, которого
-- нашёл /who, новичку не предлагаем. Ранг чужой гильдии новичку не виден, поэтому
-- офицеров называет только подсказка J2, и только найденных /who в этой гильдии.
local ADDON, ns = ...

local U, L, Codec = ns.Util, ns.L, ns.Codec
local Recruit = {
	ASK_COOLDOWN = 20, ROUTE_WAIT = 60, ROUTE_KEEP = 1800, REQUEST_EACH = 600,
	REQUESTS_SHOWN = 5, RECENT_MAX = 128,
	-- J1 за один поиск, пауза между такими пачками, повтор тому же участнику,
	-- офицеров гильдии из всех ответов J2, имён офицеров в строке гильдии.
	ROUTE_ASKS = 3, ROUTE_GAP = 15, ROUTE_FRESH = 600, ROUTE_CONTACTS = 6, OFFICERS_SHOWN = 3,
	found = {}, asked = {}, replied = {}, replyNames = {}, requests = {},
}
ns.Recruit = Recruit
local routeAsked, dnc, answered, whispers, requestAt, lineTimes, verifyTried = {}, {}, {}, {}, {}, {}, {}
local lastAsk, lastRoute = -math.huge, -math.huge

local function Field(s) return Codec.Plain(s):gsub("[~;=/]", "") end
local function Whisper(name, text)
	return ns.Comm.Send("WHISPER", text, { target = name, prio = true })
end
local function Changed() ns.Fire("RECRUIT") end

function Recruit.NoContactMe() return ns.db and ns.db.recruitsOff == true end
function Recruit.SetNoContact(on)
	ns.db.recruitsOff = on and true or nil
	ns.Print(on and L.RECRUIT_NOCONTACT_ON or L.RECRUIT_NOCONTACT_OFF)
	Changed()
end

local function Found(name, guild)
	if not ns.Who.Fresh() then return nil end
	local key = U.Key(name)
	for _, p in ipairs(Recruit.found) do
		if U.Key(p.name) == key and U.GuildKey(p.guild) == U.GuildKey(guild) then return p end
	end
end

local function AskRoute(name, check)
	if ns.IsMember() then return false end
	local key, now = U.Key(name), ns.Now()
	if not check and routeAsked[key] and now - routeAsked[key] < 10 then return false end
	if not Whisper(name, "J1~1") then return false end
	routeAsked[key] = now
	ns.Log("вступление: J1 для %s", U.Display(name))
	return true
end

function Recruit.Route()
	local r = Recruit.route
	return r and ns.Now() - r.t <= Recruit.ROUTE_KEEP and r or nil
end

-- Глава и офицеры гильдии в игре: их назвала подсказка J2, а /who нашёл в этой гильдии.
-- Кто отключил обращения, сюда не попадает.
function Recruit.Officers(guild)
	local out, seen = {}, {}
	local route = Recruit.Route()
	local hint = route and route.byName[U.GuildKey(guild)]
	for _, name in ipairs(hint and hint.contacts or {}) do
		local p = Found(name, guild)
		local key = p and U.Key(p.name)
		if key and not seen[key] and not dnc[key] then seen[key], out[#out + 1] = true, p end
	end
	return out
end

function Recruit.Guilds()
	local out, by, route = {}, {}, Recruit.Route()
	if not ns.Who.Fresh() then return out end
	for _, p in ipairs(Recruit.found) do
		local key = U.GuildKey(p.guild)
		if not by[key] then
			local hint = route and route.byName[key]
			local g = { name = p.guild, members = {}, free = hint and hint.free }
			by[key], out[#out + 1] = g, g
		end
		by[key].members[#by[key].members + 1] = p
	end
	for _, g in ipairs(out) do g.officers = Recruit.Officers(g.name) end
	table.sort(out, function(a, b)
		if (#a.officers > 0) ~= (#b.officers > 0) then return #a.officers > 0 end
		if (a.free or -1) ~= (b.free or -1) then return (a.free or -1) > (b.free or -1) end
		if #a.officers ~= #b.officers then return #a.officers > #b.officers end
		if #a.members ~= #b.members then return #a.members > #b.members end
		return a.name < b.name
	end)
	return out
end

-- Следующий офицер гильдии, которому ещё не писали (без guild — любой гильдии). Рядовых
-- не предлагаем: без офицеров в подсказке писать некому.
function Recruit.NextContact(guild)
	if not guild then
		for _, g in ipairs(Recruit.Guilds()) do
			local p = Recruit.NextContact(g.name)
			if p then return p end
		end
		return nil
	end
	for _, p in ipairs(Recruit.Officers(guild)) do
		if not Recruit.asked[U.Key(p.name)] then return p end
	end
	return nil
end

-- Офицер, которого назвала подсказка J2, но не нашёл поиск по гильдии: /who отдаёт 50 строк,
-- а в большой гильдии в игре сотни. Его проверяет отдельный запрос по имени, по одному
-- на щелчок; одно имя проверяем не чаще раза за раунд поиска.
function Recruit.Unverified()
	local route = Recruit.Route()
	if not route or not ns.Who.Fresh() or ns.IsMember() then return nil end
	local now = ns.Now()
	for _, g in ipairs(Recruit.Guilds()) do
		local hint = route.byName[U.GuildKey(g.name)]
		for _, name in ipairs(hint and hint.contacts or {}) do
			local key, at = U.Key(name), verifyTried[U.Key(name)]
			if key and not Found(name, g.name) and not dnc[key] and not Recruit.asked[key]
				and not (at and now - at <= ns.Who.ROUND_TTL) then return name end
		end
	end
	return nil
end

-- Щелчок «Найти гильдии»: сначала проверка названного офицера, потом обычный поиск.
function Recruit.Search()
	local name = Recruit.Unverified()
	if not name then return ns.Who.Search() end
	if not ns.Who.Verify(name) then return false end
	verifyTried[U.Key(name)] = ns.Now()
	ns.Log("вступление: проверка офицера %s через /who", U.Display(name))
	return true
end

function Recruit.OnRoute(msg, sender, dist, ctx)
	if dist ~= "WHISPER" or ctx or ns.IsMember() then return false end
	local key, now = U.Key(sender), ns.Now()
	if not routeAsked[key] or now - routeAsked[key] > Recruit.ROUTE_WAIT then return false end
	local flag, list = msg:match("^J2~([yn])~~0~([^~]*)$")
	if not flag or #msg > 1000 then return false end
	dnc[key] = flag == "n" or nil
	local r = { t = now, byName = {} }
	local n = 0
	for entry in list:gmatch("[^;]+") do
		local guild, free, names = entry:match("^([^=]+)=(%d+)=(.*)$")
		free = tonumber(free)
		if guild and U.IsMemberGuild(guild) and free and free <= Codec.GUILD_CAP and n < 8 then
			local contacts = {}
			for name in names:gmatch("[^/]+") do
				if #contacts < 2 and #name <= 120 then contacts[#contacts + 1] = name end
			end
			r.byName[U.GuildKey(guild)], n = { free = free, contacts = contacts }, n + 1
		end
	end
	-- Ответы разных участников складываются: каждый точно знает офицеров только своей гильдии.
	local old = n > 0 and Recruit.Route()
	for gk, e in pairs(old and old.byName or {}) do
		local cur = r.byName[gk]
		if not cur then
			r.byName[gk] = e
		else
			for _, name in ipairs(e.contacts) do
				local dup = #cur.contacts >= Recruit.ROUTE_CONTACTS
				for _, have in ipairs(cur.contacts) do dup = dup or U.Key(have) == U.Key(name) end
				if not dup then cur.contacts[#cur.contacts + 1] = name end
			end
		end
	end
	if n > 0 or not Recruit.Route() then Recruit.route = r end
	ns.Log("вступление: J2 от %s: %s", U.Display(sender), msg)
	if dnc[key] and Recruit.pending and U.Key(Recruit.pending.name) == key then
		Recruit.Cancel()
		ns.Print(L.RECRUIT_DNC, U.Display(sender))
	end
	Changed()
	return true
end
ns.Comm.On("J2", Recruit.OnRoute)

-- Глава главной гильдии не получает поток рекрутов. Своя гильдия — из ростера,
-- чужая — из подписанной переписи; список офицеров дополнительно сверяется с сертификатами.
-- Заполненная гильдия тоже попадает в ответ (мест 0), иначе новичок не увидит её офицеров;
-- гильдии с местами идут первыми и первыми помещаются в 250 байт.
function Recruit.RouteAnswer()
	local list = {}
	for _, s in ipairs(ns.Data.Summary()) do
		local row = ns.Data.Row(s.guild)
		if s.fresh and not s.conflict and (s.mine or (row and row.signed)) and U.IsMemberGuild(s.guild) then
			list[#list + 1] = { s = s, free = math.max(0, Codec.GUILD_CAP - (s.total or Codec.GUILD_CAP)) }
		end
	end
	table.sort(list, function(a, b)
		if a.free ~= b.free then return a.free > b.free end
		return a.s.guild < b.s.guild
	end)
	local msg = "J2~" .. (Recruit.NoContactMe() and "n" or "y") .. "~~0~"
	local n = 0
	for _, e in ipairs(list) do
		local s, contacts = e.s, {}
		local function Add(name, online, role)
			if not online or not name or #contacts >= 2 then return end
			if role == "leader" and U.IsMainGuild(s.guild) then return end
			if ns.IsMe(name) and Recruit.NoContactMe() then return end
			if not s.mine then
				local cert = ns.Security.Member(s.guild, name)
				if not cert or ns.Security.Level(cert) < 2 or cert.role ~= role then return end
			end
			contacts[#contacts + 1] = Field(name)
		end
		Add(s.r.leader, s.r.leaderOnline, "leader")
		for _, o in ipairs(s.r.officers or {}) do Add(o.name, o.online, "officer") end
		local entry = (n > 0 and ";" or "") .. Field(s.guild) .. "=" .. e.free .. "=" .. table.concat(contacts, "/")
		if #msg + #entry <= 250 then msg, n = msg .. entry, n + 1 end
		if n >= 8 then break end
	end
	return msg
end

local answerTimes = {}
function Recruit.OnRouteAsk(msg, sender, dist, ctx)
	if msg ~= "J1~1" or dist ~= "WHISPER" or ctx or not ns.IsMember() or not ns.Roster.Fresh() then return false end
	local key, now = U.Key(sender), ns.Now()
	for k, at in pairs(answered) do if now - at >= 60 then answered[k] = nil end end
	if answered[key] and not Recruit.NoContactMe() then return false end
	for i = #answerTimes, 1, -1 do if now - answerTimes[i] >= 60 then table.remove(answerTimes, i) end end
	if #answerTimes >= 10 then return false end
	answered[key], answerTimes[#answerTimes + 1] = now, now
	local answer = Recruit.RouteAnswer()
	ns.Log("вступление: J1 от %s, ответ %s", U.Display(sender), answer)
	return Whisper(sender, answer)
end
ns.Comm.On("J1", Recruit.OnRouteAsk)

function Recruit.Cancel()
	Recruit.pending = nil
	if ns.RecruitPane then ns.RecruitPane.CloseDialog() end
end

function Recruit.Message(contact)
	local class = UnitClass("player") or ""
	return L.RECRUIT_MESSAGE:format(contact.guild, UnitLevel("player") or 0, class)
end

function Recruit.Prompt(contact)
	if ns.IsMember() or not contact or not Found(contact.name, contact.guild) or dnc[U.Key(contact.name)] then return false end
	Recruit.pending = contact
	AskRoute(contact.name, true)
	ns.RecruitPane.ShowDialog(contact, Recruit.Message(contact))
	return true
end

function Recruit.Ask(contact, message)
	if ns.IsMember() or not contact or not Found(contact.name, contact.guild) then return false end
	local key, now = U.Key(contact.name), ns.Now()
	if dnc[key] or Recruit.asked[key] then return false end
	if now - lastAsk < Recruit.ASK_COOLDOWN then ns.Print(L.RECRUIT_WAIT); return false end
	if type(message) ~= "string" then return false end
	message = U.Cut(U.Trim(Codec.Plain(message)), 250)
	if message == "" or ns.Comm.InLockdown() then return false end
	local _, class = UnitClass("player")
	-- Очередь метаданных проверяем до обычного шёпота: полный буфер не создаёт дублей текста.
	local ok = ns.Comm.Send("WHISPER", ("J3~%s~%d~%s"):format(Field(contact.guild), UnitLevel("player") or 0, Field(class)), {
		target = contact.name, prio = true,
		guard = function() return not ns.IsMember() and not dnc[key] and Found(contact.name, contact.guild) ~= nil end,
	})
	if not ok then return false end
	SendChatMessage(message, "WHISPER", nil, U.TellName(contact.name))
	lastAsk, Recruit.asked[key] = now, now
	Recruit.Cancel()
	ns.Print(L.RECRUIT_SENT, U.Display(contact.name))
	Changed()
	return true
end

local function Prune()
	local now, own = ns.Now(), ns.MyGuild()
	for i = #Recruit.requests, 1, -1 do
		local r = Recruit.requests[i]
		if r.guild ~= own or not ns.IsMember()
			or (ns.Roster.Fresh() and ns.Roster.RankOf(r.name) ~= nil) then table.remove(Recruit.requests, i) end
	end
	for key, at in pairs(requestAt) do if now - at >= Recruit.REQUEST_EACH then requestAt[key] = nil end end
end
local function Drop(req)
	for i, r in ipairs(Recruit.requests) do
		if r == req then table.remove(Recruit.requests, i); Changed(); return true end
	end
	return false
end

function Recruit.OnJoinRequest(msg, sender, dist, ctx)
	if dist ~= "WHISPER" or ctx or not ns.IsMember() or not ns.Roster.Fresh() or Recruit.NoContactMe() then return false end
	if type(sender) ~= "string" or #sender > 120 then return false end
	local guild, level, class = msg:match("^J3~([^~]+)~(%d+)~([A-Z]*)$")
	if not guild or U.GuildKey(guild) ~= U.GuildKey(ns.MyGuild()) or ns.Roster.RankOf(sender) ~= nil then return false end
	level = tonumber(level)
	if not level or level < 1 or level > 255 or (class ~= "" and not L.CLASS[class]) then return false end
	Prune()
	local key, now = U.Key(sender), ns.Now()
	if not key or requestAt[key] then return false end
	-- Кэш защиты от повторов ограничен: забываем старого отправителя, сами заявки не удаляем.
	local keys, oldestKey, oldestAt = 0, nil, math.huge
	for k, at in pairs(requestAt) do
		keys = keys + 1
		if at < oldestAt then oldestKey, oldestAt = k, at end
	end
	if keys >= Recruit.RECENT_MAX then requestAt[oldestKey] = nil end
	requestAt[key] = now
	for i = #Recruit.requests, 1, -1 do if U.Key(Recruit.requests[i].name) == key then table.remove(Recruit.requests, i) end end
	local w = whispers[key]
	local req = { name = U.Normal(sender), guild = ns.MyGuild(), level = level, class = class, t = now,
		text = w and now - w.t <= 120 and w.text or nil }
	Recruit.requests[#Recruit.requests + 1] = req
	for i = #lineTimes, 1, -1 do if now - lineTimes[i] >= 60 then table.remove(lineTimes, i) end end
	if #lineTimes < 6 then
		lineTimes[#lineTimes + 1] = now
		ns.Print(L.RECRUIT_RECEIVED, U.Display(sender), req.guild)
	end
	Changed()
	return true
end
ns.Comm.On("J3", Recruit.OnJoinRequest)

function Recruit.CanInvite()
	return ns.IsMember() and type(CanGuildInvite) == "function" and CanGuildInvite() and true or false
end
local function Current(req)
	Prune()
	if not ns.IsMember() or not ns.Roster.Fresh() then return false end
	for _, r in ipairs(Recruit.requests) do if r == req then return true end end
	return false
end
function Recruit.Accept(req)
	if not Recruit.CanInvite() or not Current(req) then return false end
	local invite = C_GuildInfo and C_GuildInfo.Invite or GuildInvite
	if type(invite) ~= "function" then return false end
	invite(U.TellName(req.name))
	ns.Print(L.RECRUIT_INVITED, U.Display(req.name), req.guild)
	return Drop(req)
end
function Recruit.Decline(req)
	if not Recruit.CanInvite() or not Current(req) or ns.Comm.InLockdown() then return false end
	SendChatMessage(L.RECRUIT_DECLINE_TEXT:format(req.guild), "WHISPER", nil, U.TellName(req.name))
	return Drop(req)
end
function Recruit.Officer()
	if not ns.IsMember() or not ns.Roster.Fresh() then return nil end
	for _, m in ipairs(ns.Roster.members) do
		if m.online and not ns.IsMe(m.name) and ns.Roster.IsOfficerRank(m.rank) then return U.Display(m.name) end
	end
end
function Recruit.Point(req)
	local officer = Recruit.Officer()
	if not officer or not Current(req) or ns.Comm.InLockdown() then return false end
	SendChatMessage(L.RECRUIT_POINT_TEXT:format(officer), "WHISPER", nil, U.TellName(req.name))
	return Drop(req)
end
function Recruit.Dismiss(req) return Current(req) and Drop(req) end
function Recruit.Requests() Prune(); return Recruit.requests end

function Recruit.OnWhisper(text, sender)
	if type(issecretvalue) == "function" and (issecretvalue(text) or issecretvalue(sender)) then return end
	if type(text) ~= "string" or type(sender) ~= "string" then return end
	local key, now = U.Key(sender), ns.Now()
	if ns.IsMember() then
		local count = 0
		for k, w in pairs(whispers) do
			if now - w.t > 120 then whispers[k] = nil else count = count + 1 end
		end
		if count < 30 or whispers[key] then whispers[key] = { text = U.Cut(Codec.Plain(text), 250), t = now } end
		for _, req in ipairs(Recruit.requests) do
			if U.Key(req.name) == key and now - req.t <= 120 then req.text = U.Cut(Codec.Plain(text), 250); Changed() end
		end
	elseif Recruit.asked[key] then
		Recruit.replied[key] = U.Cut(Codec.Plain(text), 250)
		Recruit.replyNames[key] = U.Display(sender)
		ns.Print(L.RECRUIT_REPLIED, U.Display(sender))
		Changed()
	end
end
ns.RegisterEvent("CHAT_MSG_WHISPER", Recruit.OnWhisper)
-- Аддон есть не у каждого найденного, а офицеров своей гильдии знает только её участник.
-- Поэтому J1 уходит нескольким: сначала по одному из гильдий, чьих офицеров ещё не знаем,
-- затем ещё участникам тех же гильдий. Гильдии с известными офицерами не спрашиваем.
local function AskRoutes()
	local now = ns.Now()
	if ns.IsMember() or now - lastRoute < Recruit.ROUTE_GAP then return end
	local need, tried, sent = {}, {}, 0
	for _, g in ipairs(Recruit.Guilds()) do
		if #g.officers == 0 then need[U.GuildKey(g.name)] = true end
	end
	for pass = 1, 2 do
		for _, p in ipairs(Recruit.found) do
			local gk, at = U.GuildKey(p.guild), routeAsked[U.Key(p.name)]
			if sent < Recruit.ROUTE_ASKS and need[gk] and (pass == 2 or not tried[gk])
				and not (at and now - at <= Recruit.ROUTE_FRESH) and AskRoute(p.name) then
				sent, tried[gk], lastRoute = sent + 1, true, now
			end
		end
	end
end

ns.On("WHO", function(list)
	Recruit.found = list
	-- Пустой список — новый раунд поиска: проверенные по имени офицеры из него выпали.
	if #list == 0 then verifyTried = {} end
	AskRoutes()
	Changed()
end)
ns.On("GUILD_CHANGED", function()
	Recruit.Cancel()
	Recruit.found, Recruit.asked, Recruit.replied, Recruit.replyNames, Recruit.requests, Recruit.route = {}, {}, {}, {}, {}, nil
	routeAsked, dnc, answered, whispers, requestAt, lineTimes, answerTimes, verifyTried = {}, {}, {}, {}, {}, {}, {}, {}
	Changed()
end)
ns.On("ROSTER", Changed)
ns.Command("nocontact", function(arg)
	if arg ~= "on" and arg ~= "off" and arg ~= "" then ns.Print(L.HELP_NOCONTACT); return end
	Recruit.SetNoContact(arg == "on" or (arg == "" and not Recruit.NoContactMe()))
end, L.HELP_NOCONTACT)
