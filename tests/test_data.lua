-- Data: приём отчётов, отказы, конфликт подписей, сроки свежести и хранения.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Setup()
	math.randomseed(3)
	local w = Wow.World()
	w:Guild("Орден Чиллзона")
	local g = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0 })
	w:Run(2)
	-- Эти тесты проверяют отчёты уже подключённых гильдий, отдельно от протокола допуска.
	for _, guild in ipairs({ "Орден Чиллзона", "Чиллзон Север", "Чиллзон Юг" }) do
		g.ns.store.security.union[g.ns.Util.GuildKey(guild)] = { active = true }
	end
	return w, g, g.ns
end

local function Report(ns, guild, st, leader, officers, veterans)
	local r = {
		guild = guild, total = 10, online = 4, leader = leader or "Вера Верная", leaderOnline = true,
		leaderDays = 0, leaderClass = "DRUID", leaderLevel = 60, users = 2,
		zones = { m1453 = 2 }, classes = { DRUID = 1, WARRIOR = 3 }, levels = { 0, 0, 0, 0, 0, 1, 3 },
		ranks = { { name = "Глава", count = 1 }, { name = "Офицер", count = 1 }, { name = "Рядовой", count = 8 } },
		officers = officers or { { name = "Борис Быстрый", online = true, days = 0, class = "WARRIOR", level = 60, rank = 1 } },
		veterans = veterans or {},
		inactive7 = 1, inactive30 = 0, avgLevel = 55.5, faction = "Alliance", st = st,
	}
	local raw = ns.Codec.EncodeReport(r)
	return ns.Codec.DecodeReport(raw), raw
end

T.test("data: census data alone never authorizes a guild role", function()
	local _, _, ns = Setup()
	local now = ns.ServerTime()
	local r, raw = Report(ns, "Чиллзон Север", now)
	T.ok(ns.Data.Take(r, raw, "Борис Быстрый-CAMWOWUS2Realm7PvE", now), "принят")
	T.eq(Wow.CertRank(ns, "Чиллзон Север", "Вера Верная"), nil, "an unverified report grants no leader role")
	T.eq(Wow.CertRank(ns, "ЧИЛЛЗОН СЕВЕР", "борис-быстрый"), nil, "an unverified report grants no officer role")
	T.eq(Wow.CertRank(ns, "Чиллзон Север", "Кто Угодно"), nil, "рядовой неизвестен")
	local again = ns.Data.Take(r, raw, "Борис Быстрый", now)
	T.no(again, "повтор не меняет")
end)

T.test("data: отказы", function()
	local _, _, ns = Setup()
	local now = ns.ServerTime()
	local function why(guild, st, origin, faction)
		local r, raw = Report(ns, guild, st or now)
		if faction then r.faction = faction end
		local ok, reason = ns.Data.Take(r, raw, origin or "Некто Первый", now)
		T.no(ok, "должен быть отказ: " .. guild)
		return reason
	end
	T.eq(why("Орден Чиллзона"), "своя гильдия", "своя")
	T.eq(why("Олимп"), "чужое название", "не Чиллзон")
	T.eq(why("Чиллзон Юг", now, "Некто Второй", "Horde"), "другая фракция", "фракция")
	T.eq(why("Чиллзон Юг", now + 3600, "Некто Третий"), "время из будущего", "будущее")
	local r, raw = Report(ns, "Чиллзон Север", now)
	T.ok(ns.Data.Take(r, raw, "Некто Четвёртый", now), "первая гильдия")
	T.eq(why("Чиллзон Юг", now, "Некто Четвёртый"), "вторая гильдия", "одна гильдия на отправителя")
	local r2, raw2 = Report(ns, "Чиллзон Север", now - 100)
	r2.online = 3
	local ok, reason = ns.Data.Take(r2, raw2, "Некто Пятый", now)
	T.no(ok, "старый отчёт")
	T.eq(reason, "старее", "причина")
	-- Через 15 минут отправитель может отчитаться за другую гильдию.
	local r3, raw3 = Report(ns, "Чиллзон Юг", now + 901)
	T.ok(ns.Data.Take(r3, raw3, "Некто Четвёртый", now + 901), "после CLAIM_TTL")
end)

T.test("data: разные подписи руководства — конфликт", function()
	local _, _, ns = Setup()
	local now = ns.ServerTime()
	local r, raw = Report(ns, "Чиллзон Север", now)
	T.ok(ns.Data.Take(r, raw, "Свидетель Первый", now), "первый")
	local fake, fakeRaw = Report(ns, "Чиллзон Север", now + 10, "Самозванец Ложный")
	T.ok(ns.Data.Take(fake, fakeRaw, "Свидетель Второй", now + 10), "второй принят")
	local row = ns.Data.Row("Чиллзон Север")
	T.ok(row.conflict, "помечено «!»")
	T.eq(Wow.CertRank(ns, "Чиллзон Север", "Самозванец Ложный"), nil, "ранги не учитываются")
	-- Через 15 минут старая подпись устаревает.
	local r3, raw3 = Report(ns, "Чиллзон Север", now + 1000, "Самозванец Ложный")
	T.ok(ns.Data.Take(r3, raw3, "Свидетель Второй", now + 1000), "позже")
	T.no(ns.Data.Row("Чиллзон Север").conflict, "конфликт снят")
end)

