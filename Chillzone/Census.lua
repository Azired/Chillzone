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
local advertisements = {} -- последнее K1: готовность старых клиентов без отпечатка в H1
local lastSent, lastSentAt = nil, -1e9
local lastQ1Answer = -1e9
local pendingQ1
local responseSerial = 0
local trustCatchupPending = false
local lastHelloFp

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

-- Ключ репортёра гильдии. withoutMe — выбор без меня: кто пересылает гильдии, пока я после
-- входа молчу (LOGIN_QUIET), хотя гильдия уже выбрала меня.
function Census.Reporter(withoutMe)
	if not ns.myKey then return nil end
	local now = ns.Now()
	local live = Live(now)
	local mine = not withoutMe and ns.Security.MyCertificate() ~= nil
	local function ready(key)
		if not Trusted(key) then return false end
		if key == ns.myKey then return mine end
		local p = live[key]
		-- Чужой сертификат проверяется при чтении S1. Выборы зависят от объявления H1,
		-- а не от локального кэша: иначе новый клиент отбрасывает ранние RG.
		if not p then return false end
		if not p.legacy then return p.fp ~= nil end
		local a = advertisements[key]
		return not (a and a.missing and now - a.t <= C.PEER_WINDOW)
	end
	local officers = not withoutMe and ready(ns.myKey) and ns.Roster.Fresh() and ns.Roster.IsOfficerRank(ns.Roster.RankOf(ns.me))
	for key in pairs(live) do
		if ready(key) and ns.Roster.IsOfficerRank(ns.Roster.byKey[key]) then officers = true end
	end
	local function eligible(key)
		return ready(key) and (not officers or ns.Roster.IsOfficerRank(ns.Roster.byKey[key]))
	end
	local me = not withoutMe and ns.myKey or nil
	return Codec.PickReporter(me, ns.char and ns.char.shareZones or false, live, now, C.PEER_WINDOW, eligible)
end

function Census.IsReporter()
	if not ns.IsMember() or not ns.loginAt then return false end
	if ns.Now() - ns.loginAt < C.LOGIN_QUIET then return false end
	return Census.Reporter() == ns.myKey
end

---------------------------------------------------------------------------
-- Смена репортёра. Новый репортёр регистрируется у реле не сразу: после входа он молчит
-- LOGIN_QUIET, у реле — раз в 15 секунд. Всё это время реле шлют RM прежнему по его аренде.
-- Поэтому прежний ещё REPORTER_HANDOVER секунд пересылает их гильдии и называет реле
-- преемника (RU), а гильдия принимает RG и от него.
---------------------------------------------------------------------------
local elected, previous = nil, nil -- ключ выбранного репортёра; { key, untilAt } — прежний
local acting, handingUntil = false, nil -- я репортёр; до каких пор я передаю аренду

function Census.Track()
	local now = ns.Now()
	local cert = ns.Security.MyCertificate()
	if ns.IsMember() and (cert and cert.fp or nil) ~= lastHelloFp then Census.SendHello() end
	local key = Census.Reporter()
	if key ~= elected then
		pendingQ1 = nil -- старое ожидание и его отправки относятся к прежним выборам
		previous = elected and { key = elected, untilAt = now + C.REPORTER_HANDOVER } or nil
		elected = key
	end
	local me = Census.IsReporter()
	if me == acting then return end
	acting = me
	handingUntil = not me and now + C.REPORTER_HANDOVER or nil
	ns.Fire("REPORTER", me)
end

-- Я был репортёром и передаю дела: пересылаю гильдии RM по старой аренде.
function Census.Handing()
	Census.Track()
	return handingUntil ~= nil and ns.Now() <= handingUntil
end

-- Я пересылаю гильдии то, что приходит от реле: репортёр или передающий дела.
function Census.Forwarding()
	return Census.IsReporter() or Census.Handing()
end

-- Имя преемника, которому я передаю аренду, или nil.
function Census.Successor()
	local p = elected and elected ~= ns.myKey and peers[elected]
	return p and p.name or nil
end

-- Принимать ли от key пересланное гильдии (RG): от выбранного репортёра, от прежнего, пока
-- он передаёт дела, и, пока я сам после входа молчу, — от того, кто был бы выбран без меня.
function Census.MayForward(key)
	if not key then return false end
	Census.Track()
	if key == elected then return true end
	if previous and previous.key == key and ns.Now() <= previous.untilAt then return true end
	return elected == ns.myKey and not acting and key == Census.Reporter(true)
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
	local cert = ns.Security.MyCertificate()
	lastHelloFp = cert and cert.fp or nil
	local hello = Codec.EncodeHello(ns.VERSION, ns.char.shareZones, R and R.IAmRelay() or false, lastHelloFp)
	ns.Comm.Send("GUILD", hello, { key = "hello" })
