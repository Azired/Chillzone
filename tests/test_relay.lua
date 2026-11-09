-- Интеграция: три гильдии, реле, перепись, чат — в симуляторе мира.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

-- Доверие по званию (как до TRUST_ANY_MEMBER): только глава, офицеры и «Ветеран».
local RANKS = { TRUST_ANY_MEMBER = false }
local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Громосвёрт, Благословенный клинок Искателя Ветра]|h|r"

local function Build(opts)
	opts = opts or {}
	math.randomseed(opts.seed or tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	w:AddOffline("Чиллзон", "Старый Воин-CAMWOWUS2Realm3PvE", 3, 60, "WARRIOR", 40)
	w:AddOffline("Чиллзон Север", "Тихий Друид-CAMWOWUS2Realm7PvE", 3, 41, "DRUID", 2)
	for i = 1, (opts.officers or 0) do
		w:AddOffline("Орден Чиллзона", ("Офицерскийперсонаж%02d Длиннофамильный-CAMWOWUS2Realm3PvE"):format(i), 1, 60, "PRIEST", i)
	end
	local cfg = opts.config
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, zone = "Штормград", config = cfg })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, realm = "CAMWOWUS2Realm3PvE", class = "PALADIN", config = cfg })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST", config = cfg })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR", zone = "Тернистая долина", config = cfg })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, realm = "CAMWOWUS2Realm5PvE", class = "DRUID", config = cfg })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER", config = cfg })
	if not opts.run or opts.run > 30 then
		w:Run(30)
		w:Init(c.A, c.V, c.G)
		w:Pair(c.V, c.K)
		w:Pair(c.G, c.K)
	end
	w:Run(opts.run or 400)
	if not opts.run or opts.run > 30 then
		-- Boris is an active sender: first learn discovery hints from the root,
		-- then fetch the other candidates' credentials. Passive readers do neither.
		c.B.ns.Relay.PingAll(); w:Run(45)
		c.B.ns.Relay.PingAll(); w:Run(45)
	end
	return w, c
end

local function Key(c, name) return c.ns.Util.Key(name) end

-- Выход из игры как на сервере: строка ростера остаётся, но уже вне игры.
local function Quit(w, cl)
	cl:Logout()
	w:AddOffline(cl.guild, cl:Name() .. "-" .. cl.realm, cl.rank, cl.level, cl.class, 0)
end

