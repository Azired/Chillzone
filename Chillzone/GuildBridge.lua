-- Обычный /г попадает в общий канал A только в окне аддона. Локальные строки
-- видны сразу; выбранные репортёры передают их между гильдиями без копий в /г.
-- Версия 2 отделяет этот обмен от прежнего двустороннего черновика моста.
local ADDON, ns = ...

local U, L, Codec = ns.Util, ns.L, ns.Codec
local Comm, Security = ns.Comm, ns.Security
local Bridge = {}
ns.GuildBridge = Bridge

local HELLO_INTERVAL, LEASE, CHAT_TTL, SEEN_LIMIT = 8, 25, 15, 256
local HISTORY_TTL = 30
local ELECT_QUIET = 6
local operation, generation = nil, 0
local sessions, announced, retiredUntil, offlineReports = {}, {}, {}, {}
local observed, remembered = {}, {}

local function Valid(s, cap)
	return type(s) == "string" and #s > 0 and #s <= cap and U.Trim(s) == s and not s:find("[|~%c]")
end

local function IsSecret(v)
	return type(issecretvalue) == "function" and issecretvalue(v)
end

local function SameGuild(a, b)
	return U.GuildKey(a) == U.GuildKey(b)
end

local function Guild()
	local guild = ns.MyGuild()
	if Valid(guild, 96) and U.IsMemberGuild(guild) and ns.Roster.Fresh() then return guild end
end

local function PeerGuild(guild, peerGuild)
	return Valid(peerGuild, 96) and not SameGuild(guild, peerGuild) and U.IsMemberGuild(peerGuild)
end

-- Адрес связного берём из свежей подписанной переписи. Ответ с нашим номером
-- сессии подтверждает, что с другой стороны действует мост.
local function Discover(guild)
	local row = ns.Data.Row(guild)
	if row and row.signed and type(row.st) == "number" and ns.Data.IsFresh(row) and Valid(row.origin, 96) then
		return row.origin, row.st
	end
end

local function Retire(key)
	local s = sessions[key]
	if s and s.remote then retiredUntil[key] = ns.Now() + LEASE end
	sessions[key] = nil
end

local function Operator()
	local guild = Guild()
	local elected = guild and ns.Roster.RankOf(ns.me) ~= nil and ns.Census.IsReporter() and Security.MyCertificate()
	if operation and (not elected or not SameGuild(operation.guild, guild)) then
		for key in pairs(sessions) do Retire(key) end
		operation = nil
	end
	if not elected then return nil end
	if not operation then
		generation = generation + 1
		local nonce = table.concat({ ns.ServerTime(), U.Hash(tostring({}) .. ns.Now()), generation }, "-")
		operation = { guild = guild, nonce = nonce, electedAt = ns.Now(), seq = 0 }
	end
	return operation
end

local function Active(peerGuild, op)
	if not Valid(peerGuild, 96) then return nil end
	local key = U.GuildKey(peerGuild)
	op = op or Operator()
	if not op or not PeerGuild(op.guild, peerGuild) then
		Retire(key)
		return nil
	end
	local peer, reportedAt = Discover(peerGuild)
	local offline = offlineReports[key]
	if peer and offline then
		if U.Key(peer) == offline.peerKey and reportedAt <= offline.reportedAt then peer = nil
		else offlineReports[key] = nil end
	end
	if peer and not Security.Member(peerGuild, peer) then peer = nil end
	local s = sessions[key]
	if s and not U.SameName(s.peer, peer) then
		Retire(key)
		s = nil
	end
	if not peer or ns.Now() < math.max(op.electedAt + ELECT_QUIET, retiredUntil[key] or 0) then return nil end
	if not s then
		s = { config = { guild = op.guild, peerGuild = peerGuild }, peer = peer, nonce = op.nonce, nextHello = 0 }
		sessions[key] = s
	end
	s.reportedAt = reportedAt
	return s
end

local function Ready(s)
	return s and s.lease and ns.Now() < s.lease and true or false
end

function Bridge.Ready(peerGuild)
	local op = Operator()
	if not op then return false end
	if peerGuild then return Ready(Active(peerGuild, op)) end
	for _, entry in ipairs(Security.UnionGuilds()) do
		if Ready(Active(entry.guild, op)) then return true end
	end
	return false
end

local function Stamp(at, ttl)
	at = tonumber(at)
	local now = ns.ServerTime()
	if at and at <= now + 3 and now - at <= ttl then return at end
end

local function Nonce(v)
	return #v <= 48 and v:match("^%d+%-%d+%-%d+$")
end

local function Match(s, from, to)
	return Valid(from, 96) and Valid(to, 96)
		and SameGuild(from, s.config.peerGuild) and SameGuild(to, s.config.guild)
end

