-- Мост /г между двумя гильдиями, включившими его в описании. Штатная строка остаётся
-- у автора, выбранный связной соседней гильдии публикует копию с именем автора.
local ADDON, ns = ...

local U, L, Codec = ns.Util, ns.L, ns.Codec
local Comm, Security = ns.Comm, ns.Security
local Bridge = {}
ns.GuildBridge = Bridge

local HELLO_INTERVAL, LEASE, CHAT_TTL, SEEN_LIMIT = 8, 25, 15, 256
local ELECT_QUIET = 6
local PUBLICATION_LIMIT, PUBLICATION_GAP = 16, 1
local state, announced, generation = nil, nil, 0
local infoGuild, infoText, infoPolicy
local electedPolicy, electedAt, retiredUntil = nil, nil, 0
local observed, published, remembered = {}, {}, {}

local function Valid(s, cap)
	return type(s) == "string" and #s > 0 and #s <= cap and U.Trim(s) == s and not s:find("[|~%c]")
end

local function IsSecret(v)
	return type(issecretvalue) == "function" and issecretvalue(v)
end

local function SameGuild(a, b)
	return U.GuildKey(a) == U.GuildKey(b)
end

local function ParsePolicy(guild, info)
	local found
	for line in (info .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		if line:find("[CZBRIDGE1]", 1, true) then
			local peerGuild = line:match("^%[CZBRIDGE1%] (.+)$")
			if found or not Valid(peerGuild, 96) or peerGuild:find(";", 1, true)
				or SameGuild(guild, peerGuild) then return nil end
			found = { guild = guild, peerGuild = peerGuild }
		end
	end
	return found
end

-- Настройка хранится на сервере игры в описании гильдии, а не на диске связного.
-- Выключение и смену имени видит и связной, который был не в игре.
local function Policy()
	local guild = ns.MyGuild()
	if not guild or not ns.IsMember() or not ns.Roster.Fresh()
		or not C_GuildInfo or type(C_GuildInfo.GetInfoText) ~= "function" then return nil end
	local ok, info = pcall(C_GuildInfo.GetInfoText)
	if not ok or IsSecret(info) or type(info) ~= "string" or #info > 4096 then return nil end
	if guild ~= infoGuild or info ~= infoText then
		infoGuild, infoText, infoPolicy = guild, info, ParsePolicy(guild, info)
	end
	if infoPolicy and U.IsMemberGuild(infoPolicy.peerGuild) then return infoPolicy end
end

-- Адрес второй стороны берём из свежей подписанной переписи. Сам отчёт не включает мост:
-- согласие второй стороны подтверждается её ответом на наш одноразовый номер сессии.
local function Discover(c)
	local row = ns.Data.Row(c.peerGuild)
	if row and row.signed and ns.Data.IsFresh(row) and Valid(row.origin, 96) then return row.origin end
end

local function Retire()
	if state and state.remote then retiredUntil = ns.Now() + LEASE end
	state = nil
end

local function Active()
	local c = Policy()
	if not c or not ns.Census.IsReporter() or ns.Roster.RankOf(ns.me) == nil
		or not Security.MyCertificate() then
		Retire()
		electedPolicy, electedAt = nil, nil
		return nil
	end
	if electedPolicy ~= c then electedPolicy, electedAt = c, ns.Now() end
	local peer = Discover(c)
	if state and (state.config ~= c or not U.SameName(state.peer, peer)) then Retire() end
	if not peer or ns.Now() < math.max(electedAt + ELECT_QUIET, retiredUntil) then return nil end
	if not state then
		generation = generation + 1
		local nonce = table.concat({ ns.ServerTime(), U.Hash(tostring({}) .. ns.Now()), generation }, "-")
		state = { config = c, peer = peer, nonce = nonce, nextHello = 0, seq = 0, publications = {}, nextPost = 0 }
	end
	return state
end

local function Peer(s, sender)
	return U.SameName(s.peer, sender) and Security.Member(s.config.peerGuild, sender) ~= nil
end

local function Ready(s)
	return s and s.lease and ns.Now() < s.lease and Peer(s, s.peer) and true or false
end

function Bridge.Ready()
	return Ready(Active())
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
	local wire = table.concat({ "BH", c.guild, c.peerGuild, s.nonce,
		closing and "!" or s.remote or "", ns.ServerTime() }, "~")
	local opts = { target = s.peer, prio = Comm.PRIO_CONTROL,
		key = closing and ("bridge:close:" .. s.nonce) or "bridge:hello" }
	if not closing then
		opts.guard = function() return Active() == s end
	end
	Comm.Send("WHISPER", wire, opts)
end

ns.Comm.On("BH", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	local s = Active()
	if not s or not Peer(s, sender) then return end
	local from, to, origin, echo, sentAt = msg:match("^BH~([^~]+)~([^~]+)~([^~]+)~([^~]*)~(%d+)$")
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
	if changed then s.remote, s.lease, s.publications = origin, nil, {} end
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

local function Remember(guild, origin, id, author, text)
	local key = U.Key(author)
	if not ns.char or not ns.char.chatOn or not key or (ns.store and ns.store.ignore[key]) then return end
	if Once(remembered, HistoryKey(guild, origin, id)) then ns.Chat.Remember("A", guild, author, nil, text) end
end

local function PublishHistory(s, guild, origin, id, at, author, text)
	Remember(guild, origin, id, author, text)
	local wire = table.concat({ "BT", s.config.peerGuild, guild, origin, id, at, author, text }, "~")
	local remote = s.remote
	Comm.Send("GUILD", wire, {
		prio = true, logged = true,
		guard = function() return Active() == s and Ready(s) and s.remote == remote and Stamp(at, CHAT_TTL) ~= nil end,
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

local function NativeLine(prefix, text)
	local budget = 255 - #prefix
	local link = Codec.LinkAt(text, 1)
	-- Если первая ссылка целиком не влезает, оставляем её название без разметки.
	if link and link > budget then
		local label = text:sub(1, link):match("|h(%b[])|h")
		if label then text = label .. text:sub(link + 1) end
	end
	local parts = Codec.SplitChat(text, budget, 1)
	return parts[1] and prefix .. parts[1] or nil
end

-- Штатный /г ограничен по частоте. Очередь не переживает разрыв связи и не
-- публикует старые строки после снятия блокировки игры.
local function Pump(s)
	local queue = s.publications
	if not Ready(s) then s.publications = {}; return end
	while queue[1] and not Stamp(queue[1].at, CHAT_TTL) do table.remove(queue, 1) end
	if not queue[1] or ns.Now() < s.nextPost or Comm.InLockdown() then return end
	local line = table.remove(queue, 1)
	s.nextPost = ns.Now() + PUBLICATION_GAP
	if line.native then ns.SafeCall("bridge guild", ns.GuildChat.Send, "G", line.native) end
	PublishHistory(s, s.config.peerGuild, line.origin, line.id, line.at, line.author, line.text)
end

function Bridge.Tick()
	local s = Active()
	if announced and announced ~= s then Hello(announced, true) end
	announced = s
	if not s then return end
	if ns.Now() >= s.nextHello then Hello(s) end
	Pump(s)
end

ns.Comm.On("BT", function(msg, sender, dist)
	if dist ~= "GUILD" then return end
	local c = Policy()
	if not c or U.Key(sender) ~= ns.Census.Reporter() or ns.Roster.RankOf(sender) == nil then return end
	local peer, guild, origin, id, at, author, raw = msg:match("^BT~([^~]+)~([^~]+)~([^~]+)~(%d+)~(%d+)~([^~]+)~(.+)$")
	if not Stamp(at, CHAT_TTL) or not Valid(peer, 96) or not SameGuild(peer, c.peerGuild)
		or not Valid(guild, 96) or not (SameGuild(guild, c.guild) or SameGuild(guild, c.peerGuild))
		or not Nonce(origin) or not LineId(id) or not Valid(author, 64) then return end
	local text = Body(raw)
	if text then Remember(guild, origin, id, author, text) end
end)

ns.Comm.On("BM", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	local s = Active()
	if not Ready(s) or not Peer(s, sender) then return end
	local from, to, origin, echo, id, stamp, author, raw =
		msg:match("^BM~([^~]+)~([^~]+)~([^~]+)~([^~]+)~(%d+)~(%d+)~([^~]+)~(.+)$")
	local at = Stamp(stamp, CHAT_TTL)
	if not at or not Match(s, from, to) or origin ~= s.remote or echo ~= s.nonce
		or not LineId(id) or not Valid(author, 64) then return end
	local text = Body(raw)
	if not text or #s.publications >= PUBLICATION_LIMIT or not Once(published, HistoryKey(from, origin, id)) then return end
	-- Родное ограничение /г: одна строка в 255 байт с целыми ссылками и буквами.
	local prefix = L.GUILD_BRIDGE_PREFIX .. "[" .. s.config.peerGuild .. "] " .. author .. ": "
	s.publications[#s.publications + 1] = {
		origin = origin, id = id, at = at, author = author, text = text,
		native = NativeLine(prefix, text),
	}
	Pump(s)
end)

ns.RegisterEvent("CHAT_MSG_GUILD", function(raw, sender, ...)
	local s = Active()
	if not Ready(s) or IsSecret(raw) or IsSecret(sender) or type(raw) ~= "string" or type(sender) ~= "string" then return end
	local line, author, text = select(9, ...), U.Display(sender), Body(raw)
	if not text or not Valid(author, 64) then return end
	local c, remote, at = s.config, s.remote, ns.ServerTime()
	if not IsSecret(line) and type(line) == "number" and line > 0
		and not Once(observed, U.GuildKey(c.guild) .. "~" .. line) then return end
	s.seq = s.seq + 1
	local id = tostring(s.seq)
	local wire = table.concat({ "BM", c.guild, c.peerGuild, s.nonce, remote, id, at, author, text }, "~")
	local function Guard()
		return Active() == s and Ready(s) and s.remote == remote and Stamp(at, CHAT_TTL) ~= nil
	end
	Comm.Send("WHISPER", wire, { target = s.peer, prio = true, logged = true, guard = Guard, done = function(ok)
		if ok and Guard() then PublishHistory(s, c.guild, s.nonce, id, at, author, text) end
	end })
end)

ns.On("LOGIN", function() ns.Every(1, "bridge", Bridge.Tick, true) end)
ns.On("GUILD_CHANGED", Bridge.Tick)
ns.On("REPORTER", function(me)
	if me and Policy() then ns.Census.MaybeReport(true) end
	Bridge.Tick()
end)

ns.Command("bridge", function(arg)
	if U.Trim(arg) ~= "" then ns.Print(L.GUILD_BRIDGE_USAGE); return end
	local c = Policy()
	if not c then ns.Print(L.GUILD_BRIDGE_OFF); return end
	if not ns.Census.IsReporter() then ns.Print(L.GUILD_BRIDGE_OPERATOR, ns.Census.ReporterName() or "-"); return end
	ns.Print(Bridge.Ready() and L.GUILD_BRIDGE_READY or L.GUILD_BRIDGE_WAIT, c.peerGuild, Discover(c) or "-")
end, L.HELP_BRIDGE)