-- Настоящие ростер и перепись, но без фоновых таймеров: проверяем точные границы
-- REPORT_EVERY / REPORT_IDLE и не смешиваем отправку отчёта с доставкой по сети.
local function CensusReports(withVeteran)
	local w = Wow.World()
	w:Guild("Чиллзон")
	if withVeteran then
		w:AddOffline("Чиллзон", "Тихий Ветеран-CAMWOWUS2Realm7PvE", 2, 60, "WARRIOR", 3)
	end
	local c = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local reports = {}
	-- Только расписание: считаем репортёра сертифицированным, подпись завершаем синхронно.
	-- Настоящие подписи и выдача сертификатов проверяются в сетевых тестах.
	c.ns.Security.MyCertificate = function() return {} end
	c.ns.Security.Seal = function(raw, done) done(raw); return true end
	c.ns.Relay.Out = function(mode, raw)
		T.eq(mode, "L", "режим переписи")
		reports[#reports + 1] = raw
	end
	local function reportAt(seconds)
		w.now = 1000 + seconds
		c.ns.Roster.Scan()
		local st = c.ns.Roster.report.st
		c.ns.Census.MaybeReport(false)
		T.eq(c.ns.Roster.report.st, st, "сравнение не меняет время исходного ростера")
	end
	return w, c, reports, reportAt
end

for _, withVeteran in ipairs({ false, true }) do
	local hasVeteran = withVeteran
	T.test("census: неизменный отчёт ждёт REPORT_IDLE, связные " .. (hasVeteran and "есть" or "отсутствуют"), function()
		local _, c, reports, reportAt = CensusReports(hasVeteran)
		reportAt(0)
		T.eq(#reports, 1, "первый отчёт отправлен")
		local first = assert(c.ns.Codec.DecodeReport(reports[1]))
		T.eq(first.st, c.ns.ServerTime(), "в отправленном отчёте настоящее время")
		T.eq(#first.veterans, hasVeteran and 1 or 0, "связные сохранены в отчёте")
		reportAt(c.ns.Config.REPORT_EVERY)
		T.eq(#reports, 1, "новое время не считается изменением переписи")
		reportAt(c.ns.Config.REPORT_IDLE - 1)
		T.eq(#reports, 1, "до REPORT_IDLE повторов нет")
		reportAt(c.ns.Config.REPORT_IDLE)
		T.eq(#reports, 2, "по REPORT_IDLE перепись обновляется")
		local refreshed = assert(c.ns.Codec.DecodeReport(reports[2]))
		T.eq(refreshed.st, c.ns.ServerTime(), "повторный отчёт содержит свежее время")
		T.eq(refreshed.st - first.st, c.ns.Config.REPORT_IDLE, "время не обнулено")
	end)
end

T.test("census: изменение состава отправляется по REPORT_EVERY", function()
	local w, c, reports, reportAt = CensusReports(false)
	reportAt(0)
	w:AddOffline("Чиллзон", "Новый Участник-CAMWOWUS2Realm7PvE", 3, 20, "MAGE", 1)
	reportAt(c.ns.Config.REPORT_EVERY - 6)
	T.eq(#reports, 1, "изменение ждёт обычного интервала")
	reportAt(c.ns.Config.REPORT_EVERY)
	T.eq(#reports, 2, "изменённый состав не ждёт REPORT_IDLE")
	T.eq(assert(c.ns.Codec.DecodeReport(reports[2])).total, 2, "новый участник учтён")
end)

T.test("census: изменение списка связных не теряется при сравнении", function()
	local w, c, reports, reportAt = CensusReports(true)
	reportAt(0)
	-- Меняется только имя связного: все числовые поля и распределение званий прежние.
	w.guilds["Чиллзон"].members[1].full = "Другой Ветеран-CAMWOWUS2Realm7PvE"
	reportAt(c.ns.Config.REPORT_EVERY)
	T.eq(#reports, 2, "изменённый список учтён до REPORT_IDLE")
	local changed = assert(c.ns.Codec.DecodeReport(reports[2]))
	T.eq(#changed.veterans, 1, "новый связной сохранён")
	T.eq(changed.veterans[1].name, "Другой Ветеран", "имя связного")
end)

T.test("census: отчёт считается отправленным только после подписи", function()
	local w, c, reports, reportAt = CensusReports(false)
	local S = c.ns.Security
	-- Подпись не встала в очередь: отчёта нет, и следующая проверка не ждёт REPORT_EVERY.
	S.Seal = function() return false, "busy" end
	reportAt(0)
	T.eq(#reports, 0, "очередь подписей полна — отчёта нет")
	-- Подпись не удалась уже в колбэке.
	S.Seal = function(_, done) done(nil, "failed"); return true end
	reportAt(10)
	T.eq(#reports, 0, "подпись не удалась — отчёта нет")
	-- Подпись идёт долго: вторую не ставим, время отправки — по завершении.
	local calls, pending = 0, nil
	S.Seal = function(raw, done) calls = calls + 1; pending = function() done(raw) end; return true end
	reportAt(20)
	reportAt(30)
	T.eq(calls, 1, "пока идёт подпись, вторая не ставится")
	T.eq(#reports, 0, "до конца подписи отчёт не ушёл")
	w.now = w.now + 5
	pending()
	T.eq(#reports, 1, "подписанный отчёт ушёл")
	reportAt(35 + c.ns.Config.REPORT_EVERY - 6)
	T.eq(#reports, 1, "интервал считается от конца подписи")
	T.eq(calls, 1, "неизменный отчёт не подписывается заново")
	T.eq(#c.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: глобалы не утекают", function()
	local _, c = Build({ run = 5 })
	for name, cl in pairs(c) do
		local leaks = cl:Leaks()
		T.eq(#leaks, 0, name .. ": утечки " .. table.concat(leaks, ", "))
	end
end)

T.test("relay: выборы репортёра одинаковы у всех", function()
	local _, c = Build()
	T.eq(c.B.ns.Census.Reporter(), Key(c.B, "Вера Верная"), "officer has reporter priority")
	T.eq(c.V.ns.Census.Reporter(), Key(c.V, "Вера Верная"), "all peers agree on officer priority")
	T.ok(c.V.ns.Census.IsReporter(), "leader reports while online")
	T.eq(c.M.ns.Census.Reporter(), Key(c.M, "Арагорн Светлый"), "главная")
	T.ok(c.A.ns.Relay.IAmRelay() and c.K.ns.Relay.IAmRelay(), "офицеры главной — реле")
	T.no(c.B.ns.Relay.IAmRelay(), "Борис не реле")
end)

T.test("relay: согласие делиться зонами переключает репортёра", function()
	local w, c = Build()
	for _, cl in pairs(c) do cl:Slash("/chillzone", "zones off") end
	w:Run(200)
	c.V:Slash("/chillzone", "zones on")
	w:Run(200)
	T.eq(c.B.ns.Census.Reporter(), Key(c.B, "Вера Верная"), "у Бориса")
	T.eq(c.V.ns.Census.Reporter(), Key(c.V, "Вера Верная"), "у Веры")
	w:Run(200)
	local row = c.G.ns.Data.Row("Чиллзон Север")
	T.ok(row and next(row.r.zones), "зоны Севера видны после согласия")
	local main = c.G.ns.Data.Row("Чиллзон")
	T.eq(next(main.r.zones), nil, "зон главной гильдии без согласия нет")
end)

T.test("relay: перепись сходится у всех", function()
	local _, c = Build()
	for name, cl in pairs(c) do
		local mine = cl.ns.MyGuild()
		for _, g in ipairs({ "Чиллзон", "Чиллзон Север", "Орден Чиллзона" }) do
			local row = cl.ns.Data.Row(g)
			T.ok(row and row.r, name .. " знает " .. g)
			T.eq(row.mine == true, g == mine, name .. ": своя гильдия только из ростера, " .. g)
		end
	end
	local row = c.G.ns.Data.Row("Чиллзон")
	T.eq(row.r.leader, "Карл Великий", "глава главной")
	T.eq(row.r.total, 4, "численность главной")
	T.eq(row.r.online, 3, "онлайн главной")
	local tree = c.G.ns.Data.Kingdom()
	T.ok(tree.king and tree.king.leader == "Карл Великий", "король")
	T.eq(Wow.CertRank(c.B.ns, "Чиллзон", "Арагорн Светлый"), 1, "ранг офицера главной")
	T.eq(Wow.CertRank(c.B.ns, "Орден Чиллзона", "Глеб Гордый-CAMWOWUS2Realm7PvE"), 0, "ранг главы")
end)

T.test("relay: реле выучено из ответа доверенного реле", function()
	local _, c = Build({ config = RANKS })
	local learned = c.B.ns.store.relays[Key(c.B, "Карл Великий")]
	T.ok(learned, "Карл выучен")
	T.eq(c.B.ns.Relay.TrustOf("Карл Великий"), "officer", "signed officer credential")
	T.eq(c.B.ns.Relay.TrustOf("Мира Тихая"), nil, "не офицер — не реле")
end)

T.test("relay: без проверки звания любой участник — репортёр, реле и пересылает RG", function()
	local w, c = Build()
	T.ok(c.M.ns.Relay.IAmRelay(), "«Рядовой» главной — реле")
	T.eq(c.A.ns.Relay.TrustOf("Мира Тихая"), "member", "согильдийцы — по ростеру")
	T.eq(c.B.ns.Relay.TrustOf("Мира Тихая"), "member", "member credential verified independently of gossip")
	-- Рядовой Севера с зонами — единственный, кто делится зонами, поэтому репортёр он.
	local Ak = w:Client({ first = "Аким", surname = "Альфа", guild = "Чиллзон Север", rank = 3 })
	c.B:Slash("/chillzone", "zones off")
	Ak:Slash("/chillzone", "zones on")
	w:Run(200)
	T.eq(Ak.ns.Census.Reporter(), Key(Ak, "Вера Верная"), "zone sharing does not preempt an officer")
	c.V:Logout()
	w:Run(220)
	for _, cl in ipairs({ c.B, Ak }) do
		T.eq(cl.ns.Census.Reporter(), Key(cl, "Аким Альфа"), cl:Name() .. ": репортёр — Аким")
	end
	T.ok(Ak.ns.Census.IsReporter(), "Аким репортёр")
	T.eq(Ak.ns.Roster.TrustOf("Аким Альфа"), "member", "роль — участник")
	-- Строка Глеба доходит до Севера через Акима (RM от реле, затем RG гильдии).
	c.G:Slash("/cz1", "привет Северу через рядового")
	w:Run(30)
	for _, cl in ipairs({ c.B, Ak }) do T.eq(cl:Saw("привет Северу через рядового"), 1, cl:Name() .. " видит") end
	T.ok(Ak.ns.Relay.stats.delivered > 0, "certified ordinary reporter delivered real signed messages")
	Ak:Slash("/chillzone", "status")
	T.ok(Ak:Saw("может быть любой участник") >= 1, "status объясняет режим")
end)

T.test("relay: строка чата доходит один раз до всех (GUILD + реле), ссылка цела", function()
	local w, c = Build()
	local text = "всем привет " .. LINK
	c.B:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	for _, e in ipairs(w.log) do T.no(e.dist == "CHANNEL", "в канал ничего не уходит") end
	for name, cl in pairs(c) do T.eq(next(cl.joined), nil, name .. ": ни в каком канале") end
end)

T.test("relay: реле пишет само — без шёпота RL", function()
	local w, c = Build()
	w:Run(c.A.ns.Config.RELAY_SETTLE) -- сразу после входа реле шлёт своё и через других
	local text = "слово реле"
	local before = #w.log
	c.A:Slash("/cz1", text)
	w:Run(30)
	for i = before + 1, #w.log do
		local e = w.log[i]
		T.no(e.from == "Арагорн Светлый" and e.dist == "WHISPER" and e.msg:find("^RL~"), "реле не шепчет RL себе")
	end
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит") end
end)

T.test("relay: вопрос сразу после ответа не делает живое реле офлайн", function()
	local w, c = Build()
	local B = c.B
	local e = B.ns.Relay.Known()[Key(B, c.A:Name())]
	T.ok(e, "Борис знает реле")
	w:Run(10)
	e.asked, e.down = nil, nil
	B.ns.Relay.PingAll()
	T.ok(e.asked, "вопрос задан")
	for _ = 1, 100 do
		w:Run(0.1)
		if not e.asked then break end
	end
	T.no(e.asked, "реле ответило")
	B.ns.Relay.PingAll()
	w:Run(B.ns.Config.RELAY_TIMEOUT + 2)
	T.no(e.down, "реле живо, хотя второй вопрос пришёлся на его паузу")
	B.ns.Relay.PingAll()
	T.ok(e.asked, "после паузы реле снова спрашивают")
end)

T.test("relay: регистрация уходит, даже если реле только что подтвердилось", function()
	local w, c = Build()
	local V = c.V
	local gk = V.ns.Util.GuildKey("Чиллзон Север")
	local e = V.ns.Relay.Known()[Key(V, c.A:Name())]
	T.ok(e, "Вера знает реле")
	T.ok(V.ns.Census.IsReporter(), "Вера — репортёр")
	-- Сертификат реле обновляет verified так же, как ответ: продлевать аренду это не мешает.
	local ttl = c.A.ns.Relay.REG_TTL
	for _ = 1, ttl * 2 do
		e.verified = w.now
		w:Run(1)
	end
	local held = c.A.ns.Relay.Reporters()[gk]
	T.ok(held and held.key == Key(c.A, V:Name()), "аренда у Веры")
	T.ok(w.now - held.t <= ttl, "аренда продлевается")
	T.no(e.asked, "ответа на паузе реле не ждём")
	T.no(e.down, "живое реле не считается офлайн")
	T.eq(#V.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: зоны включаются один раз, дальше решает игрок", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local fresh = w:Client({ first = "Новый", surname = "Игрок", guild = "Чиллзон", rank = 3 })
	local db = { chars = { [Key(fresh, "Старый Игрок")] = { shareZones = false } } }
	local old = w:Client({ first = "Старый", surname = "Игрок", guild = "Чиллзон", rank = 3, db = db })
	w:Run(1)
	T.eq(fresh.ns.char.shareZones, true, "новый персонаж")
	T.eq(old.ns.char.shareZones, true, "заходивший раньше персонаж")
	old:Slash("/chillzone", "zones off")
	old:Logout()
	local back = w:Client({ first = "Старый", surname = "Игрок", guild = "Чиллзон", rank = 3, db = db })
	w:Run(1)
	T.eq(back.ns.char.shareZones, false, "отказ после включения сохраняется")
end)

T.test("relay: уровни чата — офицеры и главы", function()
	local w, c = Build()
	c.B:Slash("/cz2", "можно мне?")
	T.ok(c.B:Saw("можно писать только") >= 1, "Борису отказано")
	w:Run(5)
	c.V:Slash("/cz2", "офицерам привет")
	w:Run(30)
	for _, n in ipairs({ "A", "K", "G", "V" }) do T.eq(c[n]:Saw("офицерам привет"), 1, n .. " видит офицерский") end
	T.eq(c.M:Saw("офицерам привет"), 0, "рядовой не видит")
	T.eq(c.B:Saw("офицерам привет"), 0, "не офицер не видит")
	c.G:Slash("/cz3", "главам слово")
	w:Run(30)
	for _, n in ipairs({ "A", "K", "V", "G" }) do T.eq(c[n]:Saw("главам слово"), 1, n .. " видит") end
	T.eq(c.B:Saw("главам слово"), 0, "Борис не видит")
end)

T.test("relay: строка не пропадает молча, если подпись не удалась", function()
	local w, c = Build()
	local S = c.B.ns.Security
	local seal = S.Seal
	S.Seal = function() return false, "busy" end
	c.B:Slash("/cz1", "строка без подписи")
	T.eq(c.B:Saw("подписи не успевают"), 1, "очередь полна — причина видна")
	-- Подпись встала в очередь, но не удалась: причина — один раз на строку из нескольких частей.
	S.Seal = function(_, done) w:Schedule(w.now + 1, function() done(nil, "failed") end, c.B); return true end
	c.B:Slash("/cz1", ("длинная строка "):rep(30))
	w:Run(5)
	T.eq(c.B:Saw("подписать её не удалось"), 1, "сбой в колбэке — причина видна один раз")
	S.Seal = function() return false, "nocert" end
	c.B:Slash("/cz1", "строка до сертификата")
	T.eq(c.B:Saw("Ключ ещё не подтверждён"), 1, "нет сертификата — причина видна")
	w:Run(30)
	for name, cl in pairs(c) do
		T.eq(cl:Saw("строка без подписи"), 0, name .. ": неподписанная строка никуда не ушла")
	end
	S.Seal = seal
	c.B:Slash("/cz1", "строка после сбоя")
	w:Run(30)
	T.eq(c.G:Saw("строка после сбоя"), 1, "после сбоя строка уходит сразу, без «слишком часто»")
	T.eq(#c.B.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: уровень канала у отправителя — по сертификату, как у получателей", function()
	local w, c = Build()
	local V = c.V
	local clock = V.ns.ServerTime
	-- Звание в ростере Веры прежнее, а роль в сертификате уже не подтверждена (AUTH_ROLE_TTL).
	local issued = V.ns.Security.MyCertificate().issued
	V.ns.ServerTime = function() return issued + V.ns.Config.AUTH_ROLE_TTL + 1 end
	T.eq(V.ns.Chat.MyLevel(), 3, "по званию Вера — глава")
	T.eq(V.ns.Security.Level(V.ns.Security.MyCertificate()), 1, "по сертификату — нет")
	V:Slash("/cz3", "глава без свежей роли")
	T.ok(V:Saw("сертификат больше не подтверждает") >= 1, "Вера видит причину")
	V.ns.ServerTime = clock
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("глава без свежей роли"), 0, name .. ": строка не ушла") end
	V:Slash("/cz3", "глава со свежей ролью")
	w:Run(30)
	T.eq(c.G:Saw("глава со свежей ролью"), 1, "со свежей ролью строка доходит")
end)

T.test("census: новый репортёр сохраняет прежнего после начала работы, но лишь на время передачи", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local A = w:Client({ first = "Алла", surname = "Альфа", guild = "Чиллзон Север", rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	local B = w:Client({ first = "Бетта", surname = "Быстрая", guild = "Чиллзон Север", rank = 1 })
	local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3 })
	local census, C = A.ns.Census, A.ns.Config
	local vera, betta = Key(A, V:Name()), Key(A, B:Name())
	A.ns.store.security.union[A.ns.Util.GuildKey(A.guild)] = { active = true }
	A.ns.Security.MyCertificate = function() return {} end -- проверяем только окно передачи
	A.ns.Roster.Scan()
	census.Peers()[vera] = { t = w.now, name = V:Name() }
	census.Track()
	w.now = C.LOGIN_QUIET - 0.01
	T.ok(census.MayForward(vera), "до начала работы прежний репортёр принимается")
	w.now = C.LOGIN_QUIET + 0.5
	T.ok(census.IsReporter(), "новый репортёр уже работает")
	T.ok(census.MayForward(vera), "прежний ещё может пересылать по живой аренде")
	local deadline = w.now + C.REPORTER_HANDOVER
	census.Peers()[betta] = { t = w.now, name = B:Name() }
	T.eq(census.Reporter(true), betta, "позже появился другой кандидат")
	T.ok(census.MayForward(vera), "запомнен именно прежний репортёр")
	T.no(census.MayForward(betta), "новый кандидат не подменяет прежнего во время передачи")
	T.no(census.MayForward(Key(A, N:Name())), "рядовой не получает права пересылки")
	w.now = deadline
	A.ns.Roster.Scan()
	census.Peers()[vera].t = w.now
	T.ok(census.MayForward(vera), "последняя граница окна включена")
	w.now = deadline + 0.01
	census.Peers()[vera].t = w.now
	T.no(census.MayForward(vera), "новые приветствия не продлевают завершённую передачу")
	A.ns.Fire("GUILD_CHANGED")
	T.no(census.MayForward(vera), "смена гильдии сбрасывает прежнего репортёра")
	T.eq(#A.ns.db.errors, 0, "без ошибок")
end)

T.test("census: новый репортёр узнаёт прежнего после начала работы без продления окна", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local A = w:Client({ first = "Алла", surname = "Альфа", guild = "Чиллзон Север", rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	local census, C = A.ns.Census, A.ns.Config
	local vera = Key(A, V:Name())
	A.ns.store.security.union[A.ns.Util.GuildKey(A.guild)] = { active = true }
	A.ns.Security.MyCertificate = function() return {} end -- проверяем только окно передачи
	A.ns.Roster.Scan()
	w.now = C.LOGIN_QUIET
	census.Track()
	T.no(census.MayForward(vera), "неизвестный аддон ещё не имеет права пересылки")
	w.now = C.LOGIN_QUIET + 5
	census.Peers()[vera] = { t = w.now, name = V:Name() }
	T.ok(census.MayForward(vera), "запоздавшее приветствие прежнего репортёра принято")
	w.now = C.LOGIN_QUIET + C.REPORTER_HANDOVER + 0.01
	A.ns.Roster.Scan()
	census.Peers()[vera].t = w.now
	T.no(census.MayForward(vera), "срок считается от начала работы, а не от запоздавшего приветствия")
	T.eq(#A.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: смена репортёра — чат гильдии не теряется, аренда переходит преемнику", function()
	local w, c = Build()
	local U = c.A.ns.Util
	local gk = U.GuildKey("Чиллзон Север")
	local vera, alla = Key(c.A, "Вера Верная"), Key(c.A, "Алла Альфа")
	local relays = { c.A, c.K, c.M }
	local function Holders()
		local out = {}
		for _, r in ipairs(relays) do
			local held = r.ns.Relay.Reporters()[gk]
			if held and r.ns.Now() - held.t <= 60 then out[held.key] = (out[held.key] or 0) + 1 end
		end
		return out
	end
	T.ok(Holders()[vera], "до смены аренда у Веры")
	-- Входит офицер Севера, которого выборы ставят выше Веры: меньший ключ.
	local Al = w:Client({ first = "Алла", surname = "Альфа", guild = "Чиллзон Север", rank = 1 })
	c.B.ns.Roster.Scan(); c.V.ns.Roster.Scan()
	local lines = {}
	local function Line(i)
		lines[i] = ("смена репортёра %02d"):format(i)
		c.G:Slash("/cz1", lines[i])
	end
	w:Run(15); Line(1)
	w:Run(15); Line(2)
	-- Кандидатом Алла становится, когда получит сертификат и объявит готовность в H1.
	for _ = 1, 30 do
		if c.B.ns.Census.Reporter() == alla then break end
		w:Run(1)
	end
	T.eq(c.B.ns.Census.Reporter(), alla, "гильдия уже выбрала Аллу; членство=" .. tostring(Al.ns.IsMember())
		.. "; сертификат=" .. tostring(Al.ns.Security.MyCertificate() ~= nil) .. "; ошибки=" .. table.concat(Al.ns.db.errors, "; "))
	T.no(Al.ns.Census.IsReporter(), "Алла после входа ещё молчит")
	-- Рядовой Севера пробует перехватить аренду, пока она передаётся: назвать себя
	-- преемником (RU) и зарегистрироваться (RR).
	local cert = c.B.ns.Security.MyCertificate()
	for _, r in ipairs(relays) do
		c.B.ns.Comm.Send("WHISPER", "RU~Чиллзон Север~Борис Быстрый", { target = r:Name(), prio = true })
		c.B.ns.Comm.Send("WHISPER", "RR~Чиллзон Север~" .. cert.fp, { target = r:Name(), prio = true })
	end
	w:Run(5)
	T.ok(Holders()[vera], "аренда всё ещё у Веры")
	T.eq(Holders()[Key(c.A, "Борис Быстрый")], nil, "рядовой аренду не перехватил")
	for i = 3, 10 do w:Run(15); Line(i) end
	w:Run(30)
	T.ok(Al.ns.Census.IsReporter(), "Алла — репортёр")
	local held = Holders()
	T.ok(held[alla], "аренда перешла к Алле")
	T.eq(held[vera], nil, "у Веры аренды больше нет")
	for i, text in ipairs(lines) do
		for _, cl in ipairs({ c.B, c.V, Al }) do T.eq(cl:Saw(text), 1, cl:Name() .. " видит строку " .. i .. " один раз") end
	end
	-- После передачи рядовой тоже не перехватывает аренду Аллы.
	for _, r in ipairs(relays) do
		c.B.ns.Comm.Send("WHISPER", "RU~Чиллзон Север~Борис Быстрый", { target = r:Name(), prio = true })
		c.B.ns.Comm.Send("WHISPER", "RR~Чиллзон Север~" .. cert.fp, { target = r:Name(), prio = true })
	end
	w:Run(5)
	T.ok(Holders()[alla], "аренда у Аллы")
	T.eq(Holders()[Key(c.A, "Борис Быстрый")], nil, "рядовой аренду не перехватил")
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": без ошибок") end
	T.eq(#Al.ns.db.errors, 0, "Алла: без ошибок")
end)

T.test("relay: офицер без сертификата не прерывает доставку чата", function()
	local w, c = Build()
	local guild = "Чиллзон Север"
	local config = c.B.ns.Config
	local boris = Key(c.B, c.B:Name())
	-- Вера — единственный издатель. После её выхода аренду держит сертифицированный ветеран.
	c.V:Logout()
	w:Run(config.PEER_WINDOW + config.LOGIN_QUIET)
	T.ok(c.B.ns.Security.MyCertificate(), "у Бориса есть сертификат")
	T.ok(c.B.ns.Census.IsReporter(), "Борис стал репортёром")
	c.G:Slash("/cz1", "Строка до входа офицера")
	w:Run(30)
	T.eq(c.B:Saw("Строка до входа офицера"), 1)

	local alla = w:Client({ first = "Алла", surname = "Альфа", guild = guild, rank = 1 })
	-- Состав подтвердить некому, а без него Алла не шлёт H1 и флаг n не дойдёт до Бориса.
	alla.ns.store.security.union[alla.ns.Util.GuildKey(guild)] = { active = true }
	w:Run(config.REPORTER_HANDOVER + config.LOGIN_QUIET)
	T.ok(alla.ns.IsMember(), "Алла в составе объединения")
	T.no(alla.ns.Security.MyCertificate(), "издателя нет, Алла ждёт сертификат")
	T.ok(c.B.ns.Census.Peers()[Key(c.B, alla:Name())].unready, "Борис знает, что Алла не готова")
	c.G:Slash("/cz1", "Строка в ожидании сертификата")
	w:Run(30)
	T.eq(c.B:Saw("Строка в ожидании сертификата"), 1, "доставка сохраняется и после окна передачи")
	T.eq(c.B.ns.Census.Reporter(), boris, "Борис сохраняет роль репортёра")
	T.eq(alla.ns.Census.Reporter(), boris, "Алла тоже выбирает Бориса")

	w:Client({ first = c.V.first, surname = c.V.surname, realm = c.V.realm, guild = guild, rank = c.V.rank, db = c.V.ns.db })
	w:Run(config.REPORTER_HANDOVER + config.LOGIN_QUIET + 30)
	T.ok(alla.ns.Security.MyCertificate(), "вернувшийся издатель выдал сертификат")
	T.ok(alla.ns.Census.IsReporter(), "Алла принимает роль репортёра")
	T.eq(c.B.ns.Census.Reporter(), Key(c.B, alla:Name()), "Борис выбирает Аллу после выдачи")
	c.G:Slash("/cz1", "Строка после передачи роли")
	w:Run(30)
	T.eq(c.B:Saw("Строка после передачи роли"), 1)
	T.eq(alla:Saw("Строка после передачи роли"), 1)
end)

T.test("census: ростер снимает с выборов только того, кто молчит с момента чтения", function()
	local w = Wow.World()
	local guild = "Чиллзон Север"
	w:Guild(guild)
	local A = w:Client({ first = "Алла", surname = "Альфа", guild = guild, rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = guild, rank = 1 })
	local census, roster, C = V.ns.Census, V.ns.Roster, V.ns.Config
	local alla, vera = Key(V, A:Name()), V.ns.myKey
	V.ns.Security.MyCertificate = function() return {} end -- проверяем только выбор
	Quit(w, A)
	w.now = 1000
	roster.Scan()
	local heard = w.now + 1
	census.Peers()[alla] = { t = heard, name = A:Name(), z = true }
	w.now = heard + 4
	T.eq(census.Reporter(), alla, "привет новее ростера: тот мог не успеть узнать о входе")
	w.now = heard + C.ROSTER_LAG
	roster.Scan()
	T.eq(census.Reporter(), alla, "привет в пределах отставания ростера")
	w.now = heard + C.ROSTER_LAG + 1
	roster.Scan()
	T.eq(census.Reporter(), vera, "ростер прочитан позже и показывает её вне игры")
	w.now = roster.scannedAt + C.AUTH_ROSTER_TTL + 1
	T.ok(w.now - heard <= C.PEER_WINDOW, "окно приветов ещё не кончилось")
	T.eq(census.Reporter(), alla, "без свежего ростера остаётся только окно приветов")
	T.eq(#V.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: вышедшего репортёра сменяет тот, кого ростер видит в игре, раньше конца окна приветов", function()
	local w, c = Build()
	local guild = "Чиллзон Север"
	local config = c.B.ns.Config
	local Ya = w:Client({ first = "Яна", surname = "Ясная", guild = guild, rank = 3 })
	w:Run(200)
	T.eq(Ya.ns.Census.Reporter(), Key(Ya, "Вера Верная"), "до выхода репортёр — Вера")
	Quit(w, c.V)
	-- Минута до чтения ростера и запас на регистрацию у реле, пока истекает аренда Веры.
	local waited = config.SCAN_EVERY + 45
	T.ok(waited + 20 < config.PEER_WINDOW - 30, "сценарий заканчивается заметно раньше PEER_WINDOW")
	w:Run(waited)
	T.ok(c.B.ns.Census.IsReporter(), "Борис стал репортёром")
	T.eq(Ya.ns.Census.Reporter(), Key(Ya, "Борис Быстрый"), "Яна выбирает Бориса")
	c.G:Slash("/cz1", "строка после выхода репортёра")
	w:Run(20)
	T.eq(c.B:Saw("строка после выхода репортёра"), 1, "репортёр видит строку")
	T.eq(Ya:Saw("строка после выхода репортёра"), 1, "рядовая видит строку через нового репортёра")
	T.eq(#Ya.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: RG от рядового отклоняется — и чат, и отчёт", function()
	local w, c = Build({ config = RANKS })
	local M = c.M -- «Рядовой» главной гильдии
	local Codec = M.ns.Codec
	-- То, что рядовой мог бы отправить одной /run: строку «от главы Севера» и строку
	-- «от Глеба» (уровень всех), обе как будто их переслал репортёр.
	local fake1 = Codec.EncodeRM("RG", "P", "Вера Верная", Codec.EncodeChat("L", "Чиллзон Север", 4242, "DRUID", "поддельный приказ главы"))
	local fake2 = Codec.EncodeRM("RG", "P", "Глеб Гордый", Codec.EncodeChat("A", "Орден Чиллзона", 4243, "HUNTER", "поддельный привет"))
	w:Deliver(M, "GUILD", M.ns.PREFIX, fake1, nil, true)
	w:Deliver(M, "GUILD", M.ns.PREFIX, fake2, nil, true)
	-- И отчёт Севера, где глава — Мира.
	local real = c.K.ns.Data.Row("Чиллзон Север")
	T.ok(real and real.r.leader == "Вера Верная", "настоящий отчёт Севера известен")
	local r = Codec.DecodeReport(real.raw)
	r.leader, r.st = "Мира Тихая", M.ns.ServerTime() + 200
	w:Deliver(M, "GUILD", M.ns.PREFIX, Codec.EncodeRM("RG", "L", "Вера Верная", Codec.EncodeReport(r)), nil, false)
	w:Run(5)
	for _, n in ipairs({ "K", "A" }) do
		T.eq(c[n]:Saw("поддельный приказ главы"), 0, n .. " не видит поддельную строку глав")
		T.eq(c[n]:Saw("поддельный привет"), 0, n .. " не видит поддельную строку всех")
		T.eq(c[n].ns.Data.Row("Чиллзон Север").r.leader, "Вера Верная", n .. ": глава Севера прежний")
		T.ok(c[n].ns.Relay.stats.untrusted >= 3, n .. ": RG посчитаны как недоверенные")
	end
end)

T.test("relay: рядовой не становится репортёром — ни с первым именем, ни с зонами", function()
	local w, c = Build({ config = RANKS })
	local Ak = w:Client({ first = "Аким", surname = "Альфа", guild = "Чиллзон Север", rank = 3, config = RANKS })
	Ak:Slash("/chillzone", "zones on")
	w:Run(200)
	for _, cl in ipairs({ c.B, c.V, Ak }) do
		T.eq(cl.ns.Census.Reporter(), Key(cl, "Вера Верная"), cl:Name() .. ": officer has priority over veteran")
	end
	T.eq(c.B.ns.Roster.TrustOf("Борис Быстрый"), "rank", "Борис — «Ветеран»")
	T.eq(c.B.ns.Roster.TrustOf("Аким Альфа"), nil, "Аким — рядовой")
	-- Ушли Борис и Вера — в Севере некому быть репортёром.
	c.B:Logout()
	c.V:Logout()
	w:Run(200)
	T.eq(Ak.ns.Census.Reporter(), nil, "репортёра нет")
	Ak:Slash("/chillzone", "status")
	T.ok(Ak:Saw("нет главы, офицера или «Ветеран»") >= 1, "status объясняет")
end)

T.test("relay: связной главной гильдии — реле, другие гильдии его узнают", function()
	local w, c = Build({ config = RANKS })
	local Vt = w:Client({ first = "Вадим", surname = "Ветров", guild = "Чиллзон", rank = 2, class = "ROGUE", config = RANKS })
	T.no(c.M.ns.Relay.IAmRelay(), "«Рядовой» главной — нет")
	w:Run(700)
	c.B.ns.Relay.PingAll(); w:Run(30)
	c.B.ns.Relay.PingAll(); w:Run(30)
	T.ok(Vt.ns.Relay.IAmRelay(), "veteran relays after native membership certification")
	local row = c.B.ns.Data.Row("Чиллзон")
	local listed = false
	for _, v in ipairs(row.r.veterans or {}) do if v.name == "Вадим Ветров" then listed = true end end
	T.ok(listed, "связной — в отчёте главной")
	T.eq(c.B.ns.Relay.TrustOf("Вадим Ветров"), "member", "certified veteran is a nonofficer transport")
	T.eq(c.K.ns.Relay.TrustOf("Вадим Ветров"), "member", "certified veteran is not an officer")
	-- Без звания связных в настройках «Ветеран» — обычный участник.
	Vt.ns.Config.RELAY_RANK = ""
	T.no(Vt.ns.Relay.IAmRelay(), "RELAY_RANK пустой — не реле")
end)

T.test("relay: офицер — по игровому флагу звания, а не по номеру ранга", function()
	local w, c = Build()
	-- В главной гильдии звание 1 без офицерских прав, в Севере офицеры — звание 2 («Ветеран»).
	w.guilds["Чиллзон"].officers = { [0] = true }
	w.guilds["Чиллзон Север"].officers = { [0] = true, [2] = true }
	for _, cl in pairs(c) do cl:Fire("GUILD_RANKS_UPDATE") end
	w:Run(400)
	T.eq(c.B.ns.Chat.MyLevel(), 2, "Борис (звание 2 с флагом) — офицер")
	T.eq(c.A.ns.Chat.MyLevel(), 1, "Арагорн (звание 1 без флага) — участник")
	T.ok(c.B.ns.GuildChat.CanOfficer(), "Борису доступен офицерский чат гильдии")
	T.no(c.A.ns.GuildChat.CanOfficer(), "Арагорну — нет")
	-- Борис — репортёр Севера, его сертификат приходит к Глебу вместе с переписью. Без
	-- сертификата перепись сама офицерских прав не даёт.
	c.G.ns.store.security.certs[c.G.ns.Util.GuildKey("Чиллзон Север")][Key(c.G, "Борис Быстрый")] = nil
	T.eq(Wow.CertRank(c.G.ns, "Чиллзон Север", "Борис Быстрый"), nil, "перепись не выдаёт Борису офицерские права")
	T.eq(Wow.CertRank(c.G.ns, "Чиллзон", "Арагорн Светлый"), nil, "Арагорна в офицерах главной нет")
	c.B:Slash("/cz2", "офицер по флагу")
	w:Run(30)
	T.eq(Wow.CertRank(c.G.ns, "Чиллзон Север", "Борис Быстрый"), 2, "Глеб проверил отдельный офицерский сертификат Бориса")
	for _, n in ipairs({ "K", "V", "G" }) do T.eq(c[n]:Saw("офицер по флагу"), 1, n .. " видит") end
	T.eq(c.A:Saw("офицер по флагу"), 0, "Арагорн без флага не видит")
	T.eq(c.M:Saw("офицер по флагу"), 0, "рядовой не видит")
	c.A:Slash("/cz2", "можно мне?")
	T.ok(c.A:Saw("можно писать только") >= 1, "Арагорну отказано")
end)

T.test("relay: без флагов звания офицер — по номеру звания (OFFICER_RANK)", function()
	local w = Wow.World()
	w:Guild("Чиллзон", nil, { [0] = true, [1] = false }) -- по флагу звание 1 — не офицер
	local X = w:Client({ first = "Ксения", surname = "Иксова", guild = "Чиллзон", rank = 2 })
	local R = X.ns.Roster
	X:Fire("GUILD_RANKS_UPDATE")
	T.eq(R.RankFlagOfficer(1), false, "игра сказала флаг")
	T.no(R.IsOfficerRank(1), "флаг игры важнее номера звания")
	local secret = {}
	local answers = {
		{ "пустая таблица", function() return {} end },
		{ "ошибка", function() error("нельзя") end },
		{ "не таблица", function() return nil end },
		{ "нет флага 22", function() return { true, false } end },
		{ "secret-таблица", function() return secret end },
	}
	X.env.issecretvalue = function(v) return v == secret end
	for _, a in ipairs(answers) do
		X.env.C_GuildInfo.GuildControlGetRankFlags = a[2]
		X:Fire("GUILD_RANKS_UPDATE")
		T.eq(R.RankFlagOfficer(1), nil, a[1] .. ": флаг неизвестен")
		T.ok(R.IsOfficerRank(1), a[1] .. ": звание 1 — офицер по OFFICER_RANK")
		T.no(R.IsOfficerRank(2), a[1] .. ": звание 2 — нет")
		T.ok(R.IsOfficerRank(0), a[1] .. ": глава — всегда")
	end
	X.env.C_GuildInfo.GuildControlGetRankFlags = nil
	X:Fire("GUILD_RANKS_UPDATE")
	T.ok(R.IsOfficerRank(1), "нет API: звание 1 — офицер")
	T.no(R.IsOfficerRank(3), "рядовой остаётся рядовым")
	T.ok(R.IsOfficerRank(0), "глава — всегда")
	X.ns.Config.OFFICER_RANK = 0
	X:Fire("GUILD_RANKS_UPDATE")
	T.no(R.IsOfficerRank(1), "OFFICER_RANK = 0: офицер только глава")
	T.eq(#X.ns.db.errors, 0, "без ошибок")
end)

-- Часы клиента cl на время t; все известные ему реле отвечают.
local function AtWindow(cl, t)
	cl.ns.Now = function() return t end
	for _, e in pairs(cl.ns.Relay.Known()) do e.verified, e.asked, e.down = t, nil, nil end
end

T.test("relay: из отвечающих реле первыми выбираются глава и офицеры главной", function()
	local _, c = Build()
	local B, A = c.B, c.A
	local clockB, clockA = B.ns.Now, A.ns.Now
	local base = clockB()
	local known = B.ns.Relay.Known()
	for _, k in ipairs({ "арагорн светлый", "карл великий", "мира тихая" }) do
		T.ok(known[k], "Борис знает реле " .. k)
	end
	local gk = B.ns.Util.GuildKey("Чиллзон Север")
	local picked, plain = {}, {}
	for i = 1, 60 do
		local t = base + i * 600
		AtWindow(B, t)
		picked[B.ns.Relay.Pick().key] = true
		plain[B.ns.Codec.PickRelay(gk, { "арагорн светлый", "карл великий", "мира тихая" }, t, 600)] = true
	end
	T.ok(plain["мира тихая"], "без приоритета Мира иногда была бы выбрана")
	T.no(picked["мира тихая"], "рядовая Мира не выбирается, пока офицеры отвечают")
	T.ok(picked["арагорн светлый"] and picked["карл великий"], "глава и офицер чередуются")
	T.ok(B.ns.Relay.IsMainOfficer("Карл Великий") and not B.ns.Relay.IsMainOfficer("Мира Тихая"), "по отчёту главной")

	-- Глава и офицер не в игре: сообщения идут через участника.
	local t = base + 61 * 600
	AtWindow(B, t)
	known["арагорн светлый"].down = t + 100
	known["карл великий"].down = t + 100
	T.eq(B.ns.Relay.Pick().key, "мира тихая", "офицеры не в игре — Мира")

	-- Руководство главной в отчётах расходится: офицерам из отчёта не верим, приоритета нет.
	B.ns.Data.Row("Чиллзон").conflict = true
	picked = {}
	for i = 62, 121 do
		AtWindow(B, base + i * 600)
		picked[B.ns.Relay.Pick().key] = true
	end
	T.no(picked["мира тихая"], "untrusted census conflicts cannot demote certified officers")
	B.ns.Data.Row("Чиллзон").conflict = nil

	-- В главной гильдии — по своему ростеру: у Арагорна из Карла и Миры всегда Карл.
	T.ok(A.ns.Relay.Known()["мира тихая"], "Арагорн знает Миру")
	picked, plain = {}, {}
	local agk = A.ns.Util.GuildKey("Чиллзон")
	for i = 1, 60 do
		local at = base + i * 600
		AtWindow(A, at)
		picked[A.ns.Relay.Pick().key] = true
		plain[A.ns.Codec.PickRelay(agk, { "карл великий", "мира тихая" }, at, 600)] = true
	end
	T.ok(plain["мира тихая"], "без приоритета Арагорн иногда выбрал бы Миру")
	T.no(picked["мира тихая"], "Арагорн выбирает Карла")
	B.ns.Now, A.ns.Now = clockB, clockA
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": без ошибок") end
end)

T.test("relay: из старых скрытых каналов аддон выходит, их строки спрятаны", function()
	local w = Build()
	local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3 })
	N.joined["ChillzoneA"], N.joinedById[7] = 7, "ChillzoneA"
	w:Run(10)
	T.eq(N.joined["ChillzoneA"], nil, "вышла из ChillzoneA")
	local hidden, shown = false, false
	for _, fn in ipairs(N.filters["CHAT_MSG_CHANNEL"] or {}) do
		if fn(nil, "CHAT_MSG_CHANNEL", "M1~A~x", "Кто-то", "", "7. ChillzoneA", "", "", 0, 7, "ChillzoneA") then hidden = true end
		if fn(nil, "CHAT_MSG_CHANNEL", "привет", "Кто-то", "", "2. Торговля", "", "", 0, 2, "Торговля") then shown = true end
	end
	T.ok(hidden, "строка старого канала спрятана")
	T.no(shown, "чужие каналы не трогаем")
	T.eq(#N.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: длинный отчёт (несколько кусков) доходит целым", function()
	local w, c = Build({ officers = 30, run = 500 })
	local chunked = false
	for _, e in ipairs(w.log) do
		if e.from == "Глеб Гордый" and e.msg:find("^C") then chunked = true end
	end
	T.ok(chunked, "отчёт шёл кусками")
	local ref = c.A.ns.Data.Row("Орден Чиллзона")
	T.ok(ref and #ref.r.officers == 30, "30 офицеров у реле")
	for _, n in ipairs({ "K", "M", "B", "V" }) do
		local row = c[n].ns.Data.Row("Орден Чиллзона")
		T.ok(row, n .. " получил")
		local received, expected = c[n].ns.Codec.DecodeReport(row.raw), c[n].ns.Codec.DecodeReport(ref.raw)
		received.st, expected.st = 0, 0
		T.eq(c[n].ns.Codec.EncodeReport(received), c[n].ns.Codec.EncodeReport(expected), n .. ": complete data, excluding snapshot time")
		T.ok(row.signed, n .. ": retains the original signed envelope")
	end
end)

T.test("relay: участник главной вне тройки реле пишет всем через реле", function()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	local c = {}
	-- Четыре офицера главной: тройка реле — Арагорн, Богдан, Виктор. Карл и Мира вне её.
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.O1 = w:Client({ first = "Богдан", surname = "Бравый", guild = "Чиллзон", rank = 1 })
	c.O2 = w:Client({ first = "Виктор", surname = "Верный", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0 })
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	-- Здесь проверяется доставка вне тройки, а не обнаружение: после знакомства с главой
	-- репортёры получают настоящие сертификаты всех трёх более ранних кандидатов.
	for _, target in ipairs({ c.V, c.G }) do
		for _, source in ipairs({ c.A, c.O1, c.O2 }) do
			c.A.ns.Security.Introduce(target:Name(), source.ns.Security.MyCertificate().raw)
		end
	end
	w:Run(400)
	T.no(c.M.ns.Relay.Serving(), "у Миры репортёры не регистрируются")
	local candidates = {}
	for _, cl in ipairs({ c.V, c.G }) do
		for _, e in ipairs(cl.ns.Relay.Candidates()) do
			candidates[#candidates + 1] = cl:Name() .. ": " .. e.name .. "=" .. tostring(cl.ns.Relay.TrustOf(e.name))
		end
	end
	T.no(c.K.ns.Relay.Serving(), "у Карла тоже: " .. table.concat(candidates, "; "))
	c.M:Slash("/cz1", "рядовая главной пишет всем")
	w:Run(5)
	c.K:Slash("/cz1", "глава вне тройки пишет всем")
	w:Run(30)
	for _, n in ipairs({ "B", "V", "G" }) do
		T.eq(c[n]:Saw("рядовая главной пишет всем"), 1, n .. " видит строку Миры")
		T.eq(c[n]:Saw("глава вне тройки пишет всем"), 1, n .. " видит строку Карла")
	end
	for n, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, n .. ": без ошибок") end
end)

-- Новичок главной гильдии, как в первые минуты после установки: из реле он слышал только
-- рядовую Миру, а корень Арагорна ещё не спрашивал.
local function Newcomer()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.O1 = w:Client({ first = "Богдан", surname = "Бравый", guild = "Чиллзон", rank = 1 })
	c.O2 = w:Client({ first = "Виктор", surname = "Верный", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	c.N = w:Client({ first = "Новичок", surname = "Главный", guild = "Чиллзон", rank = 3 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	w:Run(30)
	w:Init(c.A, c.V)
	w:Pair(c.V, c.K)
	for _, source in ipairs({ c.A, c.O1, c.O2 }) do
		c.A.ns.Security.Introduce(c.V:Name(), source.ns.Security.MyCertificate().raw)
	end
	w:Run(400)
	local N, U = c.N.ns, c.N.ns.Util
	local mira, root = U.Key(c.M:Name()), U.Key(c.A:Name())
	local certificates = N.Security.Certificates
	N.Security.Certificates = function(guild)
		local out = {}
		for _, cert in ipairs(certificates(guild)) do
			if U.Key(cert.name) == mira then out[#out + 1] = cert end
		end
		return out
	end
	N.Census.Peers = function() return {} end
	N.Relay.Invalidate()
	N.Relay.Candidates()
	local now = N.Now()
	for _, e in pairs(N.Relay.Known()) do e.verified, e.asked, e.down = nil, nil, nil end
	N.Relay.Known()[mira].verified = now
	T.eq(N.Relay.Pick().key, mira, "из подтверждённых у новичка только Мира")
	T.no(c.M.ns.Relay.Serving(), "у Миры нет аренд чужих гильдий")
	return w, c, root
end

T.test("relay: новичок главной спрашивает офицера раньше, чем писать через рядового", function()
	local w, c, root = Newcomer()
	c.N:Slash("/cz1", "первая строка новичка")
	w:Run(30)
	T.eq(c.V:Saw("первая строка новичка"), 1, "строка дошла до другой гильдии")
	T.eq(c.A:Saw("первая строка новичка"), 1, "своя гильдия видит один раз")
	T.ok(c.N.ns.Relay.Known()[root].verified, "офицер подтверждён")
	T.eq(c.N.ns.Relay.HoldSize(), 0, "очередь разобрана")
	for n, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, n .. ": без ошибок") end
end)

T.test("relay: офицер не в игре — очередь новичка не ждёт таймера", function()
	local w, c, root = Newcomer()
	c.A:Logout()
	c.N:Slash("/cz1", "офицера нет в игре")
	w:Run(5)
	T.ok(c.N.ns.Relay.Known()[root].down, "офицер помечен недоступным")
	T.eq(c.N.ns.Relay.HoldSize(), 0, "строка не осталась в очереди")
	for n, cl in pairs(c) do
		if n ~= "A" then T.eq(#cl.ns.db.errors, 0, n .. ": без ошибок") end
	end
end)

-- Главная гильдия и две подключённые: main — участники главной (root — глава, он же корень),
-- Север и Орден знают сертификаты общей тройки реле top. Юг подключается позже и знает только корень.
local function PartialNetwork(main, top)
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	for _, g in ipairs({ "Чиллзон", "Чиллзон Север", "Орден Чиллзона", "Чиллзон Юг" }) do w:Guild(g) end
	local c = {}
	for id, m in pairs(main) do
		c[id] = w:Client({ first = m[1], surname = m[2], guild = "Чиллзон", rank = m[3] })
	end
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2 })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0 })
	w:Run(30)
	w:Init(c.root, c.V, c.G)
	w:Pair(c.V, c.root)
	w:Pair(c.G, c.root)
	for _, target in ipairs({ c.V, c.G }) do
		for _, id in ipairs(top) do
			c.root.ns.Security.Introduce(target:Name(), c[id].ns.Security.MyCertificate().raw)
		end
	end
	w:Run(200)
	return w, c
end

local function ConnectSouth(w, c)
	c.J = w:Client({ first = "Юрий", surname = "Южный", guild = "Чиллзон Юг", rank = 0 })
	w:Run(30)
	w:Init(c.J)
	w:Pair(c.J, c.root)
end

-- Живая аренда гильдии guild у реле cl или nil.
local function Lease(cl, guild)
	local held = cl.ns.Relay.Reporters()[cl.ns.Util.GuildKey(guild)]
	return held and cl.ns.Now() - held.t <= cl.ns.Relay.REG_TTL and held or nil
end

local function NoErrors(c)
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": ошибки " .. table.concat(cl.ns.db.errors, " | ")) end
end

-- Рядовые с меньшими ключами идут раньше офицера, пока сертификат офицера неизвестен.
local RANK_AND_FILE = {
	root = { "Карл", "Великий", 0 }, O = { "Олег", "Старший", 1 },
	R1 = { "Вадим", "Рядовой", 3 }, R2 = { "Галина", "Рядовая", 3 },
	R3 = { "Дарья", "Рядовая", 3 }, R4 = { "Евгений", "Рядовой", 3 },
}

T.test("relay: реле вне тройки с арендой одной гильдии пишет всем гильдиям", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	ConnectSouth(w, c)
	for _ = 1, 200 do
		if Lease(c.R2, "Чиллзон Юг") then break end
		w:Run(1)
	end
	T.ok(Lease(c.R2, "Чиллзон Юг"), "Юг зарегистрировался у Галины")
	T.eq(Lease(c.R2, "Чиллзон Север"), nil, "Север у Галины не зарегистрирован")
	T.eq(Lease(c.R2, "Орден Чиллзона"), nil, "Орден у Галины не зарегистрирован")
	T.ok(c.R2.ns.Relay.Serving(), "Галина считает, что обслуживает гильдии")
	local text = "рядовая с арендой одной гильдии"
	c.R2:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: перезашедшее реле из тройки пишет всем, пока аренды неполные", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	-- Перезаход без паузы: репортёры не успевают заметить, что реле выходило.
	local db = c.O.ns.db
	c.O:Logout()
	c.O = w:Client({ first = "Олег", surname = "Старший", guild = "Чиллзон", rank = 1, db = db })
	local back, have, miss = c.O, "Чиллзон Север", "Орден Чиллзона"
	-- Пока реле не прочитало ростер, RR теряются, и следующий придёт через REG_EVERY.
	for _ = 1, 60 do
		if Lease(back, have) or Lease(back, miss) then break end
		w:Run(1)
	end
	if not Lease(back, have) then have, miss = miss, have end
	T.ok(Lease(back, have), "одна из гильдий уже зарегистрировалась")
	-- Вторая гильдия ещё не успела: её репортёр сам недавно зашёл.
	back.ns.Relay.Reporters()[back.ns.Util.GuildKey(miss)] = nil
	T.ok(back.ns.Relay.Serving(), "реле обслуживает гильдию")
	T.ok(back.ns.Relay.InTop(), "реле в общей тройке")
	local text = "сразу после перезахода"
	back:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)

	-- Когда все вернулись, лишний путь через тройку закрывается.
	w:Run(back.ns.Config.RELAY_SETTLE)
	T.ok(Lease(back, "Чиллзон Север") and Lease(back, "Орден Чиллзона"), "аренды обеих гильдий")
	local picks, pick = 0, back.ns.Relay.Pick
	back.ns.Relay.Pick = function()
		picks = picks + 1
		return pick()
	end
	text = "реле давно в игре"
	back:Slash("/cz1", text)
	w:Run(30)
	T.eq(picks, 0, "через других реле строка не идёт")
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: вернувшееся реле пишет и тем, кто ещё считает его офлайн", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	local db = c.O.ns.db
	c.O:Logout()
	c.O = w:Client({ first = "Олег", surname = "Старший", guild = "Чиллзон", rank = 1, db = db })
	local back, have, miss = c.O, "Чиллзон Север", "Орден Чиллзона"
	for _ = 1, 60 do
		if Lease(back, have) or Lease(back, miss) then break end
		w:Run(1)
	end
	if not Lease(back, have) then have, miss = miss, have end
	T.ok(Lease(back, have), "одна из гильдий уже зарегистрировалась")
	-- Вторая гильдия заметила выход и до конца RELAY_DOWN у этого реле не регистрируется. Состояние
	-- ставится каждую секунду: ответ на RR, уже идущий к её репортёру, снял бы отметку «офлайн».
	local down, key, gk = back.ns.Config.RELAY_DOWN, back.ns.Util.Key(back:Name()), back.ns.Util.GuildKey(miss)
	local function Away()
		for _, cl in pairs(c) do
			local e = cl.guild == miss and cl.ns.Relay.Known()[key]
			if e then e.down, e.asked, e.verified = w.now + down, nil, nil end
		end
		back.ns.Relay.Reporters()[gk] = nil
	end
	for _ = 1, down / 2 do
		Away()
		w:Run(1)
	end
	Away()
	T.ok(Lease(back, have), "первая гильдия держит аренду")
	T.eq(Lease(back, miss), nil, "вторая гильдия так и не зарегистрировалась")
	T.ok(back.ns.Relay.Serving(), "реле обслуживает гильдию")
	T.ok(back.ns.Relay.InTop(), "реле в общей тройке")
	local text = "реле вернулось несколько минут назад"
	back:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: новая гильдия узнаёт общую тройку от реле вне её", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	ConnectSouth(w, c)
	w:Run(180)
	T.ok(Lease(c.O, "Чиллзон Юг"), "Юг зарегистрировался у офицера: тройка та же, что у всех")
	T.eq(Lease(c.R2, "Чиллзон Юг"), nil, "у рядовой вне тройки аренда Юга истекла")
	local text = "офицер пишет после подключения Юга"
	c.O:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: автор после долгого молчания пишет через общую тройку", function()
	-- Общая тройка — молчащие офицеры, зонами они не делятся. Репортёр главной гильдии — четвёртый
	-- офицер: только его сертификат расходится с отчётами, но аренд других гильдий у него нет.
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
		O4 = { "Дмитрий", "Четвёртый", 1 },
		R1 = { "Адам", "Рядовой", 3 }, R2 = { "Алина", "Рядовая", 3 },
	}, { "O1", "O2", "O3" })
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		c[id].ns.char.shareZones = false
		c[id].ns.Census.SendHello()
	end
	w:Run(240)
	T.ok(c.O4.ns.Census.IsReporter(), "репортёр главной — четвёртый офицер")
	local author = c.B
	T.no(author.ns.Census.IsReporter(), "Борис не репортёр")
	-- Автор давно в сети: сертификаты главной гильдии у него уже есть.
	for _, id in ipairs({ "root", "O1", "O2", "O3", "O4", "R1", "R2" }) do
		c.root.ns.Security.Introduce(author:Name(), c[id].ns.Security.MyCertificate().raw)
	end
	w:Run(30)
	author:Slash("/cz1", "до молчания")
	w:Run(60)
	T.eq(c.G:Saw("до молчания"), 1, "пока роли свежие, строка доходит")
	w:Run(author.ns.Config.AUTH_ROLE_TTL + 300)
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		T.eq(author.ns.Relay.TrustOf(c[id]:Name()), "officer", id .. ": роль у молчавшего автора свежая")
	end
	local text = "первая строка после молчания"
	author:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: отчёты доходят до гильдии, зарегистрированной только вне общей тройки", function()
	-- Корень — глава с большим ключом, в общую тройку офицеров не входит. Рядовые с малыми ключами
	-- идут у Юга сразу за корнем, поэтому никого из общей тройки Юг сначала не спрашивает.
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
		R1 = { "Адам", "Рядовой", 3 }, R2 = { "Алина", "Рядовая", 3 },
	}, { "O1", "O2", "O3" })
	ConnectSouth(w, c)
	w:Run(180)
	-- Отчёт длинный и идёт кусками в общей очереди: ждём приход, а не фиксированную паузу.
	local function Fresh(reader, reporter, guild)
		w:Run(65)
		reporter.ns.Roster.Scan()
		local st = reporter.ns.Roster.report.st
		reporter.ns.Census.MaybeReport(true)
		local row
		for _ = 1, 120 do
			row = reader.ns.Data.Row(guild)
			if row and row.r and row.r.st >= st then break end
			w:Run(1)
		end
		T.ok(row and row.r, reader:Name() .. " знает " .. guild)
		T.ok(row.r.st >= st, reader:Name() .. " получил свежий отчёт " .. guild .. ": " .. row.r.st .. " против " .. st)
	end
	Fresh(c.J, c.V, "Чиллзон Север")
	Fresh(c.J, c.G, "Орден Чиллзона")
	Fresh(c.V, c.J, "Чиллзон Юг")
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		T.ok(Lease(c[id], "Чиллзон Юг"), id .. ": Юг зарегистрирован у общей тройки")
	end
	NoErrors(c)
end)

T.test("relay: входящий отчёт проходит через реле вне тройки без аренды получателя", function()
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
	}, { "O1", "O2", "O3" })
	ConnectSouth(w, c)
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		c.root.ns.Security.Introduce(c.J:Name(), c[id].ns.Security.MyCertificate().raw, true)
	end
	w:Run(90)
	c.J.ns.Relay.Register(); w:Run(20)
	T.no(c.root.ns.Relay.InTop(), "выбранное автором реле вне общей тройки")
	for _, id in ipairs({ "O1", "O2", "O3" }) do T.ok(Lease(c[id], c.J.guild), "тройка обслуживает получателя") end
	c.root.ns.Relay.Reporters()[c.root.ns.Util.GuildKey(c.J.guild)] = nil
	local rootPeer = { key = c.root.ns.myKey, name = c.root:Name() }
	c.V.ns.Relay.Pick = function() return rootPeer end
	w:Run(65)
	c.V.ns.Roster.Scan()
	local stamp = c.V.ns.Roster.report.st
	c.V.ns.Census.MaybeReport(true); w:Run(90)
	local row = c.J.ns.Data.Row(c.V.guild)
	T.ok(row and row.r.st >= stamp, "отчёт передан тройке и доставлен без аренды у первого реле")
	-- При поиске следующего реле нельзя склеить отчёты разных гильдий в один S1.
	local pick = c.root.ns.Relay.Pick
	c.root.ns.Relay.Pick = function() return nil end
	c.G.ns.Relay.Pick = function() return rootPeer end
	w:Run(65)
	c.V.ns.Roster.Scan(); c.G.ns.Roster.Scan()
	local northStamp, orderStamp = c.V.ns.Roster.report.st, c.G.ns.Roster.report.st
	c.V.ns.Census.MaybeReport(true); c.G.ns.Census.MaybeReport(true); w:Run(10)
	c.root.ns.Relay.Pick = pick
	c.O1.ns.Comm.Send("WHISPER", "RY~", { target = c.root:Name(), prio = true }); w:Run(90)
	T.ok(c.J.ns.Data.Row(c.V.guild).r.st >= northStamp, "очередь сохранила отчёт Севера")
	T.ok(c.J.ns.Data.Row(c.G.guild).r.st >= orderStamp, "очередь сохранила отчёт Ордена")
	local text = "через запасное реле без аренды"
	c.V:Slash("/cz1", text); w:Run(35)
	T.eq(c.J:Saw(text), 1, "строка тоже доходит один раз")
	NoErrors(c)
end)

T.test("relay: старый отчёт от реле не вытесняет новый из очереди гильдии", function()
	local w, c = Build()
	local reporter = c.V.ns.Census.IsReporter() and c.V or c.B
	local member = reporter == c.V and c.B or c.V
	T.ok(reporter.ns.Census.IsReporter(), "у Севера есть репортёр")
	local guild, comm = "Орден Чиллзона", reporter.ns.Comm
	local function Until(check)
		for _ = 1, 30 do
			if check() then return true end
			w:Run(1)
		end
		return check()
	end
	local function HasReport(cl, st)
		return function()
			local row = cl.ns.Data.Row(guild)
			return row and row.r.st >= st
		end
	end
	local old = c.G.ns.Census.lastRaw
	T.ok(old, "у Ордена уже есть отчёт")
	-- Перезашедшее реле отдаёт отчёт позже, чем истекает защита от повторов.
	w:Run(reporter.ns.Config.RELAY_DEDUPE + 30)

	-- Очередь репортёра стоит, как при всплеске трафика: новый отчёт ждёт отправки гильдии.
	local free = comm.InLockdown
	comm.InLockdown = function() return true end
	c.G.ns.Roster.Scan()
	local st = c.G.ns.Roster.report.st
	c.G.ns.Census.MaybeReport(true)
	T.ok(Until(HasReport(reporter, st)), "репортёр получил новый отчёт")

	c.A.ns.Comm.Send("WHISPER", c.A.ns.Codec.EncodeRM("RM", "L", "Глеб Гордый", old), { target = reporter:Name() })
	T.ok(Until(function()
		for _, line in ipairs(reporter.ns.db.log) do
			if line:find("старее", 1, true) then return true end
		end
		return false
	end), "репортёр отклонил старый отчёт")

	comm.InLockdown = free
	T.ok(Until(HasReport(member, st)), "участник получил новый отчёт")
	NoErrors(c)
end)

T.test("relay: реле вышло из игры — сообщение уходит через другое", function()
	local w, c = Build()
	local pick = c.B.ns.Relay.Pick()
	T.ok(pick, "у Бориса есть реле")
	local function Client(key)
		for _, cl in pairs(c) do
			if Key(c.B, cl:Name()) == key then return cl end
		end
	end
	local gone = Client(pick.key)
	T.ok(gone, "реле Бориса — один из клиентов")
	gone:Logout()
	local text = "реле ушло, а я пишу"
	c.B:Slash("/cz1", text)
	w:Run(60)
	T.ok(c.B.ns.Relay.Known()[pick.key].down, "ушедшее реле помечено")
	local now = c.B.ns.Relay.Pick()
	T.ok(now and now.key ~= pick.key, "Борис перешёл на другое реле")
	T.eq(c.G:Saw(text), 1, "Глеб видит")
	T.eq(Client(now.key):Saw(text), 1, "второе реле видит")
	local hidden = false
	for _, fn in ipairs(c.B.filters["CHAT_MSG_SYSTEM"] or {}) do
		if fn(nil, "CHAT_MSG_SYSTEM", ("No player named '%s' is currently playing."):format(pick.name)) then hidden = true end
	end
	T.no(hidden, "через 60 с строка уже не скрывается")
end)

T.test("relay: ошибка Forever снимает аренду репортёра и остаётся скрытой", function()
	local _, c = Build()
	local gk = c.A.ns.Util.GuildKey("Чиллзон Север")
	local relay
	for _, cl in pairs(c) do
		local held = cl.ns.Relay.Reporters()[gk]
		if held and held.key == Key(cl, c.V:Name()) then relay = cl; break end
	end
	T.ok(relay, "есть реле с арендой Веры")
	local text = ('Персонаж по имени "%s" в игре не найден.'):format(c.V:Name())
	relay.ns.Comm.SendNow("WHISPER", "ZZ~test", c.V:Name())
	relay:Fire("CHAT_MSG_SYSTEM", text)
	T.eq(relay.ns.Relay.Reporters()[gk], nil, "аренда снята сразу")
	for _ = 1, 2 do
		local hidden = false
		for _, filter in ipairs(relay.filters.CHAT_MSG_SYSTEM or {}) do
			if filter(nil, "CHAT_MSG_SYSTEM", text) then hidden = true end
		end
		T.ok(hidden, "строка скрыта и после снятия аренды, в каждом окне")
	end
end)

T.test("relay: Q1 после /reload восполняет перепись", function()
	local w, c = Build()
	-- Мира перезаходит с пустыми данными.
	c.M:Logout()
	local M2 = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	T.eq(M2.ns.Data.Row("Орден Чиллзона"), nil, "сначала пусто")
	w:Run(40)
	T.ok(M2.ns.Data.Row("Орден Чиллзона"), "Орден пришёл по Q1")
	T.ok(M2.ns.Data.Row("Чиллзон Север"), "Север пришёл по Q1")
end)

T.test("relay: команды выполняются, обычный текст коротких алиасов доходит в общий чат", function()
	local w, c = Build()
	local toggles, toggle = 0, c.B.ns.UI.Toggle
	c.B.ns.UI.Toggle = function() toggles = toggles + 1 end
	c.B:Slash("/chillzone", "")
	for _, cmd in ipairs({ "/chillzone", "/cz", "/чз", "/чиллзон" }) do
		c.B:Slash(cmd, "status")
	end
	c.B.ns.UI.Toggle = toggle
	T.eq(toggles, 1, "без текста — окно")
	T.eq(c.B.ns.Chat.stats.sent, 0, "команды не ушли в чат")
	T.eq(c.B:Saw("перепись: репортёр"), 4, "status выполнен каждым алиасом")
	local lines = {
		{ c.B, "/чз", "Привет кириллицей" },
		{ c.B, "/cz", "привет без номера" },
		{ c.B, "/чиллзон", "ещё одно сообщение" },
		{ c.B, "/cz1", "status" },
		{ c.B, "/чз1", "привет через чз1" },
		{ c.V, "/чз2", "офицерам через чз2" },
		{ c.G, "/чз3", "главам через чз3" },
	}
	for _, l in ipairs(lines) do
		l[1]:Slash(l[2], l[3])
	w:Run(30)
	end
	for name, cl in pairs(c) do
		T.eq(cl:Saw("Привет кириллицей"), 1, name .. ": /чз текст")
		T.eq(cl:Saw("привет без номера"), 1, name .. ": /cz текст")
		T.eq(cl:Saw("ещё одно сообщение"), 1, name .. ": /чиллзон текст")
		T.eq(cl:Saw("status"), 1, name .. ": слово команды — текст через /cz1")
		T.eq(cl:Saw("привет через чз1"), 1, name .. ": /чз1")
	end
	for _, n in ipairs({ "A", "K", "G", "V" }) do T.eq(c[n]:Saw("офицерам через чз2"), 1, n .. ": /чз2") end
	T.eq(c.M:Saw("офицерам через чз2"), 0, "рядовой не видит /чз2")
	for _, n in ipairs({ "A", "K", "V", "G" }) do T.eq(c[n]:Saw("главам через чз3"), 1, n .. ": /чз3") end
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": без ошибок") end
end)

T.test("relay: команды, окно и вкладки без ошибок", function()
	local w, c = Build()
	for _, cmd in ipairs({ "", "help", "status", "relay", "relay ping", "zones", "chat", "chat off", "chat on", "history 1", "history 3", "map off", "map on", "minimap", "minimap", "kingdom", "census", "ignore", "log 5", "debug", "debug", "нетакой" }) do
		c.B:Slash("/chillzone", cmd)
		c.A:Slash("/chillzone", cmd)
	end
	c.B:Slash("/chillzone", "ignore Глеб Гордый")
	c.G:Slash("/cz1", "меня не видно")
	w:Run(30)
	T.eq(c.B:Saw("меня не видно"), 0, "игнор работает")
	T.eq(c.A:Saw("меня не видно"), 1, "у других видно")
	c.B.ns.Map.RefreshNow()
	local census = c.B.ns.Views.CensusRows()
	local kingdom = c.B.ns.Views.Kingdom()
	local function has(lines, text)
		for _, l in ipairs(lines) do
			if (l.text or ""):find(text, 1, true) then return true end
		end
		return false
	end
	T.ok(has(census, "Орден Чиллзона") and has(census, "Чиллзон Север"), "перепись")
	T.ok(has(kingdom, "Карл Великий") and has(kingdom, "Глеб Гордый") and has(kingdom, "Вера Верная"), "королевство")
	T.ok(has(kingdom, "Арагорн Светлый"), "капитан короля")
	for _, l in ipairs(census) do
		if l.tip then l.tip(setmetatable({}, { __index = function() return function() end end })) end
	end
	for name, cl in pairs(c) do
		local errors = cl.ns.db.errors
		T.eq(#errors, 0, name .. ": ошибки " .. table.concat(errors, " | "))
	end
end)