T.test("data: разные связные в отчётах — тоже конфликт", function()
	local _, _, ns = Setup()
	local now = ns.ServerTime()
	local r, raw = Report(ns, "Чиллзон Север", now)
	T.ok(ns.Data.Take(r, raw, "Свидетель Первый", now), "первый")
	local fake, fakeRaw = Report(ns, "Чиллзон Север", now + 10, nil, nil,
		{ { name = "Самозванец Ложный", online = true, days = 0, class = "MAGE", level = 60, rank = 2 } })
	T.ok(ns.Data.Take(fake, fakeRaw, "Свидетель Второй", now + 10), "второй принят")
	T.ok(ns.Data.Row("Чиллзон Север").conflict, "помечено «!»")
end)

T.test("data: сроки FRESH, TOTAL_KEEP, KEEP", function()
	local _, _, ns = Setup()
	local C = ns.Config
	local now = ns.ServerTime()
	local r, raw = Report(ns, "Чиллзон Север", now)
	ns.Data.Take(r, raw, "Борис Быстрый", now)
	local function row(at)
		for _, s in ipairs(ns.Data.Summary(at)) do
			if s.guild == "Чиллзон Север" then return s end
		end
	end
	local s = row(now + C.FRESH)
	T.eq(s.online, 4, "онлайн свежий на границе")
	T.ok(next(ns.Data.ZoneCounts(now + C.FRESH)), "зоны на карте")
	s = row(now + C.FRESH + 1)
	T.eq(s.online, nil, "онлайн устарел")
	T.eq(s.total, 10, "численность ещё видна")
	T.eq(next(ns.Data.ZoneCounts(now + C.FRESH + 1)), nil, "круги исчезли")
	T.eq(Wow.CertRank(ns, "Чиллзон Север", "Вера Верная"), nil, "ранг только по свежему")
	s = row(now + C.TOTAL_KEEP + 1)
	T.ok(s and not s.recent and s.total == nil, "итог устарел, строка ещё есть")
	T.ok(row(now + C.KEEP), "хранится 7 дней")
	ns.Data.Prune(now + C.KEEP + 1)
	T.eq(ns.Data.Row("Чиллзон Север"), nil, "удалено после 7 дней")
end)

T.test("data: unsigned census and learned names cannot vouch for relays", function()
	local _, _, ns = Setup()
	ns.Config.TRUST_ANY_MEMBER = false
	local now = ns.ServerTime()
	T.eq(ns.Relay.TrustOf("Карл Великий"), nil, "без корня главной — неизвестно")
	local r, raw = Report(ns, "Чиллзон", now, "Карл Великий",
		{ { name = "Арагорн Светлый", online = true, days = 0, class = "MAGE", level = 60, rank = 1 } },
		{ { name = "Вадим Ветров", online = true, days = 0, class = "ROGUE", level = 60, rank = 2 } })
	T.ok(ns.Data.Take(r, raw, "Арагорн Светлый", now), "отчёт главной")
	T.eq(ns.Relay.TrustOf("Арагорн Светлый"), nil, "census officer claim is not authority")
	T.eq(ns.Relay.TrustOf("Вадим Ветров"), nil, "census veteran claim is not authority")
	T.eq(ns.Relay.TrustOf("Мира Тихая"), nil, "membership is unknown without an approved root")
	T.eq(Wow.CertRank(ns, "Чиллзон", "Вадим Ветров"), nil, "связной — не офицер для уровней чата")
	ns.store.relays[ns.Util.Key("Мира Тихая")] = { name = "Мира Тихая", t = now }
	T.eq(ns.Relay.TrustOf("Мира Тихая"), nil, "выученное реле не из руководства главной — не доверено")
	ns.store.relays[ns.Util.Key("Арагорн Светлый")] = { name = "Арагорн Светлый", t = now }
	T.eq(ns.Relay.TrustOf("Арагорн Светлый"), nil, "a claimed officer needs a signed credential")
	ns.store.relays[ns.Util.Key("Вадим Ветров")] = { name = "Вадим Ветров", t = now }
	T.eq(ns.Relay.TrustOf("Вадим Ветров"), nil, "a claimed veteran needs a signed credential")
	-- Без проверки звания реле может быть любой участник: отчёту главной нечем его опровергнуть.
	ns.Config.TRUST_ANY_MEMBER = true
	T.eq(ns.Relay.TrustOf("Мира Тихая"), nil, "member fallback never bypasses credential verification")
end)
