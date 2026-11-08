-- Chillzone: ретрансляторы. На WoW: Forever аддон-сообщения в пользовательском канале не
-- доставляются, а GUILD и WHISPER доставляются. Поэтому данные между гильдиями ходят
-- шёпотом через реле: автор → реле (RL) → репортёр каждой гильдии (RM) → его гильдия (RG).
-- Схема — упрощённая версия Olympus Relay.lua.
-- Реле — участник главной гильдии с сертификатом от её корня. Пока Config.TRUST_ANY_MEMBER,
-- любой; иначе только глава, офицеры и связные (Config.RELAY_RANK). Всё пересылаемое
-- подписано автором (Security.lua), поэтому подменить чужое реле не может.
-- RG по GUILD гильдия принимает только от своего репортёра (и от прежнего, пока он передаёт
-- дела): иначе любой участник заставлял бы всю гильдию проверять чужие подписи.
-- Аренда репортёра у реле (RR) уступается заявителю со званием выше или преемнику, которого
-- назвал сам держатель (RU). Рядовой не перехватит аренду офицера, посторонний — ничью.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Relay = {}
ns.Relay = Relay

local known = {} -- [Key] = { key, name, verified, asked, down }: реле, о которых я знаю
-- (я реле) [guildKey] = { name, key, t, next = { key, untilAt } }: аренда репортёра гильдии;
-- next — преемник, которого назвал сам держатель (RU).
local reporters = {}
local regOf = {} -- (я реле) [Key репортёра] = guildKey
local claims = {} -- (я реле) [guildKey] = { name, key, t }: кому отказано при живой аренде
-- Решение главы доходит до действующего репортёра даже после исключения гильдии:
-- обычный RP от неё уже не пройдёт проверку членства.
ns.On("UNION_POLICY", function(guild, wire)
	if not U.IsMainGuild(ns.MyGuild()) then return end
	local held = reporters[U.GuildKey(guild)]
	if held then ns.Comm.Send("WHISPER", wire, { target = held.name, prio = true,
		key = "union-reporter:" .. U.GuildKey(guild) }) end
end)
local seen = {} -- [ключ дедупа] = время
local rate = {} -- [Key автора] = { n, t0 }
local hold = {} -- сообщения, пока ни одно реле не ответило
local recent = {} -- [Key реле] = { { mode, inner, t } }: что ему недавно ушло (на случай офлайна)
local lastPong = {} -- [Key] = когда отвечали RY
Relay.stats = { forwarded = 0, delivered = 0, dropped = 0, untrusted = 0 }

local REG_TTL = 60 -- репортёр продлевает аренду раз в 15 секунд; без продления она истекает
Relay.REG_TTL = REG_TTL
local PONG_GAP = 5 -- реле отвечает одному адресату не чаще; вопрос раньше остаётся без ответа

local function Now() return ns.Now() end

local function MyGuildKey()
	local g = ns.MyGuild()
	return g and U.GuildKey(g) or nil
end

-- Гильдия, от имени которой написано вложенное сообщение.
function Relay.InnerGuild(inner)
	local signed = inner:match("^S1~[^~]+~%d+~%d+~[^~]+~(.+)$")
	if signed then return Relay.InnerGuild(signed) end
	return inner:match("^M1~%u~([^~]+)~") or inner:match("^R1~([^~]+)~")
end

local function Logged(inner)
	return inner:find("~M1~", 1, true) ~= nil or Codec.InnerType(inner) == "M1"
end

---------------------------------------------------------------------------
-- Кто реле и кому я доверяю
---------------------------------------------------------------------------
function Relay.IAmRelay()
	if not ns.myKey then return false end
	local g = ns.MyGuild()
	return g ~= nil and U.IsMainGuild(g) and ns.Roster.Fresh() and ns.MyTrust() ~= nil
		and ns.Security.MyCertificate() ~= nil
end

-- Имена из ответов других реле — только подсказка, кого спросить. Реле делает лишь сертификат
-- от подтверждённого корня главной гильдии.
function Relay.TrustOf(name)
	local key = U.Key(name)
	if not key then return nil end
	if key == ns.myKey then return Relay.IAmRelay() and "self" or nil end
	local c = ns.Security.Member(C.MAIN_GUILD, name)
	if not c then return nil end
	if not C.TRUST_ANY_MEMBER and c.role == "member" then return nil end
	return ns.Security.Level(c) > 1 and "officer" or "member"
