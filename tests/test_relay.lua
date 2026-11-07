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
	-- Только расписание: подпись здесь завершается синхронно. Настоящие подписи
	-- и проверка сертификатов покрываются сетевыми и adversarial-тестами.
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
	local text = "слово реле"
	c.A:Slash("/cz1", text)
	w:Run(30)
	for _, e in ipairs(w.log) do
		T.no(e.from == "Арагорн Светлый" and e.dist == "WHISPER" and e.msg:find("^RL~"), "реле не шепчет RL себе")
	end
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит") end
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

T.test("relay: /chillzone управляет, /чз и /cz пишут в общий чат", function()
	local w, c = Build()
	local toggles, toggle = 0, c.B.ns.UI.Toggle
	c.B.ns.UI.Toggle = function() toggles = toggles + 1 end
	for _, cmd in ipairs({ "/chillzone" }) do
		c.B:Slash(cmd, "")
		c.B:Slash(cmd, "status")
	end
	c.B.ns.UI.Toggle = toggle
	T.eq(toggles, 1, "без текста — окно")
	T.eq(c.B.ns.Chat.stats.sent, 0, "команды не ушли в чат")
	T.ok(c.B:Saw("перепись: репортёр") >= 1, "status выполнен")
	local lines = {
		{ c.B, "/чз", "Привет кириллицей" },
		{ c.B, "/cz", "привет без номера" },
		{ c.B, "/чиллзон", "status" },
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
		T.eq(cl:Saw("status"), 1, name .. ": слово команды — текст через /чиллзон")
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