local function Hello(s, closing)
	local c = s.config
	if not closing then
		s.nextHello = ns.Now() + HELLO_INTERVAL
		Security.Introduce(s.peer)
	end
	local wire = table.concat({ "BH", "2", c.guild, c.peerGuild, s.nonce,
		closing and "!" or s.remote or "", ns.ServerTime() }, "~")
	local key = U.GuildKey(c.peerGuild)
	-- Фоновые приветствия уступают срочным сообщениям и обмену сертификатами.
	local opts = { target = s.peer,
		key = closing and ("bridge:close:" .. key .. ":" .. s.nonce) or ("bridge:hello:" .. key) }
	if closing then
		opts.guard = function() return Security.Member(c.peerGuild, s.peer) ~= nil end
	else
		opts.guard = function() return Active(c.peerGuild) == s end
	end
	Comm.Send("WHISPER", wire, opts)
end

ns.Comm.On("BH", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	local from, to, origin, echo, sentAt = msg:match("^BH~2~([^~]+)~([^~]+)~([^~]+)~([^~]*)~(%d+)$")
	local s = Active(from)
	if not s or not U.SameName(s.peer, sender) then return end
	local at = Stamp(sentAt, LEASE)
	if not at or not Match(s, from, to) or not Nonce(origin) or (s.peerAt and at < s.peerAt) then return end
	if echo == "!" then
		if s.remote == origin then s.peerAt, s.remote, s.lease = at, nil, nil end
		return
	end
	if echo ~= "" and not Nonce(echo) then return end
	if s.peerAt and at <= s.peerAt then return end
	s.peerAt = at
	local changed = s.remote ~= origin
	if changed then s.remote, s.lease = origin, nil end
	if echo == s.nonce then s.lease = ns.Now() + LEASE - math.max(0, ns.ServerTime() - at) end
	if changed then Hello(s) end
end)

-- Ограниченная память по идентификаторам: повторы текста с разными lineID допустимы.
local function Once(cache, key)
	if cache[key] then return false end
	local slot = (cache.slot or 0) % SEEN_LIMIT + 1
	local old = cache[slot]
	if old then cache[old] = nil end
	cache.slot, cache[slot], cache[key] = slot, key, true
	return true
end

local function HistoryKey(guild, origin, id)
	return U.GuildKey(guild) .. "~" .. origin .. "~" .. id
end

local function Remember(guild, author, class, text, at)
	local key = U.Key(author)
	if not ns.char or not ns.char.chatOn or not key or (ns.store and ns.store.ignore[key]) then return end
	-- Chat.Show пишет ещё и в игровые вкладки. Импорт нужен только в истории A и окне.
	ns.Chat.Remember("A", guild, author, class, text, at)
end

local function PublishHistory(s, origin, id, at, author, class, text)
	local cert = Security.MyCertificate()
	if not cert then return end
	Security.Introduce("GUILD")
	local wire = table.concat({ "BT", "2", cert.fp, s.config.peerGuild, origin, id, at, author,
		Codec.CLASS_CODE[class or ""] or "", text }, "~")
	local remote = s.remote
	Comm.Send("GUILD", wire, {
		prio = true, logged = true,
		guard = function()
			return Active(s.config.peerGuild) == s and Ready(s) and s.remote == remote and Stamp(at, HISTORY_TTL) ~= nil
		end,
	})
end