end

ns.Comm.On("H1", function(msg, sender, dist)
	if dist ~= "GUILD" then return end
	local h = Codec.DecodeHello(msg)
	if not h then return end
	local key = U.Key(sender)
	local known = peers[key]
	peers[key] = { t = ns.Now(), z = h.zones, r = h.relay, name = sender, version = h.version,
		fp = h.fp, legacy = h.legacy }
	-- Новый согильдиец с аддоном: ответить своим приветом, чтобы выборы сошлись быстрее.
	if not known then ns.After(math.random(2, 6), "hello back", Census.SendHello) end
end)

-- Security уже проверила канал, ростер и формат ключа. Последнее K1 заменяет
-- прежнее даже при смене identity; положительное объявление снимает отказ ~0.
-- Это сведения самого игрока, а не зависимость выборов от нашего кэша KP.
ns.On("AUTH_ADVERTISEMENT", function(sender, public, missing)
	advertisements[U.Key(sender)] = { public = public, missing = missing, t = ns.Now() }
end)

---------------------------------------------------------------------------
-- Отчёты
---------------------------------------------------------------------------

-- Отчёт подписывается асинхронно (Security.Seal). Отправленным он считается только после
-- подписи: если она не удалась, следующая проверка через 10 секунд попробует снова.
-- signing — подпись уже идёт (не ставить вторую); epoch меняется со сменой гильдии.
local signing, epoch = nil, 0
local SIGN_WAIT = 30 -- подпись дольше этого считается потерянной

function Census.MaybeReport(force)
	if not Census.IsReporter() then return end
	local r = ns.Roster.report
	if not r then return end
	local now = ns.Now()
	if signing and now - signing < SIGN_WAIT then return end
	if not force and now - lastSentAt < C.REPORT_EVERY - 5 then return end
	r.users = Census.Users()
	local shareable = Codec.Shareable(r, ns.char.shareZones)
	local raw = Codec.EncodeReport(shareable)
	-- Время исключаем только из сравнения, не из отправляемого отчёта.
	-- Shareable вернул копию: время ростера и все поля (включая связных) сохраняются.
	shareable.st = 0
	local body = Codec.EncodeReport(shareable)
	if not force and body == lastSent and now - lastSentAt < C.REPORT_IDLE then return end
	local mine, online, total = epoch, r.online, r.total
	signing = now
	local queued, why = ns.Security.Seal(raw, function(wire, failed)
		if mine ~= epoch then return end
		signing = nil
		if not wire then
			ns.Log("отчёт не подписан (%s), повтор при следующей проверке", tostring(failed))
			return
		end
		lastSent, lastSentAt = body, ns.Now()
		Census.lastRaw = wire
		ns.Relay.EnsureRegistered()
		ns.Relay.Out("L", wire)
		ns.Log("отчёт отправлен: %d/%d онлайн", online, total)
	end)
	if not queued then
		signing = nil
		ns.Log("отчёт не подписан (%s), повтор при следующей проверке", tostring(why))
	end
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
local function AnnounceResponse(response, phase)
	local function Current() return response.epoch == epoch and Census.IsReporter() end
	if not Current() then return end
	local msg = "Q2~" .. response.id .. "~" .. phase
	-- Короткое объявление не должно ждать за WHISPER-регистрациями в общей очереди.
	-- При отказе игры остаётся обычный ограниченный повтор очереди.
	if not ns.Comm.SendNow("GUILD", msg) then
		ns.Comm.Send("GUILD", msg, { prio = true, key = "q2:" .. phase, guard = Current })
	end
end