end

-- Глава или офицер главной гильдии — по свежему сертификату, у всех одинаково: и в главной
-- гильдии, и в остальных. Такие реле идут первыми (Top).
function Relay.IsMainOfficer(name)
	local c = ns.Security.Member(C.MAIN_GUILD, name)
	return c ~= nil and ns.Security.Level(c) > 1
end

local function Entry(key, name)
	local e = known[key]
	if not e then
		e = { key = key }
		known[key] = e
	end
	if name then e.name = U.TellName(name) end
	return e
end

-- Кандидаты в реле, кроме меня, с доверием и приоритетом — один раз на тик (ns.Now()): Top,
-- Pick, Rank, статус и окно зовут их много раз подряд, а разбор и проверка сертификатов
-- не бесплатны. Состояние реле (verified, down) живёт в записях known и не кэшируется.
-- pool = { at, list = { записи known }, trust = { [Key] = роль }, officer = { [Key] = true } }
local pool

function Relay.Invalidate()
	pool = nil
end

local function Pool()
	local now = Now()
	if pool and pool.at == now then return pool end
	local p = { at = now, list = {}, trust = {}, officer = {} }
	local function add(name, probe)
		local k = U.Key(name)
		if not k or k == ns.myKey or p.trust[k] ~= nil then return end
		local trust = Relay.TrustOf(name)
		if not trust and not probe then return end
		p.trust[k] = trust or false
		p.officer[k] = trust == "officer"
		p.list[#p.list + 1] = Entry(k, name)
	end
	local root = ns.Security.Roots()[U.GuildKey(C.MAIN_GUILD)]
	if root then add(root.name, true) end
	for _, c in ipairs(ns.Security.Certificates(C.MAIN_GUILD)) do add(c.name) end
	if ns.store then
		for _, l in pairs(ns.store.relays) do add(l.name, true) end
	end
	for _, p2 in pairs(ns.Census.Peers()) do
		if p2.r then add(p2.name) end
	end
	if ns.myKey then p.officer[ns.myKey] = Relay.IsMainOfficer(ns.me) end
	pool = p
	return p
end

-- Доверенные реле, кроме меня (и те, кого стоит спросить). Список — копия: его можно сортировать.
function Relay.Candidates()
	local out = {}
	for i, e in ipairs(Pool().list) do out[i] = e end
	return out
end

local function Usable(e, now)
	return not (e.down and now < e.down)
end

local function Verified(e, now)
	return e.verified ~= nil and now - e.verified <= C.RELAY_VERIFIED and Usable(e, now)
end

-- Порядок реле: сначала глава и офицеры главной гильдии, потом остальные, внутри — по ключу.
local function Rank(list)
	local officer = Pool().officer
	table.sort(list, function(a, b)
		local oa, ob = officer[a.key] == true, officer[b.key] == true
		if oa ~= ob then return oa end
		return a.key < b.key
	end)
	return list
end

-- Три доступных реле сверху списка: у них регистрируются репортёры, через них идут
-- сообщения. Я сам стою в общем списке, если я реле, но в ответ не попадаю: так клиенты
-- главной гильдии и репортёры видят одну и ту же тройку. Опрос ограничен ею, а не всеми.
local function Top()
	local now, list = Now(), {}
	for _, e in ipairs(Pool().list) do
		if Usable(e, now) then list[#list + 1] = e end
	end
	if Relay.IAmRelay() then list[#list + 1] = { key = ns.myKey, name = ns.me, self = true } end
	Rank(list)
	local out = {}
	for i = 1, math.min(3, #list) do
		if not list[i].self then out[#out + 1] = list[i] end
	end
	return out
end

-- Я реле и у меня зарегистрирован репортёр чужой гильдии: моё сообщение я разошлю сам.
function Relay.Serving()
	local now, mine = Now(), MyGuildKey()
	for gk, r in pairs(reporters) do
		if gk ~= mine and now - r.t <= REG_TTL then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- Пинги и офлайн
---------------------------------------------------------------------------
local Out -- вперёд

local function MarkDown(e, why)
	local now = Now()
	e.down, e.asked, e.verified = now + C.RELAY_DOWN, nil, nil
	ns.Log("реле %s недоступно: %s", e.name or e.key, why)
	-- Что ему недавно ушло, уходит через другое реле.
	local list = recent[e.key]
	recent[e.key] = nil
	for _, m in ipairs(list or {}) do
		if now - m.t <= 15 then Out(m.mode, m.inner) end
	end
	ns.Fire("RELAYS")
end

local function Ask(e, payload)
	local now = Now()
	if e.asked and now - e.asked < C.RELAY_TIMEOUT then return end
	-- Реле промолчало бы, и живое реле попало бы в офлайн на RELAY_DOWN. Аренда от пропуска
	-- не страдает: следующая попытка через 15 секунд, а живёт аренда REG_TTL.
	if e.verified and now - e.verified < PONG_GAP then return end
	e.asked = now
	ns.Security.Introduce(e.name) -- в RP и RR только отпечаток моего сертификата
	ns.Comm.Send("WHISPER", payload, { target = e.name, prio = true, key = "ask:" .. e.key })
	local asked = now
	ns.After(C.RELAY_TIMEOUT + 1, "relay timeout", function()
		if e.asked == asked then MarkDown(e, "нет ответа") end
	end)
end

function Relay.PingAll()
	local now = Now()
	local c = ns.Security.MyCertificate()
	if not c then return end
	for _, e in ipairs(Top()) do
		if Usable(e, now) then Ask(e, "RP~" .. c.fp) end
	end
end

-- (я реле) Аренда гильдии gk переходит к name или продлевается. true — это новый репортёр:
-- ему нужна догоняющая рассылка. Продление снимает и названного преемника: держатель
-- снова репортёр.
local function Lease(gk, name, key, now)
	local old = reporters[gk]
	local isNew = not old or old.key ~= key or now - old.t > REG_TTL
	if old and old.key ~= key and regOf[old.key] == gk then regOf[old.key] = nil end
	local other = regOf[key]
	if other and other ~= gk and reporters[other] and reporters[other].key == key then reporters[other] = nil end
	reporters[gk], regOf[key], claims[gk] = { name = name, key = key, t = now }, gk, nil
	return isNew
end

-- Регистрация репортёра у каждого реле (RR). Реле отвечает RY — это и пинг.
function Relay.Register()
	local g = ns.MyGuild()
	local credential = ns.Security.MyCertificate()
	if not g or not credential or not ns.Census.IsReporter() then return end
	local now = Now()
	Relay.lastRegister = now
	if Relay.IAmRelay() then
		-- Реле — репортёр своей гильдии: регистрируется у себя. Впервые — отдаёт гильдии всё,
		-- что уже знает (чужие отчёты могли прийти до того, как я стал репортёром).
		if Lease(U.GuildKey(g), ns.me, ns.myKey, now) then
			for _, c in ipairs(ns.Data.Cached()) do
				ns.Security.IntroduceWire("GUILD", c.raw)
				ns.Comm.Send("GUILD", Codec.EncodeRM("RG", "L", c.origin, c.raw), { key = "rg:" .. c.key })
			end
		end
	end
	for _, e in ipairs(Top()) do
		if Usable(e, now) then Ask(e, "RR~" .. Codec.Clean(g) .. "~" .. credential.fp) end
	end
end

-- Перед отчётом: зарегистрироваться, если давно не регистрировался (новый репортёр).
function Relay.EnsureRegistered()
	if not Relay.lastRegister or Now() - Relay.lastRegister >= C.REG_EVERY - 10 then Relay.Register() end
end

-- Я реле: новому репортёру — всё, что я знаю о других гильдиях, чтобы перепись у его
-- гильдии сошлась сразу, а не через полчаса отчётов.
local function CatchUp(r, gk)
	for _, c in ipairs(ns.Data.Cached()) do
		if c.key ~= gk then
			ns.Security.IntroduceWire(r.name, c.raw)
			ns.Comm.Send("WHISPER", Codec.EncodeRM("RM", "L", c.origin, c.raw), { target = r.name, key = "rm:" .. gk .. ":" .. c.key })
		end
	end
	local mine = MyGuildKey()
	local own = ns.Census.lastRaw
	if own and mine and mine ~= gk and ns.Census.IsReporter() then
		ns.Security.IntroduceWire(r.name, own)
		ns.Comm.Send("WHISPER", Codec.EncodeRM("RM", "L", U.Display(ns.me), own), { target = r.name, key = "rm:" .. gk .. ":" .. mine })
	end
end

---------------------------------------------------------------------------
-- Передача аренды. Гильдия сменила репортёра, а реле ещё шлют RM прежнему: он продолжает
-- пересылать их гильдии и называет реле преемника (RU). Реле продлевает ему аренду до
-- регистрации преемника и уступает её именно преемнику, даже если у того звание ниже.
-- Назвать преемника может только сам держатель аренды; отказ заявителю реле помнит,
-- чтобы отдать ему аренду сразу, как только держатель его назовёт.
---------------------------------------------------------------------------
local function Pass(gk, from, successor, now)
	local held = reporters[gk]
	local to = U.Key(successor)
	if not held or held.key ~= from or now - held.t > REG_TTL or not to or to == from then return end
	held.t, held.next = now, { key = to, untilAt = now + REG_TTL }
	local claim = claims[gk]
	if claim and claim.key == to and now - claim.t <= REG_TTL and Lease(gk, claim.name, claim.key, now) then
		ns.Log("аренда гильдии %s передана: %s", gk, U.Display(claim.name))
		CatchUp(reporters[gk], gk)
	end
end

-- Уступает ли живая аренда held заявителю с сертификатом c гильдии guild.
local function Yields(held, guild, c, now)
	if held.next and held.next.key == c.key and now <= held.next.untilAt then return true end
	local holder = ns.Security.Member(guild, held.name)
	return (holder and ns.Security.Level(holder) or 0) < ns.Security.Level(c)
end

-- Я больше не репортёр, но реле ещё шлют мне: назвать им преемника (раз в 15 секунд, пока
-- передаю дела; это же продлевает мою аренду). Реле — и у себя.
function Relay.HandOver()
	local g, to = ns.MyGuild(), ns.Census.Successor()
	if not g or not to then return end
	local now = Now()
	if Relay.IAmRelay() then Pass(U.GuildKey(g), ns.myKey, to, now) end
	local wire = "RU~" .. Codec.Clean(g) .. "~" .. U.Display(to)
	for _, e in ipairs(Top()) do
		if Usable(e, now) then ns.Comm.Send("WHISPER", wire, { target = e.name, prio = true, key = "ru:" .. e.key }) end
	end
end

---------------------------------------------------------------------------
-- Отправка от автора
---------------------------------------------------------------------------
local function Remember(key, mode, inner)
	local list = recent[key] or {}
	local now = Now()
	for i = #list, 1, -1 do
		if now - list[i].t > 15 then table.remove(list, i) end
	end
	list[#list + 1] = { mode = mode, inner = inner, t = now }
	while #list > 5 do table.remove(list, 1) end
	recent[key] = list
end

local function Hold(mode, inner)
	if mode == "L" then
		local t = Codec.InnerType(inner)
		for i = #hold, 1, -1 do
			if hold[i].mode == "L" and Codec.InnerType(hold[i].inner) == t then table.remove(hold, i) end
		end
	end
	hold[#hold + 1] = { mode = mode, inner = inner, t = Now() }
	while #hold > C.RELAY_HOLD do table.remove(hold, 1) end
end

local function FlushHold()
	if #hold == 0 then return end
	local list = hold
	hold = {}
	local now = Now()
	for _, m in ipairs(list) do
		if now - m.t <= C.RELAY_VERIFIED then Out(m.mode, m.inner) end
	end
end

-- Реле, через которое пойдёт сообщение моей гильдии сейчас: запись known или nil. Только
-- из тройки Top (у других реле репортёры не зарегистрированы) и только отвечающее; глава и
-- офицеры главной — первыми, остальные — если ни один из них не отвечает. Внутри группы
-- реле меняется раз в RELAY_WINDOW (по хешу гильдии).
function Relay.Pick()
	local now = Now()
	local officers, others = {}, {}
	local p = Pool()
	for _, e in ipairs(Top()) do
		if Verified(e, now) and p.trust[e.key] then
			local list = p.officer[e.key] and officers or others
			list[#list + 1] = e.key
		end
	end
	local keys = #officers > 0 and officers or others
	local pick = Codec.PickRelay(MyGuildKey() or "", keys, now, C.RELAY_WINDOW)
	return pick and known[pick] or nil
end

-- mode: "L" (отчёт: новый заменяет старый) или "P" (каждое: чат). inner: подписанный S1.
-- Реле главной гильдии рассылает само, только если у него есть чужие репортёры; иначе, как
-- и все, шлёт RL реле из тройки: рядовой вне тройки иначе разослал бы в пустоту.
function Out(mode, inner)
	if not ns.IsMember() or Codec.InnerType(inner) ~= "S1" then return false end
	if Relay.IAmRelay() and Relay.Serving() then
		-- Свой пакет я только что подписал сам: проверять подпись незачем.
		local clear, certificate = ns.Security.Own(inner)
		if clear then
			Relay.Forward(ns.me, mode, inner, clear, certificate)
		else
			Relay.HandleRL(ns.me, mode, inner)
		end
		return true
	end
	local e = Relay.Pick()
	if not e then
		Hold(mode, inner)
		Relay.PingAll()
		return false
	end
	local key = mode == "L" and ("rl:" .. Codec.InnerType(inner)) or nil
	ns.Security.Introduce(e.name)
	ns.Comm.Send("WHISPER", Codec.EncodeRL(mode, inner), { target = e.name, key = key, prio = mode == "P", logged = Logged(inner) })
	Remember(e.key, mode, inner)
	return true
end
Relay.Out = Out

---------------------------------------------------------------------------
-- Работа реле
---------------------------------------------------------------------------
local function Seen(dk, now)
	if seen[dk] and now - seen[dk] <= C.RELAY_DEDUPE then return true end
	seen[dk] = now
	return false
end

local function RateOk(okey, now)
	local r = rate[okey]
	if not r or now - r.t0 > 60 then
		rate[okey] = { n = 1, t0 = now }
		return true
	end
	r.n = r.n + 1
	return r.n <= C.RELAY_PER_MIN
end

-- Я реле: проверенное сообщение автора (clear — вложенное, certificate — сертификат автора)
-- уходит репортёрам остальных гильдий.
function Relay.Forward(origin, mode, inner, clear, certificate)
	if certificate.key ~= U.Key(origin) then return end
	if (mode == "L") ~= (clear:sub(1, 2) == "R1") then return end
	local now = Now()
	local okey = U.Key(origin)
	local ig = Relay.InnerGuild(inner)
	if not okey or not ig or not U.IsMemberGuild(ig) then return end
	if not RateOk(okey, now) then
		Relay.stats.dropped = Relay.stats.dropped + 1
		return
	end
	if Seen(Codec.DedupeKey(okey, inner), now) then return end
	local igk = U.GuildKey(ig)
	local mine = MyGuildKey()
	if igk ~= mine then ns.Comm.Inject(clear, certificate.name,
		{ via = "RL", authenticated = true, certificate = certificate, wire = inner }) end
	for gk, r in pairs(reporters) do
		if now - r.t > REG_TTL then
			reporters[gk] = nil
			if regOf[r.key] == gk then regOf[r.key] = nil end
		elseif gk ~= igk then
			Relay.stats.forwarded = Relay.stats.forwarded + 1
			local key = mode == "L" and ("rm:" .. gk .. ":" .. okey .. ":" .. Codec.InnerType(inner)) or nil
			if r.key == ns.myKey then
				if gk == mine then
					ns.Security.Introduce("GUILD", certificate.raw)
					ns.Comm.Send("GUILD", Codec.EncodeRM("RG", mode, U.Display(origin), inner), { key = key, prio = mode == "P", logged = Logged(inner) })
				end
			else
				ns.Security.Introduce(r.name, certificate.raw)
				ns.Comm.Send("WHISPER", Codec.EncodeRM("RM", mode, U.Display(origin), inner), { target = r.name, key = key, prio = mode == "P", logged = Logged(inner) })
			end
		end
	end
end

-- Я реле: сообщение автора (RL) — проверить подпись и разослать.
function Relay.HandleRL(origin, mode, inner)
	if Codec.InnerType(inner) ~= "S1" then Relay.stats.untrusted = Relay.stats.untrusted + 1; return end
	return ns.Security.Open(inner, origin, function(clear, certificate)
		Relay.Forward(origin, mode, inner, clear, certificate)
	end)
end

-- Доставка вложенного сообщения у получателя (RM — репортёр, RG — его гильдия).
local function Deliver(mode, origin, inner, ctx, toGuild)
	if Codec.InnerType(inner) ~= "S1" then Relay.stats.untrusted = Relay.stats.untrusted + 1; return end
	return ns.Security.Open(inner, ctx.relay or origin, function(clear, certificate)
	if certificate.key ~= U.Key(origin) then return end
	if (mode == "L") ~= (clear:sub(1, 2) == "R1") then return end
	local now = Now()
	local okey = U.Key(origin)
	if not okey or Seen(Codec.DedupeKey(okey, inner), now) then return end
	local ig = Relay.InnerGuild(inner)
	if not ig or U.GuildKey(ig) == MyGuildKey() then return end -- своя гильдия приходит напрямую
	Relay.stats.delivered = Relay.stats.delivered + 1
	ctx.authenticated, ctx.certificate, ctx.wire = true, certificate, inner
	ns.Comm.Inject(clear, certificate.name, ctx)
	if toGuild and ns.MyGuild() then
		local key = mode == "L" and ("rg:" .. okey .. ":" .. Codec.InnerType(inner)) or nil
		ns.Security.Introduce("GUILD", certificate.raw)
		ns.Comm.Send("GUILD", Codec.EncodeRM("RG", mode, origin, inner), { key = key, prio = mode == "P", logged = Logged(inner) })
	end
	end, ctx.via == "RG")
end

local function GossipList(exceptKey)
	local now = Now()
	local out = {}
	for _, e in ipairs(Rank(Relay.Candidates())) do
		if #out >= C.RELAY_GOSSIP then break end
		if e.key ~= exceptKey and Usable(e, now) then out[#out + 1] = U.Display(e.name) end
	end
	return out
end

local function Pong(sender)
	local k = U.Key(sender)
	local now = Now()
	if lastPong[k] and now - lastPong[k] < PONG_GAP then return end
	lastPong[k] = now
	ns.Security.SendPolicies(sender)
	ns.Security.Introduce(sender)
	ns.Comm.Send("WHISPER", Codec.EncodeRelayList(GossipList(k)), { target = sender, prio = true, key = "ry:" .. k })
end

ns.Comm.On("RP", function(msg, sender, dist)
	if dist ~= "WHISPER" or not Relay.IAmRelay() then return end
	local fp = msg:match("^RP~([%w_-]+)$")
	if fp then ns.Security.Resolve(fp, sender, sender, function() Pong(sender) end) end
end)

ns.Comm.On("RR", function(msg, sender, dist)
	if dist ~= "WHISPER" or not Relay.IAmRelay() then return end
	local guild, fp = msg:match("^RR~([^~]+)~([%w_-]+)$")
	if not guild or not U.IsMemberGuild(guild) or Codec.LongGuild(guild) then return end
	ns.Security.Resolve(fp, sender, sender, function(certificate)
		if U.GuildKey(certificate.guild) ~= U.GuildKey(guild) then return end
		local gk, k = U.GuildKey(guild), U.Key(sender)
		local now = Now()
		local held = reporters[gk]
		if held and held.key ~= k and now - held.t <= REG_TTL and not Yields(held, guild, certificate, now) then
			-- Живую аренду держит другой: отказ, но если держатель назовёт этого заявителя
			-- преемником (RU), аренда перейдёт к нему сразу.
			claims[gk] = { name = sender, key = k, t = now }
			Pong(sender)
			return
		end
		local isNew = Lease(gk, sender, k, now)
		Pong(sender)
		if isNew then CatchUp(reporters[gk], gk) end
	end)
end)

-- RU~гильдия~преемник: держатель аренды больше не репортёр и называет преемника.
ns.Comm.On("RU", function(msg, sender, dist)
	if dist ~= "WHISPER" or not Relay.IAmRelay() then return end
	local guild, successor = msg:match("^RU~([^~]+)~([^~]+)$")
	if not guild or not U.IsMemberGuild(guild) or Codec.LongGuild(guild) then return end
	Pass(U.GuildKey(guild), U.Key(sender), successor, Now())
end)

ns.Comm.On("RY", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	if not Relay.TrustOf(sender) then
		Relay.stats.untrusted = Relay.stats.untrusted + 1
		return
	end
	local e = Entry(U.Key(sender), sender)
	e.verified, e.asked, e.down = Now(), nil, nil
	-- Выучить реле из ответа.
	local store = ns.store
	local changed = false
	for _, name in ipairs(Codec.DecodeRelayList(msg, C.RELAY_GOSSIP) or {}) do
		local k = U.Key(name)
		if k and k ~= ns.myKey and not Relay.TrustOf(name) then
			store.relays[k] = { name = name, t = ns.ServerTime(), by = e.key }
			changed = true
		elseif k and store.relays[k] then
			store.relays[k].t = ns.ServerTime()
		end
	end
	if changed then
		Relay.PruneLearned()
		Relay.Invalidate()
	end
	FlushHold()
	ns.Fire("RELAYS")
end)

ns.On("AUTH_PEER", function(c, sender)
	if not U.IsMainGuild(c.guild) or not Relay.TrustOf(sender) or ns.IsMe(sender) then return end
	local e = Entry(U.Key(sender), sender)
	e.verified, e.asked, e.down = Now(), nil, nil
	FlushHold()
end)

ns.Comm.On("RL", function(msg, sender, dist)
	if dist ~= "WHISPER" or not Relay.IAmRelay() then return end
	local kind, mode, _, inner = Codec.DecodeRelay(msg)
	if kind ~= "RL" then return end
	Relay.HandleRL(sender, mode, inner)
end)

-- RM принимает репортёр, а после смены репортёра — и прежний, пока передаёт дела: реле ещё
-- шлют ему по старой аренде.
ns.Comm.On("RM", function(msg, sender, dist)
	if dist ~= "WHISPER" or not ns.Census.Forwarding() then return end
	if not Relay.TrustOf(sender) then
		Relay.stats.untrusted = Relay.stats.untrusted + 1
		return
	end
	local kind, mode, origin, inner = Codec.DecodeRelay(msg)
	if kind ~= "RM" then return end
	local e = Entry(U.Key(sender), sender)
	e.verified, e.down = Now(), nil
	Deliver(mode, origin, inner, { via = "RM", relay = sender }, true)
end)

-- RG раздаёт репортёр (или реле-репортёр) своей гильдии. Пакет внутри подписан автором, но
-- проверка подписи стоит каждому в гильдии, поэтому RG принимается только от репортёра
-- (Census.MayForward), а не от любого участника.
ns.Comm.On("RG", function(msg, sender, dist)
	if dist ~= "GUILD" then return end
	if not ns.Roster.Fresh() or not ns.Census.MayForward(U.Key(sender)) then
		Relay.stats.untrusted = Relay.stats.untrusted + 1
		ns.Log("RG от %s отклонён: он не репортёр гильдии", U.Display(sender))
		return
	end
	local kind, mode, origin, inner = Codec.DecodeRelay(msg)
	if kind ~= "RG" then return end
	Deliver(mode, origin, inner, { via = "RG", relay = sender }, false)
end)

---------------------------------------------------------------------------
-- Выученные реле: не дольше 14 дней, не больше 12.
---------------------------------------------------------------------------
function Relay.PruneLearned()
	local store = ns.store
	if not store then return end
	local now = ns.ServerTime()
	local list = {}
	for k, l in pairs(store.relays) do
		if type(l) ~= "table" or not l.name or now - (l.t or 0) > C.RELAY_LEARNED_TTL then
			store.relays[k] = nil
		else
			list[#list + 1] = { k = k, t = l.t }
		end
	end
	table.sort(list, function(a, b) return a.t > b.t end)
	for i = C.RELAY_LEARNED_MAX + 1, #list do store.relays[list[i].k] = nil end
end

---------------------------------------------------------------------------
-- Транспорт подтвердил недоступность адресата: меняем реле или снимаем аренду репортёра
-- сразу, не дожидаясь REG_TTL. Очередь этому адресату уже отменена в Comm.
---------------------------------------------------------------------------
ns.On("WHISPER_UNAVAILABLE", function(k)
	local e = known[k]
	if e then MarkDown(e, "не в игре") end
	ns.Security.ContactAway(k)
	local gk = regOf[k]
	local reporter = gk and reporters[gk]
	if reporter and reporter.key == k then
		ns.Log("репортёр %s не в игре: аренда гильдии %s снята", U.Display(reporters[gk].name), gk)
		reporters[gk], regOf[k] = nil, nil
	end
end)

---------------------------------------------------------------------------
-- Расписание, команды, статус
---------------------------------------------------------------------------
ns.On("LOGIN", function()
	Relay.PruneLearned()
	ns.After(20, "relay first ping", function()
		if ns.IsMember() and not Relay.IAmRelay() then Relay.PingAll() end
	end)
	ns.Every(C.REG_EVERY, "relay register", function()
		if not ns.IsMember() then return end
		if ns.Census.IsReporter() then
			Relay.EnsureRegistered()
		end
	end)
	ns.Every(15, "relay discovery", function()
		if not ns.IsMember() then return end
		if ns.Census.IsReporter() then
			Relay.Register()
		elseif ns.Census.Handing() then
			Relay.HandOver()
		elseif #hold > 0 then
			Relay.PingAll()
		end
	end)
	ns.Every(60, "relay gc", function()
		local now = Now()
		for k, t in pairs(seen) do
			if now - t > C.RELAY_DEDUPE then seen[k] = nil end
		end
		for k, t in pairs(lastPong) do
			if now - t > 60 then lastPong[k] = nil end
		end
		for gk, claim in pairs(claims) do
			if now - claim.t > REG_TTL then claims[gk] = nil end
		end
	end)
end)

-- Я стал репортёром — регистрируюсь сразу, не дожидаясь расписания; перестал — называю
-- реле преемника.
ns.On("REPORTER", function(me)
	if not ns.IsMember() then return end
	if me then Relay.Register() else Relay.HandOver() end
end)

ns.On("AUTH_ROOT", Relay.Invalidate)
ns.On("GUILD_CHANGED", Relay.Invalidate)

-- Для тестов и окна.
function Relay.Known() return known end
function Relay.Reporters() return reporters end
function Relay.HoldSize() return #hold end

-- Состояние реле для показа: подпись и код ("down", "ok", "asked", "unknown").
local function StateOf(e, now)
	if e.down and now < e.down then return L.RELAY_DOWN, "down" end
	if Verified(e, now) then return L.RELAY_OK, "ok" end
	if e.asked then return L.RELAY_ASKED, "asked" end
	return L.RELAY_UNKNOWN, "unknown"
end
Relay.StateOf = StateOf

ns.Command("relay", function(arg)
	local cmd, name = U.Trim(arg):match("^(%S*)%s*(.-)$")
	cmd = U.Fold(cmd or "")
	name = U.Trim(name)
	local store = ns.store
	if cmd == "add" and name ~= "" then
		local ok, why = ns.Security.Link(name)
		if not ok and why then ns.Print(why) end
		return
	elseif (cmd == "del" or cmd == "remove") and name ~= "" then
		local k = U.Key(name)
		store.manual[k], store.relays[k], known[k] = nil, nil, nil
		Relay.Invalidate()
		ns.Print(L.RELAY_REMOVED, name)
		return
	elseif cmd == "ping" then
		for _, e in pairs(known) do e.down, e.asked = nil, nil end
		Relay.PingAll()
		ns.Print(L.RELAY_PINGING)
		return
	end
	local now = Now()
	ns.Print(Relay.IAmRelay() and L.RELAY_I_AM or L.RELAY_I_AM_NOT)
	local list = Relay.Candidates()
	if #list == 0 then ns.Print(L.RELAY_NONE) end
	for _, e in ipairs(list) do
		ns.Print("  %s — %s (%s)", U.Display(e.name), (StateOf(e, now)), Relay.TrustOf(e.name) or "?")
	end
	if Relay.IAmRelay() then
		local n = 0
		for gk, r in pairs(reporters) do
			if now - r.t <= REG_TTL then
				n = n + 1
				ns.Print("  " .. L.RELAY_REPORTER, gk, U.Display(r.name))
			end
		end
		if n == 0 then ns.Print("  " .. L.RELAY_NO_REPORTERS) end
	end
end, L.HELP_RELAY)

ns.Status(function()
	local now = Now()
	local ok, total = 0, 0
	for _, e in ipairs(Relay.Candidates()) do
		total = total + 1
		if Verified(e, now) then ok = ok + 1 end
	end
	local pick = Relay.Pick()
	return L.STATUS_RELAY:format(Relay.IAmRelay() and L.YES or L.NO, ok, total, pick and U.Display(pick.name) or "—", #hold)
end)