local function IsCopy(text)
	return text:sub(1, #L.GUILD_BRIDGE_PREFIX) == L.GUILD_BRIDGE_PREFIX or ns.GuildChat.IsMirror(text)
end

local function Body(text)
	if not text or #text > 510 or IsCopy(text) then return nil end
	text = Codec.SanitizeChat(text)
	return text ~= "" and text or nil
end

local function LineId(id)
	return #id <= 16 and id:match("^[1-9]%d*$")
end

function Bridge.Tick()
	local op, live = Operator(), {}
	if op then
		for _, entry in ipairs(Security.UnionGuilds()) do
			local s = Active(entry.guild, op)
			if s then live[U.GuildKey(entry.guild)] = s end
		end
		for key in pairs(sessions) do
			if not live[key] then Retire(key) end
		end
	end
	for key, s in pairs(announced) do
		if live[key] ~= s then Hello(s, true) end
	end
	announced = live
	for _, s in pairs(live) do
		if ns.Now() >= s.nextHello then Hello(s) end
	end
	for key, untilAt in pairs(retiredUntil) do
		if ns.Now() >= untilAt then retiredUntil[key] = nil end
	end
	for key in pairs(offlineReports) do
		if not U.IsMemberGuild(key) then offlineReports[key] = nil end
	end
end

local function LocalReporter(sender)
	local guild = Guild()
	if guild and U.Key(sender) == ns.Census.Reporter() and ns.Roster.RankOf(sender) ~= nil then return guild end
end

ns.Comm.On("BT", function(msg, sender, dist)
	if dist ~= "GUILD" then return end
	local localGuild = LocalReporter(sender)
	if not localGuild then return end
	local fp, guild, origin, id, at, author, class, raw =
		msg:match("^BT~2~([%w_-]+)~([^~]+)~([^~]+)~(%d+)~(%d+)~([^~]+)~([A-Z]*)~(.+)$")
	if not Stamp(at, HISTORY_TTL) or not PeerGuild(localGuild, guild)
		or not Nonce(origin) or not LineId(id) or not Valid(author, 64)
		or (class ~= "" and not Codec.CLASS_FILE[class]) then return end
	local text = Body(raw)
	if not text then return end
	Security.Resolve(fp, sender, sender, function(cert)
		if SameGuild(LocalReporter(sender), localGuild) and SameGuild(cert.guild, localGuild)
			and PeerGuild(localGuild, guild) and Stamp(at, HISTORY_TTL)
			and Once(remembered, HistoryKey(guild, origin, id)) then
			Remember(guild, author, Codec.CLASS_FILE[class], text, tonumber(at))
		end
	end)
end)

ns.Comm.On("BM", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	local from, to, origin, echo, id, stamp, author, class, raw =
		msg:match("^BM~2~([^~]+)~([^~]+)~([^~]+)~([^~]+)~(%d+)~(%d+)~([^~]+)~([A-Z]*)~(.+)$")
	local s = Active(from)
	if not Ready(s) or not U.SameName(s.peer, sender) then return end
	local at = Stamp(stamp, CHAT_TTL)
	if not at or not Match(s, from, to) or origin ~= s.remote or echo ~= s.nonce
		or not LineId(id) or not Valid(author, 64) or (class ~= "" and not Codec.CLASS_FILE[class]) then return end
	local text = Body(raw)
	if not text or not Once(remembered, HistoryKey(from, origin, id)) then return end
	Remember(from, author, Codec.CLASS_FILE[class], text, at)
	-- Только принимающая гильдия получает BT. Исходная уже видела нативное событие.
	PublishHistory(s, origin, id, at, author, Codec.CLASS_FILE[class], text)
end)

ns.RegisterEvent("CHAT_MSG_GUILD", function(raw, sender, ...)
	if IsSecret(raw) or IsSecret(sender) or type(raw) ~= "string" or type(sender) ~= "string" then return end
	local guild = ns.MyGuild()
	if not ns.IsMember() or not Valid(guild, 96) then return end
	local line, guid = select(9, ...), select(10, ...)
	local author, text = U.Display(sender), Body(raw)
	if not text or not Valid(author, 64) then return end
	local at = ns.ServerTime()
	if not IsSecret(line) and type(line) == "number" and line > 0
		and not Once(observed, U.GuildKey(guild) .. "~" .. line) then return end
	local class = ns.GuildChat.ClassOf(sender, guid)
	Remember(guild, author, class, text, at)
	-- Ни сертификат, ни выборы, ни доступность соседей не задерживают локальную строку.
	local op = Operator()
	if not op then return end
	op.seq = op.seq + 1
	local id = tostring(op.seq)
	for _, entry in ipairs(Security.UnionGuilds()) do
		local s = Active(entry.guild, op)
		if Ready(s) then
			local c, remote = s.config, s.remote
			local wire = table.concat({ "BM", "2", c.guild, c.peerGuild, s.nonce, remote, id, at, author,
				Codec.CLASS_CODE[class or ""] or "", text }, "~")
			local function Guard()
				return Active(c.peerGuild) == s and Ready(s) and s.remote == remote and Stamp(at, CHAT_TTL) ~= nil
			end
			Comm.Send("WHISPER", wire, { target = s.peer, prio = true, logged = true, guard = Guard })
		end
	end
end)

ns.On("LOGIN", function() ns.Every(1, "bridge", Bridge.Tick, true) end)
ns.On("GUILD_CHANGED", Bridge.Tick)
ns.On("WHISPER_UNAVAILABLE", function(peerKey)
	for key, s in pairs(sessions) do
		if U.Key(s.peer) == peerKey then
			-- Повторная проба по старой переписи снова заблокировала бы служебные шёпоты.
			offlineReports[key] = { peerKey = peerKey, reportedAt = s.reportedAt }
			Retire(key)
		end
	end
end)
ns.On("REPORTER", function(me)
	if me and Guild() then ns.Census.MaybeReport(true) end
	Bridge.Tick()
end)

ns.Command("bridge", function(arg)
	if U.Trim(arg) ~= "" then ns.Print(L.GUILD_BRIDGE_USAGE); return end
	if not ns.IsMember() then ns.Print(L.GUILD_BRIDGE_OFF); return end
	ns.Print(L.GUILD_BRIDGE_LOCAL)
	local guild = Guild()
	if not guild then ns.Print(L.GUILD_BRIDGE_PENDING); return end
	if not ns.Census.IsReporter() then ns.Print(L.GUILD_BRIDGE_OPERATOR, ns.Census.ReporterName() or "-"); return end
	local found
	for _, entry in ipairs(Security.UnionGuilds()) do
		if PeerGuild(guild, entry.guild) then
			found = true
			ns.Print(Bridge.Ready(entry.guild) and L.GUILD_BRIDGE_READY or L.GUILD_BRIDGE_WAIT,
				entry.guild, Discover(entry.guild) or "-")
		end
	end
	if not found or not Security.MyCertificate() then ns.Print(L.GUILD_BRIDGE_PENDING) end
end, L.HELP_BRIDGE)