local function AnswerQ1(cached, pending)
	local now = ns.Now()
	if now - lastQ1Answer < C.Q1_GAP or #cached == 0 then return false end
	lastQ1Answer = now
	if pending then pending.remaining = #cached end
	local response
	if not pending then
		responseSerial = responseSerial % 999999 + 1
		response = { id = responseSerial, remaining = #cached, epoch = epoch }
		AnnounceResponse(response, "B")
	end
	ns.Security.ShareTrust() -- корни и ключ репортёра — раньше самих конвертов
	for _, c in ipairs(cached) do
		ns.Security.IntroduceWire("GUILD", c.raw, true) -- спросивший мог отбросить прежний KP
		local opts = { key = "q1:" .. c.key }
		if pending then
			opts.guard = function()
				return Census.Forwarding() and pendingQ1 == pending and pending.missing[c.raw] ~= nil
			end
			opts.done = function()
				pending.remaining = pending.remaining - 1
				if pending.remaining == 0 and pendingQ1 == pending then pendingQ1 = nil end
			end
		else
			opts.done = function()
				response.remaining = response.remaining - 1
				-- E завершает попытки отправки. Если часть не ушла, прежний увидит её
				-- в missing и досылает; при утрате E сработает ограниченный таймер.
				if response.remaining == 0 then AnnounceResponse(response, "E") end
			end
		end
		ns.Comm.Send("GUILD", Codec.EncodeRM("RG", "L", c.origin, c.raw), opts)
	end
	return true
end

-- Relay вызывает до дедупликации: уже известный нам отчёт тоже может быть
-- ответом преемника вошедшему игроку. Только точный подписанный отчёт и его автор.
function Census.ObserveResponse(sender, origin, wire)
	if not pendingQ1 or U.Key(sender) ~= pendingQ1.reporter then return end
	local c = pendingQ1.missing[wire]
	if c and U.Key(origin) == U.Key(c.origin) then pendingQ1.missing[wire] = nil end
end

local function Fallback(pending)
	if pendingQ1 ~= pending or pending.sent then return end
	local forwarding = Census.Forwarding() -- Track может отменить ожидание при новых выборах
	if pendingQ1 ~= pending then return end
	if not forwarding or not next(pending.missing) then pendingQ1 = nil; return end
	local now = ns.Now()
	if pending.response and not pending.finished and now < pending.deadline then
		ns.After(pending.deadline - now, "census handover fallback", function() Fallback(pending) end)
		return
	end
	local missing = {}
	for _, c in ipairs(pending.cached) do
		if pending.missing[c.raw] then missing[#missing + 1] = c end
	end
	pending.sent = true
	if not AnswerQ1(missing, pending) then pendingQ1 = nil end
end

-- Необязательное объявление ответа: старые клиенты неизвестный Q2 пропускают.
-- Только текущий выбранный репортёр может отложить наш уже ожидающий ответ.
ns.Comm.On("Q2", function(msg, sender, dist)
	local pending = pendingQ1
	if dist ~= "GUILD" or not pending or pending.sent or U.Key(sender) ~= pending.reporter
		or Census.Reporter() ~= pending.reporter then return end
	local id, phase = msg:match("^Q2~(%d+)~([BE])$")
	if not id or #id > 6 or tonumber(id) < 1 then return end
	if phase == "B" and not pending.response then
		pending.response, pending.deadline = id, ns.Now() + 60
	elseif phase == "E" and pending.response == id then
		pending.finished = true
		Fallback(pending)
	end
end)

ns.Comm.On("Q1", function(_, sender, dist)
	if dist ~= "GUILD" or not Census.Forwarding() then return end
	if ns.Now() - lastQ1Answer < C.Q1_GAP then return end
	local cached = ns.Data.Cached()
	if Census.IsReporter() then
		-- Новый ответ может заменить задания с тем же q1: ключом без их старого done.
		pendingQ1 = nil
		AnswerQ1(cached)
		return
	end
	if pendingQ1 or #cached == 0 then return end
	-- Без объявления нового репортёра прежний помогает через пять секунд. Начатый
	-- ответ ждём до E, но максимум минуту; повторные B не продлевают этот срок.
	local pending = { reporter = Census.Reporter(), missing = {}, cached = cached }
	for _, c in ipairs(cached) do pending.missing[c.raw] = c end
	pendingQ1 = pending
	ns.After(5, "census handover fallback", function() Fallback(pending) end)
end)

-- Отчёты, пришедшие до подтверждения нового корня, были отброшены. Один раз запросить их у
-- репортёра своей гильдии, выждав обычную паузу Q1. Несколько корней подряд — один запрос;
-- авторам отчётов ничего не шлём.
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
	ns.Every(5, "reporter change", Census.Track)
	ns.Every(10, "report check", function() Census.MaybeReport(false) end)
	ns.Every(300, "prune", function() ns.Data.Prune() end)
end)

ns.On("GUILD_CHANGED", function()
	wipe(peers)
	wipe(advertisements)
	pendingQ1, lastQ1Answer = nil, -1e9
	lastHelloFp = nil
	elected, previous, acting, handingUntil = nil, nil, false, nil
	lastSent, lastSentAt, signing, epoch = nil, -1e9, nil, epoch + 1
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

